import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO
import AppKit

public final class FrameHandshakeServer: MediaSourceDelegate {
    public static let shared = FrameHandshakeServer()
    
    private let socketPaths = [
        "/private/tmp/com.swmansion.SimCam/frame-handshake.sock",
        "/private/tmp/opensimcam/frame-handshake.sock"
    ]
    
    private var listeningSockets: [Int32] = []
    private var dispatchSources: [DispatchSourceRead] = []
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private let serverQueue = DispatchQueue(label: "opensc.handshakeserver")
    
    private var activeChannels: [ProcessChannel] = []
    private let channelsLock = NSLock()
    private let lifecycleLock = NSLock()
    private var isStopping = false
    private var connectedChannelIDs = Set<ObjectIdentifier>()
    private var reconnectingChannelPaths = Set<String>()
    private var reconnectTargets: [String: ReconnectTarget] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var disconnectedNotifications = Set<String>()
    private let reconnectGracePeriod: TimeInterval = 2.0
    public var onPreviewFrame: ((Data) -> Void)?
    public var onClientConnected: ((String, String) -> Void)?
    public var onClientDisconnected: ((String) -> Void)?
    public var onCameraStateChanged: ((String, Bool, String) -> Void)?
    
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let previewQueue = DispatchQueue(label: "opensc.preview.queue", qos: .userInteractive)
    private let sourceLock = NSLock()
    private let previewStateLock = NSLock()
    private var isGeneratingPreview = false
    private var lastPreviewTime: CFAbsoluteTime = 0
    
    public var frontTransformConfig = TransformConfig(fitMode: "fill", zoom: 1.0, offsetX: 0.0, offsetY: 0.0, rotation: 0, mirror: true)
    public var backTransformConfig = TransformConfig(fitMode: "fill", zoom: 1.0, offsetX: 0.0, offsetY: 0.0, rotation: 0, mirror: false)
    public var previewTargetCamera: String = "back"
    
    private var mediaSource: MediaSource?

    private struct ReconnectTarget {
        let simUDID: String
        let bundleID: String
        let channelPath: String
    }
    public var currentMediaSource: MediaSource? {
        get {
            sourceLock.lock()
            defer { sourceLock.unlock() }
            return mediaSource
        }
        set {
            sourceLock.lock()
            let previous = mediaSource
            mediaSource = newValue
            sourceLock.unlock()

            guard previous !== newValue else { return }
            previous?.delegate = nil
            previous?.stop()
            newValue?.delegate = self
            newValue?.start()
        }
    }

    private func isCurrentSource(_ source: MediaSource) -> Bool {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        return mediaSource === source
    }

    private func channelsSnapshot() -> [ProcessChannel] {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        return activeChannels
    }

    public func connectionSnapshot() -> [(bundleID: String, simUDID: String, isCameraActive: Bool, camera: String)] {
        channelsSnapshot().map { channel in
            let cameraState = channel.cameraStateSnapshot()
            return (channel.bundleID, channel.simUDID, cameraState.isActive, cameraState.camera)
        }
    }

    public func hasActiveConnectedChannels() -> Bool {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        return activeChannels.contains { $0.isTransportConnected }
    }
    
    private init() {}
    
    public func start() {
        lifecycleLock.lock()
        isStopping = false
        lifecycleLock.unlock()
        for path in socketPaths {
            try? startListening(at: path)
        }
        startWatchingSocketDirectories()
        scanExistingProcessSockets()
    }
    
    public func stop() {
        lifecycleLock.lock()
        isStopping = true
        lifecycleLock.unlock()
        for watcher in directoryWatchers {
            watcher.cancel()
        }
        directoryWatchers.removeAll()

        for source in dispatchSources {
            source.cancel()
        }
        dispatchSources.removeAll()
        
        for fd in listeningSockets {
            close(fd)
        }
        listeningSockets.removeAll()
        
        for path in socketPaths {
            unlink(path)
        }
        
        for ch in channelsSnapshot() {
            ch.disconnect()
        }
        channelsLock.lock()
        activeChannels.removeAll()
        channelsLock.unlock()
        
        currentMediaSource = nil
        print("[FrameHandshakeServer] Stopped and cleaned up all sockets.")
    }
    
    private func startListening(at path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        
        unlink(path)
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }
        
        guard bindRes == 0 else {
            close(fd)
            return
        }
        
        chmod(path, 0o777)
        guard listen(fd, 32) == 0 else {
            close(fd)
            return
        }
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serverQueue)
        source.setEventHandler { [weak self] in
            self?.acceptClient(on: fd)
        }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        
        listeningSockets.append(fd)
        dispatchSources.append(source)
        source.resume()
    }
    
    private func acceptClient(on listenFD: Int32) {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.accept(listenFD, sockPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else { return }
        
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var handshake = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var parsedHandshake: [String: Any]?
        while handshake.count < 16 * 1024, parsedHandshake == nil {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            handshake.append(buffer, count: bytesRead)
            let payload: Data
            if let newline = handshake.firstIndex(of: 0x0a) {
                payload = handshake.subdata(in: 0..<newline)
            } else {
                payload = handshake
            }
            parsedHandshake = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        }
        close(clientFD)

        guard let json = parsedHandshake,
              let type = json["type"] as? String, type == "handshake",
              let simUDID = json["simUDID"] as? String,
              let bundleID = json["bundleID"] as? String,
              let channelPath = json["channelPath"] as? String else {
            return
        }

        let targetCanonical = canonicalPath(channelPath)
        channelsLock.lock()
        let existingWorking = activeChannels.first {
            (canonicalPath($0.channelPath) == targetCanonical || $0.channelPath == channelPath) && $0.isTransportConnected
        }
        channelsLock.unlock()

        if let existing = existingWorking {
            existing.updateBundleID(bundleID)
            publishConnected(bundleID: bundleID, simUDID: simUDID)
            return
        }
        
        let channel = ProcessChannel(simUDID: simUDID, bundleID: bundleID, channelPath: channelPath)
        channel.frontTransformConfig = frontTransformConfig
        channel.backTransformConfig = backTransformConfig

        cancelReconnects(bundleID: bundleID)
        configureCallbacks(for: channel)
        if channel.connect(), channel.isTransportConnected {
            installConnectedChannel(channel)
            publishConnected(bundleID: bundleID, simUDID: simUDID)
        } else {
            beginReconnect(ReconnectTarget(
                simUDID: simUDID,
                bundleID: bundleID,
                channelPath: channelPath
            ))
        }
    }

    private func configureCallbacks(for channel: ProcessChannel) {
        channel.onDisconnected = { [weak self, weak channel] _ in
            guard let self = self, let channel = channel else { return }
            self.serverQueue.async {
                let channelID = ObjectIdentifier(channel)
                let hadBeenConnected = self.connectedChannelIDs.remove(channelID) != nil
                self.channelsLock.lock()
                self.activeChannels.removeAll { $0 === channel }
                let replacementExists = self.activeChannels.contains { $0.bundleID == channel.bundleID }
                self.channelsLock.unlock()
                guard !self.isServerStopping, !replacementExists else { return }

                let target = ReconnectTarget(
                    simUDID: channel.simUDID,
                    bundleID: channel.bundleID,
                    channelPath: channel.channelPath
                )
                if hadBeenConnected {
                    self.scheduleDisconnectedNotification(for: target)
                }
                self.beginReconnect(target)
            }
        }

        channel.onCameraStateChanged = { [weak self, weak channel] isActive, camera in
            guard let self = self, let channel = channel else { return }
            self.serverQueue.async {
                self.channelsLock.lock()
                let isCurrentChannel = self.activeChannels.contains { $0 === channel }
                self.channelsLock.unlock()
                guard isCurrentChannel else { return }
                DispatchQueue.main.async {
                    self.onCameraStateChanged?(channel.bundleID, isActive, camera)
                }
            }
        }
    }

    private var isServerStopping: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isStopping
    }

    /// Called on `serverQueue`; replacing the channel invalidates any retry
    /// loop associated with that app bundle.
    private func cancelReconnects(bundleID: String) {
        let paths = reconnectTargets.values
            .filter { $0.bundleID == bundleID }
            .map(\.channelPath)
        for path in paths {
            reconnectingChannelPaths.remove(path)
            reconnectTargets.removeValue(forKey: path)
            reconnectAttempts.removeValue(forKey: path)
            disconnectedNotifications.remove(path)
        }
    }

    private func canonicalPath(_ path: String) -> String {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Called on `serverQueue` when a handshake arrives or an active socket
    /// drops. Retry the app's advertised endpoint with bounded backoff; the
    /// app stays alive, so its camera plugin and Flutter dev session are not
    /// restarted.
    private func beginReconnect(_ target: ReconnectTarget) {
        guard !isServerStopping else { return }
        channelsLock.lock()
        let canonicalTarget = canonicalPath(target.channelPath)
        let alreadyConnected = activeChannels.contains {
            (canonicalPath($0.channelPath) == canonicalTarget || $0.bundleID == target.bundleID) && $0.isTransportConnected
        }
        channelsLock.unlock()
        guard !alreadyConnected,
              reconnectingChannelPaths.insert(target.channelPath).inserted else { return }
        reconnectTargets[target.channelPath] = target
        reconnectAttempts[target.channelPath] = 0
        scheduleReconnectAttempt(target)
    }

    private func scheduleReconnectAttempt(_ target: ReconnectTarget) {
        let path = target.channelPath
        guard reconnectingChannelPaths.contains(path), !isServerStopping else { return }
        let attempt = (reconnectAttempts[path] ?? 0) + 1
        reconnectAttempts[path] = attempt
        let delay = (attempt == 1) ? 0.05 : min(2.0, 0.15 * pow(1.5, Double(attempt - 1)))

        serverQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self,
                  self.reconnectingChannelPaths.contains(path),
                  !self.isServerStopping else { return }

            self.channelsLock.lock()
            let canonicalTarget = self.canonicalPath(path)
            let replacementExists = self.activeChannels.contains {
                (self.canonicalPath($0.channelPath) == canonicalTarget || $0.bundleID == target.bundleID) && $0.isTransportConnected
            }
            self.channelsLock.unlock()
            guard !replacementExists else {
                self.finishReconnect(path: path)
                return
            }

            let channel = ProcessChannel(
                simUDID: target.simUDID,
                bundleID: target.bundleID,
                channelPath: target.channelPath
            )
            channel.frontTransformConfig = self.frontTransformConfig
            channel.backTransformConfig = self.backTransformConfig
            self.configureCallbacks(for: channel)

            if channel.connect(), channel.isTransportConnected {
                self.finishReconnect(path: path)
                self.installConnectedChannel(channel)
                self.publishConnected(bundleID: target.bundleID, simUDID: target.simUDID)
            } else {
                self.scheduleReconnectAttempt(target)
            }
        }
    }

    private func finishReconnect(path: String) {
        reconnectingChannelPaths.remove(path)
        reconnectTargets.removeValue(forKey: path)
        reconnectAttempts.removeValue(forKey: path)
        disconnectedNotifications.remove(path)
    }

    private func scheduleDisconnectedNotification(for target: ReconnectTarget) {
        let path = target.channelPath
        serverQueue.asyncAfter(deadline: .now() + reconnectGracePeriod) { [weak self] in
            guard let self = self,
                  self.reconnectingChannelPaths.contains(path),
                  self.disconnectedNotifications.insert(path).inserted else { return }
            self.channelsLock.lock()
            let stillDisconnected = !self.activeChannels.contains { $0.bundleID == target.bundleID }
            self.channelsLock.unlock()
            if stillDisconnected { self.onClientDisconnected?(target.bundleID) }
        }
    }

    private func installConnectedChannel(_ channel: ProcessChannel) {
        channelsLock.lock()
        let channelCanonical = canonicalPath(channel.channelPath)
        let staleChannels = activeChannels.filter {
            $0 !== channel && (canonicalPath($0.channelPath) == channelCanonical || $0.bundleID == channel.bundleID)
        }
        for oldChannel in staleChannels {
            connectedChannelIDs.remove(ObjectIdentifier(oldChannel))
            oldChannel.disconnect()
        }
        activeChannels.removeAll {
            $0 !== channel && (canonicalPath($0.channelPath) == channelCanonical || $0.bundleID == channel.bundleID)
        }
        if !activeChannels.contains(where: { $0 === channel }) {
            activeChannels.append(channel)
            connectedChannelIDs.insert(ObjectIdentifier(channel))
        }
        channelsLock.unlock()
        cancelReconnects(bundleID: channel.bundleID)
    }

    private func publishConnected(bundleID: String, simUDID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onClientConnected?(bundleID, simUDID)
        }
    }

    private func startWatchingSocketDirectories() {
        for path in socketPaths {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib],
                queue: serverQueue
            )
            watcher.setEventHandler { [weak self] in
                self?.scanExistingProcessSockets()
            }
            watcher.setCancelHandler {
                close(fd)
            }
            watcher.resume()
            directoryWatchers.append(watcher)
        }
    }

    public func scanExistingProcessSockets() {
        serverQueue.async { [weak self] in
            guard let self = self, !self.isServerStopping else { return }
            let scanDirs = self.socketPaths.map { ($0 as NSString).deletingLastPathComponent }
            for dir in scanDirs {
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for file in files where file.hasSuffix(".process.socket") {
                    let fullPath = (dir as NSString).appendingPathComponent(file)
                    self.tryConnectDiscoveredSocket(at: fullPath)
                }
            }
        }
    }

    public func tryConnectDiscoveredSocket(at fullPath: String) {
        let canonicalFullPath = canonicalPath(fullPath)
        channelsLock.lock()
        let alreadyConnected = activeChannels.contains {
            (canonicalPath($0.channelPath) == canonicalFullPath || $0.channelPath == fullPath) && $0.isTransportConnected
        }
        channelsLock.unlock()
        if alreadyConnected || reconnectingChannelPaths.contains(canonicalFullPath) || reconnectingChannelPaths.contains(fullPath) {
            return
        }

        guard FileManager.default.fileExists(atPath: fullPath) else { return }

        let filename = (fullPath as NSString).lastPathComponent
        let parts = filename.split(separator: ".")

        var matchedUDID: String?
        var targetPID: Int?

        if parts.count >= 4 && parts.contains("SimCam") {
            // Format: <token>.<pid>.SimCam.process.socket
            let token = String(parts[0]).lowercased()
            if let pid = Int(parts[1]) {
                targetPID = pid
            }
            for sim in SimulatorManager.getBootedSimulators(includeRunningApps: false) {
                let clean = sim.udid.replacingOccurrences(of: "-", with: "").lowercased()
                if clean.hasPrefix(token) {
                    matchedUDID = sim.udid
                    break
                }
            }
        } else if parts.count >= 3 {
            // Format: <pid>.process.socket
            if let pid = Int(parts[0]) {
                targetPID = pid
            }
        }

        let booted = SimulatorManager.getBootedSimulators(includeRunningApps: false)
        let simUDID = matchedUDID ?? booted.first?.udid ?? "simulator"

        var bundleID = "iOS App"
        if let pid = targetPID, let app = SimulatorManager.getBundleID(forPID: pid, simUDID: simUDID) {
            bundleID = app
        } else if let cached = SimulatorManager.getCachedRunningApp(simUDID: simUDID) {
            bundleID = cached
        }

        let channel = ProcessChannel(simUDID: simUDID, bundleID: bundleID, channelPath: fullPath)
        channel.frontTransformConfig = self.frontTransformConfig
        channel.backTransformConfig = self.backTransformConfig
        self.configureCallbacks(for: channel)

        if channel.connect(), channel.isTransportConnected {
            print("[FrameHandshakeServer] Discovered and connected to active socket: \(fullPath) (bundle: \(bundleID), sim: \(simUDID))")
            SimulatorManager.recordSuccessfulHandshake(simUDID: simUDID)
            self.installConnectedChannel(channel)
            self.publishConnected(bundleID: bundleID, simUDID: simUDID)
        } else {
            // Stale or dead socket file from previous run/crash
            print("[FrameHandshakeServer] Removing stale or unresponsive socket at \(fullPath)")
            try? FileManager.default.removeItem(atPath: fullPath)
        }
    }
    
    // MARK: - MediaSourceDelegate
    public func mediaSourceDidOutputFrame(
        _ source: MediaSource,
        pixelBuffer: CVPixelBuffer?,
        image: CGImage?,
        ciImage: CIImage?
    ) {
        guard isCurrentSource(source) else { return }

        for channel in channelsSnapshot() {
            if let ciImage {
                channel.deliverCIImage(ciImage)
            } else if let pb = pixelBuffer {
                channel.deliverPixelBuffer(pb)
            } else if let img = image {
                channel.deliverCGImage(img)
            }
        }
        
        // GPU-accelerated JPEG generation for Flutter UI preview (~25 FPS) on dedicated queue
        let now = CFAbsoluteTimeGetCurrent()
        previewStateLock.lock()
        if now - lastPreviewTime > 0.04 && !isGeneratingPreview {
            lastPreviewTime = now
            isGeneratingPreview = true
            previewStateLock.unlock()
            
            var ci: CIImage?
            if let ciImage {
                ci = ciImage
            } else if let pb = pixelBuffer {
                ci = CIImage(cvPixelBuffer: pb)
            } else if let img = image {
                ci = CIImage(cgImage: img)
            }
            
            if let ci = ci {
                let config = (self.previewTargetCamera == "front") ? self.frontTransformConfig : self.backTransformConfig
                previewQueue.async { [weak self] in
                    guard let self else { return }
                    defer {
                        self.previewStateLock.lock()
                        self.isGeneratingPreview = false
                        self.previewStateLock.unlock()
                    }
                    
                    // Render through exact same transform pipeline as simulator
                    let transformed = SharedMemoryBuffer.transformToPortraitDisplay(ci, config: config)
                    
                    // Downscale preview to standard height (480px) to maximize preview fluidity
                    let targetH: CGFloat = 480.0
                    let scale = min(1.0, targetH / transformed.extent.height)
                    let previewCI = (scale < 1.0) ? transformed.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : transformed
                    
                    if let jpeg = self.ciContext.jpegRepresentation(
                        of: previewCI,
                        colorSpace: self.colorSpace,
                        options: [CIImageRepresentationOption(rawValue: "lossyCompressionFactor"): 0.7]
                    ) {
                        DispatchQueue.main.async {
                            guard self.isCurrentSource(source) else { return }
                            self.onPreviewFrame?(jpeg)
                        }
                    }
                }
            } else {
                previewStateLock.lock()
                isGeneratingPreview = false
                previewStateLock.unlock()
            }
        } else {
            previewStateLock.unlock()
        }
    }
    
    public func mediaSourceDidOutputMetadata(_ source: MediaSource, metadataObjects: [[String: Any]]) {
        guard isCurrentSource(source) else { return }
        for channel in channelsSnapshot() {
            channel.deliverMetadata(metadataObjects)
        }
    }
    
    public func setFitMode(target: String = "both", mode: String) {
        if target == "front" || target == "both" {
            frontTransformConfig.fitMode = mode
            for ch in channelsSnapshot() { ch.frontTransformConfig.fitMode = mode }
        }
        if target == "back" || target == "both" {
            backTransformConfig.fitMode = mode
            for ch in channelsSnapshot() { ch.backTransformConfig.fitMode = mode }
        }
    }
    
    public func updateTransformConfig(target: String = "both", config: TransformConfig) {
        switch target {
        case "front":
            frontTransformConfig = config
            for ch in channelsSnapshot() {
                ch.frontTransformConfig = config
            }
        case "back":
            backTransformConfig = config
            for ch in channelsSnapshot() {
                ch.backTransformConfig = config
            }
        default: // "both"
            frontTransformConfig = config
            backTransformConfig = config
            for ch in channelsSnapshot() {
                ch.frontTransformConfig = config
                ch.backTransformConfig = config
            }
        }
    }
}
