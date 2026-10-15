import Foundation
import CoreVideo
import CoreGraphics
import CoreImage

public struct TransformConfig {
    public var fitMode: String = "fill"
    public var zoom: CGFloat = 1.0
    public var offsetX: CGFloat = 0.0
    public var offsetY: CGFloat = 0.0
    public var rotation: Int = 0 // 0, 90, 180, 270
    public var mirror: Bool = false
    
    public init(
        fitMode: String = "fill",
        zoom: CGFloat = 1.0,
        offsetX: CGFloat = 0.0,
        offsetY: CGFloat = 0.0,
        rotation: Int = 0,
        mirror: Bool = false
    ) {
        self.fitMode = fitMode
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotation = rotation
        self.mirror = mirror
    }
}

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
    
    public static func transformToPortraitDisplay(_ ciImage: CIImage, config: TransformConfig) -> CIImage {
        // 1. Normalize origin so extent starts at (0, 0)
        let origX = ciImage.extent.origin.x
        let origY = ciImage.extent.origin.y
        var baseImage = ciImage.transformed(by: CGAffineTransform(translationX: -origX, y: -origY))
        
        // 2. Mirror (Selfie horizontal flip)
        if config.mirror {
            let flip = CGAffineTransform(scaleX: -1.0, y: 1.0)
                .concatenating(CGAffineTransform(translationX: baseImage.extent.width, y: 0.0))
            baseImage = baseImage.transformed(by: flip)
        }
        
        // 3. User-requested orientation / rotation adjustments
        if config.rotation == 90 {
            let rot = baseImage.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            baseImage = rot.transformed(by: CGAffineTransform(translationX: -rot.extent.origin.x, y: -rot.extent.origin.y))
        } else if config.rotation == 180 {
            let rot = baseImage.transformed(by: CGAffineTransform(rotationAngle: .pi))
            baseImage = rot.transformed(by: CGAffineTransform(translationX: -rot.extent.origin.x, y: -rot.extent.origin.y))
        } else if config.rotation == 270 {
            let rot = baseImage.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            baseImage = rot.transformed(by: CGAffineTransform(translationX: -rot.extent.origin.x, y: -rot.extent.origin.y))
        }
        
        let srcW = baseImage.extent.width
        let srcH = baseImage.extent.height
        guard srcW > 0, srcH > 0 else { return baseImage }
        
        // 4. Target standard portrait display (1080x1920)
        let targetDisplayW: CGFloat = 1080.0
        let targetDisplayH: CGFloat = 1920.0
        
        let scaleX = targetDisplayW / srcW
        let scaleY = targetDisplayH / srcH
        
        var baseScaleX: CGFloat
        var baseScaleY: CGFloat
        
        if config.fitMode == "stretch" {
            baseScaleX = scaleX
            baseScaleY = scaleY
        } else if config.fitMode == "fit" {
            let s = min(scaleX, scaleY)
            baseScaleX = s
            baseScaleY = s
        } else {
            // Default "fill" (Cover 9:16)
            let s = max(scaleX, scaleY)
            baseScaleX = s
            baseScaleY = s
        }
        
        // 5. Apply user zoom (clamped between 0.25x and 5.0x)
        let safeZoom = max(0.25, min(5.0, config.zoom))
        let finalScaleX = baseScaleX * safeZoom
        let finalScaleY = baseScaleY * safeZoom
        
        let scaledW = srcW * finalScaleX
        let scaledH = srcH * finalScaleY
        
        // 6. User Pan / Offset (config.offsetX and config.offsetY in range -1.0 to 1.0)
        let panX = config.offsetX * (targetDisplayW * 0.5)
        let panY = config.offsetY * (targetDisplayH * 0.5)
        
        let posX = (targetDisplayW - scaledW) / 2.0 + panX
        let posY = (targetDisplayH - scaledH) / 2.0 + panY
        
        let transform = CGAffineTransform(scaleX: finalScaleX, y: finalScaleY)
            .concatenating(CGAffineTransform(translationX: posX, y: posY))
        
        let scaledImage = baseImage.transformed(by: transform)
        let displayBounds = CGRect(x: 0, y: 0, width: targetDisplayW, height: targetDisplayH)
        let blackBg = CIImage(color: CIColor.black).cropped(to: displayBounds)
        return scaledImage.composited(over: blackBg).cropped(to: displayBounds)
    }
    
    public func renderCIImage(_ ciImage: CIImage, slot: Int, config: TransformConfig = TransformConfig()) {
        lock.lock()
        defer { lock.unlock() }
        guard let mapped = mappedMemory, slot >= 0 && slot < slotCount else { return }
        let destSlot = mapped.advanced(by: slot * frameSize)
        
        let uprightPortraitImage = SharedMemoryBuffer.transformToPortraitDisplay(ciImage, config: config)
        
        // Map into sensor coordinate space
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
    
    public func writePixelBuffer(_ pixelBuffer: CVPixelBuffer, slot: Int, config: TransformConfig = TransformConfig()) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        renderCIImage(ciImage, slot: slot, config: config)
    }
    
    public func writeCGImage(_ image: CGImage, slot: Int, config: TransformConfig = TransformConfig()) {
        let ciImage = CIImage(cgImage: image)
        renderCIImage(ciImage, slot: slot, config: config)
    }
    
    // Backward compatibility overloads
    public func writePixelBuffer(_ pixelBuffer: CVPixelBuffer, slot: Int, fitMode: String) {
        writePixelBuffer(pixelBuffer, slot: slot, config: TransformConfig(fitMode: fitMode))
    }
    
    public func writeCGImage(_ image: CGImage, slot: Int, fitMode: String) {
        writeCGImage(image, slot: slot, config: TransformConfig(fitMode: fitMode))
    }
}
