import Foundation
import CoreGraphics
import CoreVideo

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
    public var activeCamera = "front"
    public var fitMode = "fill"
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
            frontShm = try SharedMemoryBuffer(path: frontPath, width: 1080, height: 1920, slotCount: 3)
            backShm = try SharedMemoryBuffer(path: backPath, width: 1080, height: 1920, slotCount: 3)
        } catch {
            print("[ProcessChannel] Failed to setup shared memory: \(error)")
        }
    }
    
    public func sendOffer() {
        guard let shm = (activeCamera == "back") ? (backShm ?? frontShm) : frontShm else { return }
        let offer: [String: Any] = [
            "type": "offer",
            "shmPath": shm.path,
            "count": shm.slotCount,
            "frameSize": shm.frameSize,
            "bytesPerRow": shm.bytesPerRow,
            "width": shm.width,
            "height": shm.height,
            "metadataTypes": ["org.iso.QRCode"]
        ]
        sendJSON(offer)
    }
    
    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
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
            let cam = json["camera"] as? String ?? "front"
            activeCamera = cam
            isCameraActive = true
            sendOffer()
        case "stop":
            isCameraActive = false
        default:
            break
        }
    }
    
    public func deliverPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let shm = (activeCamera == "back") ? (backShm ?? frontShm) : frontShm
        guard let buffer = shm else { return }
        
        currentSlotIndex = (currentSlotIndex + 1) % buffer.slotCount
        buffer.writePixelBuffer(pixelBuffer, slot: currentSlotIndex, fitMode: fitMode)
        
        let frameMsg: [String: Any] = [
            "type": "frame",
            "index": currentSlotIndex,
            "sourceMirrorCompensation": false
        ]
        sendJSON(frameMsg)
    }
    
    public func deliverCGImage(_ image: CGImage) {
        let shm = (activeCamera == "back") ? (backShm ?? frontShm) : frontShm
        guard let buffer = shm else { return }
        
        currentSlotIndex = (currentSlotIndex + 1) % buffer.slotCount
        buffer.writeCGImage(image, slot: currentSlotIndex, fitMode: fitMode)
        
        let frameMsg: [String: Any] = [
            "type": "frame",
            "index": currentSlotIndex,
            "sourceMirrorCompensation": false
        ]
        sendJSON(frameMsg)
    }
    
    public func deliverMetadata(_ objects: [[String: Any]]) {
        let metaMsg: [String: Any] = [
            "type": "metadata",
            "objects": objects
        ]
        sendJSON(metaMsg)
    }
    
    private func sendJSON(_ obj: [String: Any]) {
        guard socketFD >= 0,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var packet = data
        packet.append(0x0a)
        packet.withUnsafeBytes { rawPtr in
            _ = write(socketFD, rawPtr.baseAddress!, packet.count)
        }
    }
    
    public func disconnect() {
        readSource?.cancel()
        readSource = nil
        isCameraActive = false
    }
}
