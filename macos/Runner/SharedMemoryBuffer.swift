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
    private let lock = NSLock()
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    
    public init(path: String, width: Int = 1920, height: Int = 1080, slotCount: Int = 3) throws {
        self.path = path
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.frameSize = self.bytesPerRow * height
        self.slotCount = slotCount
        self.totalSize = self.frameSize * slotCount
        
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        
        fileDescriptor = open(path, O_RDWR | O_CREAT, 0o666)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to open shm file: \(path)"])
        }
        
        var st = stat()
        if fstat(fileDescriptor, &st) == 0 && st.st_size < off_t(totalSize) {
            _ = ftruncate(fileDescriptor, off_t(totalSize))
        }
        
        mappedMemory = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0)
        guard mappedMemory != MAP_FAILED, let mapped = mappedMemory else {
            close(fileDescriptor)
            fileDescriptor = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "mmap failed for \(path)"])
        }
        
        // Fill initial buffer with black background if newly created
        if st.st_size < off_t(totalSize) {
            memset(mapped, 0, totalSize)
            for slot in 0..<slotCount {
                let slotPtr = mapped.advanced(by: slot * frameSize).assumingMemoryBound(to: UInt8.self)
                for i in stride(from: 3, to: frameSize, by: 4) {
                    slotPtr[i] = 255
                }
            }
        }
    }
    
    deinit {
        lock.lock()
        if let mapped = mappedMemory {
            munmap(mapped, totalSize)
            mappedMemory = nil
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        lock.unlock()
    }
    
    public func renderCIImage(_ ciImage: CIImage, slot: Int, fitMode: String = "fill") {
        lock.lock()
        defer { lock.unlock() }
        guard let mapped = mappedMemory, slot >= 0 && slot < slotCount else { return }
        let destSlot = mapped.advanced(by: slot * frameSize)
        
        // 1. Normalize origin so extent starts at (0, 0)
        let origX = ciImage.extent.origin.x
        let origY = ciImage.extent.origin.y
        var baseImage = ciImage.transformed(by: CGAffineTransform(translationX: -origX, y: -origY))
        
        // 2. User-requested orientation / rotation adjustments
        if fitMode == "rotate90" {
            let rot = baseImage.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            baseImage = rot.transformed(by: CGAffineTransform(translationX: -rot.extent.origin.x, y: -rot.extent.origin.y))
        } else if fitMode == "rotate180" {
            let rot = baseImage.transformed(by: CGAffineTransform(rotationAngle: .pi))
            baseImage = rot.transformed(by: CGAffineTransform(translationX: -rot.extent.origin.x, y: -rot.extent.origin.y))
        } else if fitMode == "rotate270" {
            let rot = baseImage.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            baseImage = rot.transformed(by: CGAffineTransform(translationX: -rot.extent.origin.x, y: -rot.extent.origin.y))
        }
        
        let srcW = baseImage.extent.width
        let srcH = baseImage.extent.height
        guard srcW > 0, srcH > 0 else { return }
        
        // 3. Frame image for standard portrait device display (1080x1920)
        let targetDisplayW: CGFloat = 1080.0
        let targetDisplayH: CGFloat = 1920.0
        
        let scaleX = targetDisplayW / srcW
        let scaleY = targetDisplayH / srcH
        
        let transform: CGAffineTransform
        if fitMode == "stretch" {
            // Stretch to 1080x1920
            transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        } else if fitMode == "fit" {
            // Contain / Letterbox with black bars
            let scale = min(scaleX, scaleY)
            let scaledW = srcW * scale
            let scaledH = srcH * scale
            let offsetX = (targetDisplayW - scaledW) / 2.0
            let offsetY = (targetDisplayH - scaledH) / 2.0
            transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        } else {
            // Default "fill" (Cover 9:16) & all rotation modes:
            // Scales to completely fill the 1080x1920 portrait screen edge-to-edge
            let scale = max(scaleX, scaleY)
            let scaledW = srcW * scale
            let scaledH = srcH * scale
            let offsetX = (targetDisplayW - scaledW) / 2.0
            let offsetY = (targetDisplayH - scaledH) / 2.0
            transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        }
        
        let scaledImage = baseImage.transformed(by: transform)
        let displayBounds = CGRect(x: 0, y: 0, width: targetDisplayW, height: targetDisplayH)
        let blackBg = CIImage(color: CIColor.black).cropped(to: displayBounds)
        let uprightPortraitImage = scaledImage.composited(over: blackBg).cropped(to: displayBounds)
        
        // 4. Map into the 1920x1080 camera sensor coordinate space by applying .oriented(.left)
        // In AVFoundation, camera sensors are physically mounted in landscape (1920x1080).
        // SimCam/AVFoundation automatically applies .oriented(.right) when apps read portrait video.
        // Since .oriented(.left) followed by .oriented(.right) is the identity transform (360°),
        // the final camera feed inside the Simulator is 100% upright, distortion-free, and properly oriented!
        let sensorImage = uprightPortraitImage.oriented(.left)
        let sensorBounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        
        ciContext.render(
            sensorImage,
            toBitmap: destSlot,
            rowBytes: bytesPerRow,
            bounds: sensorBounds,
            format: .BGRA8,
            colorSpace: colorSpace
        )
    }
    
    public func writePixelBuffer(_ pixelBuffer: CVPixelBuffer, slot: Int, fitMode: String = "fit") {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        renderCIImage(ciImage, slot: slot, fitMode: fitMode)
    }
    
    public func writeCGImage(_ image: CGImage, slot: Int, fitMode: String = "fit") {
        let ciImage = CIImage(cgImage: image)
        renderCIImage(ciImage, slot: slot, fitMode: fitMode)
    }
}
