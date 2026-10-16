import Foundation
import CoreGraphics
import CoreVideo
import CoreImage

public final class ProcessChannel {
    public let simUDID: String
    public let bundleID: String
    public let channelPath: String
    
    private var socketFD: Int32 = -1
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "opensc.processchannel")
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    
    public var frontShm: SharedMemoryBuffer?
    public var backShm: SharedMemoryBuffer?
    
    private var isCameraActive = false
    private var activeCamera = "back"
    private let transformLock = NSLock()
    private var storedFrontTransformConfig = TransformConfig(fitMode: "fill", zoom: 1.0, offsetX: 0.0, offsetY: 0.0, rotation: 0, mirror: true)
    private var storedBackTransformConfig = TransformConfig(fitMode: "fill", zoom: 1.0, offsetX: 0.0, offsetY: 0.0, rotation: 0, mirror: false)
    public var frontTransformConfig: TransformConfig {
        get {
            transformLock.lock()
            defer { transformLock.unlock() }
            return storedFrontTransformConfig
        }
        set {
            transformLock.lock()
            storedFrontTransformConfig = newValue
            transformLock.unlock()
        }
    }
    public var backTransformConfig: TransformConfig {
        get {
            transformLock.lock()
            defer { transformLock.unlock() }
            return storedBackTransformConfig
        }
        set {
            transformLock.lock()
            storedBackTransformConfig = newValue
            transformLock.unlock()
        }
    }
    
    public var onDisconnected: ((ProcessChannel) -> Void)?
    public var onCameraStateChanged: ((Bool, String) -> Void)?
    private var isDisconnected = false
    private var currentSlotIndex = 0
    
    public init(simUDID: String, bundleID: String, channelPath: String) {
        self.simUDID = simUDID
        self.bundleID = bundleID
        self.channelPath = channelPath
    }
    
    public func connect() -> Bool {
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            return false
        }
        
        var nosigpipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = channelPath.utf8CString
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(socketFD)
            return false
        }
        
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, addrLen)
            }
        }
        
        guard connectRes == 0 else {
            close(socketFD)
            socketFD = -1
            return false
        }
        
        print("[ProcessChannel] Connected to app '\(bundleID)' in simulator '\(simUDID)'")
        guard setupSharedMemory() else {
            disconnect()
            return false
        }
        startReading()
        // Install the read source before writing. A fast client teardown can
        // make the first offer fail; disconnect then closes the descriptor.
        // Starting the source afterwards would pass -1 to DispatchSource.
        sendOffer()
        return true
    }
    
    private func setupSharedMemory() -> Bool {
        let base = (channelPath as NSString).lastPathComponent
        let parts = base.split(separator: ".")
        let pidStr = !parts.isEmpty ? String(parts[0]) : "\(ProcessInfo.processInfo.processIdentifier)"
        
        let frontPath = "/private/tmp/com.swmansion.SimCam/\(pidStr).front.stream.shm"
        let backPath = "/private/tmp/com.swmansion.SimCam/\(pidStr).back.stream.shm"
        
        do {
            frontShm = try SharedMemoryBuffer(path: frontPath, width: 1920, height: 1080, slotCount: 3)
            backShm = try SharedMemoryBuffer(path: backPath, width: 1920, height: 1080, slotCount: 3)
            return true
        } catch {
            print("[ProcessChannel] Failed to setup shared memory: \(error)")
            frontShm = nil
            backShm = nil
            return false
        }
    }
    
    public func sendOffer() {
        if let fShm = frontShm {
            let frontOffer: [String: Any] = [
                "type": "offer",
                "camera": "front",
                "shmPath": fShm.path,
                "count": fShm.slotCount,
                "frameSize": fShm.frameSize,
                "bytesPerRow": fShm.bytesPerRow,
                "width": fShm.width,
                "height": fShm.height,
                "metadataTypes": ["org.iso.QRCode"]
            ]
            sendJSON(frontOffer)
        }
        
        if let bShm = backShm {
            let backOffer: [String: Any] = [
                "type": "offer",
                "camera": "back",
                "shmPath": bShm.path,
                "count": bShm.slotCount,
                "frameSize": bShm.frameSize,
                "bytesPerRow": bShm.bytesPerRow,
                "width": bShm.width,
                "height": bShm.height,
                "metadataTypes": ["org.iso.QRCode"]
            ]
            sendJSON(backOffer)
        }
    }
    
    private func startReading() {
        stateLock.lock()
        let descriptor = socketFD
        let disconnected = isDisconnected
        stateLock.unlock()
        guard descriptor >= 0, !disconnected else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self, !self.isTransportDisconnected else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(descriptor, &buffer, buffer.count)
            if bytesRead > 0 {
                self.readBuffer.append(buffer, count: bytesRead)
                self.processReadBuffer()
            } else if bytesRead < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else if bytesRead <= 0 {
                self.disconnect()
            }
        }
        // Wait for any in-flight read handler to finish before closing this
        // descriptor, avoiding a close/reuse race with another process socket.
        source.setCancelHandler { close(descriptor) }
        self.readSource = source
        source.resume()
    }

    private var isTransportDisconnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isDisconnected
    }

    public func cameraStateSnapshot() -> (isActive: Bool, camera: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (isCameraActive, activeCamera)
    }
    
    private func processReadBuffer() {
        while let newlineIndex = readBuffer.firstIndex(of: 0x0a) {
            let lineData = readBuffer.subdata(in: 0..<newlineIndex)
            readBuffer.removeSubrange(0...newlineIndex)
            if lineData.isEmpty { continue }
            handleIncomingMessage(lineData)
        }
    }
    
    private func handleIncomingMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        switch type {
        case "start":
            let cam = json["camera"] as? String ?? "back"
            stateLock.lock()
            activeCamera = cam
            isCameraActive = true
            stateLock.unlock()
            sendOffer()
            onCameraStateChanged?(true, cam)
        case "stop":
            stateLock.lock()
            isCameraActive = false
            let camera = activeCamera
            stateLock.unlock()
            onCameraStateChanged?(false, camera)
        default:
            break
        }
    }
    
    public func deliverPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard !isTransportDisconnected else { return }
        currentSlotIndex = (currentSlotIndex + 1) % 3
        
        // Feed back camera
        if let bShm = backShm {
            bShm.writePixelBuffer(pixelBuffer, slot: currentSlotIndex, config: backTransformConfig)
            let backMsg: [String: Any] = [
                "type": "frame",
                "camera": "back",
                "index": currentSlotIndex,
                "sourceMirrorCompensation": false
            ]
            sendJSON(backMsg)
        }
        
        // Feed front camera
        if let fShm = frontShm {
            fShm.writePixelBuffer(pixelBuffer, slot: currentSlotIndex, config: frontTransformConfig)
            let frontMsg: [String: Any] = [
                "type": "frame",
                "camera": "front",
                "index": currentSlotIndex,
                "sourceMirrorCompensation": true
            ]
            sendJSON(frontMsg)
        }
    }
    
    public func deliverCGImage(_ image: CGImage) {
        guard !isTransportDisconnected else { return }
        currentSlotIndex = (currentSlotIndex + 1) % 3
        
        // Feed back camera
        if let bShm = backShm {
            bShm.writeCGImage(image, slot: currentSlotIndex, config: backTransformConfig)
            let backMsg: [String: Any] = [
                "type": "frame",
                "camera": "back",
                "index": currentSlotIndex,
                "sourceMirrorCompensation": false
            ]
            sendJSON(backMsg)
        }
        
        // Feed front camera
        if let fShm = frontShm {
            fShm.writeCGImage(image, slot: currentSlotIndex, config: frontTransformConfig)
            let frontMsg: [String: Any] = [
                "type": "frame",
                "camera": "front",
                "index": currentSlotIndex,
                "sourceMirrorCompensation": true
            ]
            sendJSON(frontMsg)
        }
    }

    public func deliverCIImage(_ image: CIImage) {
        guard !isTransportDisconnected else { return }
        currentSlotIndex = (currentSlotIndex + 1) % 3

        if let bShm = backShm {
            bShm.writeCIImage(image, slot: currentSlotIndex, config: backTransformConfig)
            sendJSON([
                "type": "frame",
                "camera": "back",
                "index": currentSlotIndex,
                "sourceMirrorCompensation": false
            ])
        }

        if let fShm = frontShm {
            fShm.writeCIImage(image, slot: currentSlotIndex, config: frontTransformConfig)
            sendJSON([
                "type": "frame",
                "camera": "front",
                "index": currentSlotIndex,
                "sourceMirrorCompensation": true
            ])
        }
    }
    
    public func deliverMetadata(_ objects: [[String: Any]]) {
        guard !isTransportDisconnected else { return }
        let metaMsg: [String: Any] = [
            "type": "metadata",
            "objects": objects
        ]
        sendJSON(metaMsg)
    }
    
    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var packet = data
        packet.append(0x0a)
        stateLock.lock()
        guard !isDisconnected, socketFD >= 0 else {
            stateLock.unlock()
            return
        }
        let descriptor = socketFD
        let succeeded = packet.withUnsafeBytes { rawPtr -> Bool in
            guard let baseAddress = rawPtr.baseAddress else { return false }
            var offset = 0
            while offset < packet.count {
                let written = write(descriptor, baseAddress.advanced(by: offset), packet.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        stateLock.unlock()
        if !succeeded { disconnect() }
    }
    
    public func disconnect() {
        stateLock.lock()
        guard !isDisconnected else {
            stateLock.unlock()
            return
        }
        isDisconnected = true
        isCameraActive = false
        let descriptor = socketFD
        socketFD = -1
        stateLock.unlock()
        
        if let source = readSource {
            source.cancel()
            readSource = nil
        } else if descriptor >= 0 {
            close(descriptor)
        }
        
        if let fPath = frontShm?.path {
            frontShm = nil
            unlink(fPath)
        }
        if let bPath = backShm?.path {
            backShm = nil
            unlink(bPath)
        }
        
        print("[ProcessChannel] Disconnected from app '\(bundleID)' in simulator '\(simUDID)'")
        onDisconnected?(self)
    }
}
