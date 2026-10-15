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
    private let serverQueue = DispatchQueue(label: "opensimcam.handshakeserver")
    
    public private(set) var activeChannels: [ProcessChannel] = []
    public var onPreviewFrame: ((Data) -> Void)?
    public var onClientConnected: ((String, String) -> Void)?
    public var onClientDisconnected: ((String) -> Void)?
    
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let previewQueue = DispatchQueue(label: "opensimcam.preview.queue", qos: .userInteractive)
    private var isGeneratingPreview = false
    private var lastPreviewTime: CFAbsoluteTime = 0
    public var currentFitMode = "fill"
    
    public var currentMediaSource: MediaSource? {
        didSet {
            oldValue?.stop()
            currentMediaSource?.delegate = self
            currentMediaSource?.start()
        }
    }
    
    private init() {}
    
    public func start() {
        for path in socketPaths {
            try? startListening(at: path)
        }
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
        
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientFD, &buffer, buffer.count)
        close(clientFD)
        
        guard bytesRead > 0 else { return }
        let data = Data(buffer[0..<bytesRead])
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "handshake",
              let simUDID = json["simUDID"] as? String,
              let bundleID = json["bundleID"] as? String,
              let channelPath = json["channelPath"] as? String else {
            return
        }
        
        let channel = ProcessChannel(simUDID: simUDID, bundleID: bundleID, channelPath: channelPath)
        channel.fitMode = currentFitMode
        if channel.connect() {
            activeChannels.removeAll { $0.channelPath == channelPath }
            activeChannels.append(channel)
            DispatchQueue.main.async { [weak self] in
                self?.onClientConnected?(bundleID, simUDID)
            }
        }
    }
    
    // MARK: - MediaSourceDelegate
    public func mediaSourceDidOutputFrame(_ source: MediaSource, pixelBuffer: CVPixelBuffer?, image: CGImage?) {
        for channel in activeChannels {
            if let pb = pixelBuffer {
                channel.deliverPixelBuffer(pb)
            } else if let img = image {
                channel.deliverCGImage(img)
            }
        }
        
        // GPU-accelerated JPEG generation for Flutter UI preview (~25 FPS) on dedicated queue
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPreviewTime > 0.04 && !isGeneratingPreview {
            lastPreviewTime = now
            isGeneratingPreview = true
            
            var ci: CIImage?
            if let pb = pixelBuffer {
                ci = CIImage(cvPixelBuffer: pb)
            } else if let img = image {
                ci = CIImage(cgImage: img)
            }
            
            if let ci = ci {
                previewQueue.async { [weak self] in
                    defer { self?.isGeneratingPreview = false }
                    guard let self = self else { return }
                    
                    // Downscale preview to standard height (720px) to maximize preview fluidity
                    let targetH: CGFloat = 720.0
                    let scale = min(1.0, targetH / ci.extent.height)
                    let previewCI = (scale < 1.0) ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
                    
                    if let jpeg = self.ciContext.jpegRepresentation(
                        of: previewCI,
                        colorSpace: self.colorSpace,
                        options: [CIImageRepresentationOption(rawValue: "lossyCompressionFactor"): 0.7]
                    ) {
                        DispatchQueue.main.async {
                            self.onPreviewFrame?(jpeg)
                        }
                    }
                }
            } else {
                isGeneratingPreview = false
            }
        }
    }
    
    public func mediaSourceDidOutputMetadata(_ source: MediaSource, metadataObjects: [[String: Any]]) {
        for channel in activeChannels {
            channel.deliverMetadata(metadataObjects)
        }
    }
    
    public func setFitMode(_ mode: String) {
        currentFitMode = mode
        for ch in activeChannels {
            ch.fitMode = mode
        }
    }
}
