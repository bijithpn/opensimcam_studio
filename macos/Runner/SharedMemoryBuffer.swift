import Foundation
import CoreVideo
import CoreGraphics
import CoreImage

public final class SharedMemoryBuffer {
    public let path: String
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let frameSize: Int
    public let slotCount: Int
    public let totalSize: Int
    
    private var fileDescriptor: Int32 = -1
    private var mappedMemory: UnsafeMutableRawPointer?
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    
    public init(path: String, width: Int = 1080, height: Int = 1920, slotCount: Int = 3) throws {
        self.path = path
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.frameSize = self.bytesPerRow * height
        self.slotCount = slotCount
        self.totalSize = self.frameSize * slotCount
        
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        
        fileDescriptor = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o666)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to open shm file: \(path)"])
        }
        
        if ftruncate(fileDescriptor, off_t(totalSize)) != 0 {
            close(fileDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to ftruncate shm file: \(path)"])
        }
        
        mappedMemory = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0)
        guard mappedMemory != MAP_FAILED, let mapped = mappedMemory else {
            close(fileDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "mmap failed for \(path)"])
        }
        
        // Fill initial buffer with black background
        memset(mapped, 0, totalSize)
        for slot in 0..<slotCount {
            let slotPtr = mapped.advanced(by: slot * frameSize).assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 3, to: frameSize, by: 4) {
                slotPtr[i] = 255
            }
        }
    }
    
    deinit {
        if let mapped = mappedMemory {
            munmap(mapped, totalSize)
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }
    
    public func renderCIImage(_ ciImage: CIImage, slot: Int, fitMode: String = "fill") {
        guard let mapped = mappedMemory, slot >= 0 && slot < slotCount else { return }
        let destSlot = mapped.advanced(by: slot * frameSize)
        
        let srcW = ciImage.extent.width
        let srcH = ciImage.extent.height
        guard srcW > 0, srcH > 0 else { return }
        
        let scaleX = CGFloat(width) / srcW
        let scaleY = CGFloat(height) / srcH
        let scale = (fitMode == "fit") ? min(scaleX, scaleY) : max(scaleX, scaleY)
        
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledW = scaledImage.extent.width
        let scaledH = scaledImage.extent.height
        
        // Center inside the 1080x1920 viewport
        let offsetX = (CGFloat(width) - scaledW) / 2.0
        let offsetY = (CGFloat(height) - scaledH) / 2.0
        let centeredImage = scaledImage.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        
        let targetBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let outputImage: CIImage
        if fitMode == "fit" {
            let blackBg = CIImage(color: CIColor.black).cropped(to: targetBounds)
            outputImage = centeredImage.composited(over: blackBg)
        } else {
            outputImage = centeredImage.cropped(to: targetBounds)
        }
        
        ciContext.render(
            outputImage,
            toBitmap: destSlot,
            rowBytes: bytesPerRow,
            bounds: targetBounds,
            format: .BGRA8,
            colorSpace: colorSpace
        )
    }
    
    public func writePixelBuffer(_ pixelBuffer: CVPixelBuffer, slot: Int, fitMode: String = "fill") {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        renderCIImage(ciImage, slot: slot, fitMode: fitMode)
    }
    
    public func writeCGImage(_ image: CGImage, slot: Int, fitMode: String = "fill") {
        let ciImage = CIImage(cgImage: image)
        renderCIImage(ciImage, slot: slot, fitMode: fitMode)
    }
}
