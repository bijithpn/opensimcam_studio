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
    private let serverQueue = DispatchQueue(label: "opensc.handshakeserver")
    
    private var activeChannels: [ProcessChannel] = []
    private let channelsLock = NSLock()
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
    
    private init() {}
    
    public func start() {
        for path in socketPaths {
            try? startListening(at: path)
        }
    }
    
    public func stop() {
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
        
        let channel = ProcessChannel(simUDID: simUDID, bundleID: bundleID, channelPath: channelPath)
        channel.frontTransformConfig = frontTransformConfig
        channel.backTransformConfig = backTransformConfig
        
        channel.onDisconnected = { [weak self, weak channel] ch in
            guard let self = self, let channel = channel else { return }
            self.serverQueue.async {
                self.channelsLock.lock()
                self.activeChannels.removeAll { $0 === channel }
                let replacementExists = self.activeChannels.contains { $0.bundleID == channel.bundleID }
                self.channelsLock.unlock()
                guard !replacementExists else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // A replacement may have connected after the removal was
                    // queued. Re-check on the server queue before publishing.
                    self.serverQueue.async {
                        self.channelsLock.lock()
                        let stillDisconnected = !self.activeChannels.contains { $0.bundleID == channel.bundleID }
                        self.channelsLock.unlock()
                        if stillDisconnected { self.onClientDisconnected?(channel.bundleID) }
                    }
                }
            }
        }
        
        channel.onCameraStateChanged = { [weak self, weak channel] isActive, cam in
            guard let self = self, let channel = channel else { return }
            self.serverQueue.async {
                self.channelsLock.lock()
                let isCurrentChannel = self.activeChannels.contains { $0 === channel }
                self.channelsLock.unlock()
                guard isCurrentChannel else { return }
                DispatchQueue.main.async {
                    self.onCameraStateChanged?(channel.bundleID, isActive, cam)
                }
            }
        }
        
        if channel.connect() {
            // Disconnect and remove any stale channel with same channelPath or bundleID.
            // A late disconnect callback from one of these is suppressed if
            // this replacement is already active.
            channelsLock.lock()
            for oldCh in activeChannels where oldCh.channelPath == channelPath || oldCh.bundleID == bundleID {
                oldCh.disconnect()
            }
            activeChannels.removeAll { $0.channelPath == channelPath || $0.bundleID == bundleID }
            activeChannels.append(channel)
            channelsLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onClientConnected?(bundleID, simUDID)
            }
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
