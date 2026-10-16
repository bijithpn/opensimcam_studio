import Foundation
import CoreGraphics
import CoreVideo
import CoreImage

public final class ProcessChannel {
    public let simUDID: String
    public let bundleID: String
    public let channelPath: String
    
    private var socketFD: Int32 = -1
    private let queue = DispatchQueue(label: "opensimcam.processchannel")
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    
    public var frontShm: SharedMemoryBuffer?
    public var backShm: SharedMemoryBuffer?
    
    public var isCameraActive = false
    public var activeCamera = "back"
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
        setupSharedMemory()
        sendOffer()
        startReading()
        return true
    }
    
    private func setupSharedMemory() {
        let base = (channelPath as NSString).lastPathComponent
        let parts = base.split(separator: ".")
        let pidStr = !parts.isEmpty ? String(parts[0]) : "\(ProcessInfo.processInfo.processIdentifier)"
        
        let frontPath = "/private/tmp/com.swmansion.SimCam/\(pidStr).front.stream.shm"
        let backPath = "/private/tmp/com.swmansion.SimCam/\(pidStr).back.stream.shm"
        
        do {
            frontShm = try SharedMemoryBuffer(path: frontPath, width: 1920, height: 1080, slotCount: 3)
            backShm = try SharedMemoryBuffer(path: backPath, width: 1920, height: 1080, slotCount: 3)
        } catch {
            print("[ProcessChannel] Failed to setup shared memory: \(error)")
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
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self, !self.isDisconnected else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.socketFD, &buffer, buffer.count)
            if bytesRead > 0 {
                self.readBuffer.append(buffer, count: bytesRead)
                self.processReadBuffer()
            } else if bytesRead <= 0 {
                self.disconnect()
            }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
                self?.socketFD = -1
            }
        }
        self.readSource = source
        source.resume()
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
            activeCamera = cam
            isCameraActive = true
            sendOffer()
            onCameraStateChanged?(true, activeCamera)
        case "stop":
            isCameraActive = false
            onCameraStateChanged?(false, activeCamera)
        default:
            break
        }
    }
    
    public func deliverPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard !isDisconnected, socketFD >= 0 else { return }
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
        guard !isDisconnected, socketFD >= 0 else { return }
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
        guard !isDisconnected, socketFD >= 0 else { return }
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
        guard !isDisconnected, socketFD >= 0 else { return }
        let metaMsg: [String: Any] = [
            "type": "metadata",
            "objects": objects
        ]
        sendJSON(metaMsg)
    }
    
    private func sendJSON(_ obj: [String: Any]) {
        guard !isDisconnected, socketFD >= 0,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var packet = data
        packet.append(0x0a)
        let written = packet.withUnsafeBytes { rawPtr in
            write(socketFD, rawPtr.baseAddress!, packet.count)
        }
        if written <= 0 {
            disconnect()
        }
    }
    
    public func disconnect() {
        guard !isDisconnected else { return }
        isDisconnected = true
        isCameraActive = false
        
        if let source = readSource {
            source.cancel()
            readSource = nil
        }
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
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
