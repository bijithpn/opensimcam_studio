import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import AppKit
import ScreenCaptureKit

public protocol MediaSourceDelegate: AnyObject {
    func mediaSourceDidOutputFrame(_ source: MediaSource, pixelBuffer: CVPixelBuffer?, image: CGImage?)
    func mediaSourceDidOutputMetadata(_ source: MediaSource, metadataObjects: [[String: Any]])
}

public protocol MediaSource: AnyObject {
    var delegate: MediaSourceDelegate? { get set }
    func start()
    func stop()
}

// MARK: - Passthrough Mode (Mac Screen Behind Simulator Window)
public final class PassthroughSource: MediaSource {
    public weak var delegate: MediaSourceDelegate?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "opensimcam.passthrough.queue")
    private let fps: Double
    private var isCapturing = false
    
    public init(fps: Double = 30.0) {
        self.fps = fps
    }
    
    public func start() {
        if #available(macOS 10.15, *) {
            guard CGPreflightScreenCaptureAccess() else {
                print("[PassthroughSource] Screen capture permission not granted. Not starting timer.")
                return
            }
        }
        
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = 1.0 / self.fps
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in
                self?.captureTick()
            }
            self.timer = timer
            timer.resume()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }
    
    private func captureTick() {
        if #available(macOS 10.15, *) {
            guard CGPreflightScreenCaptureAccess() else {
                stop()
                return
            }
        }
        guard !isCapturing else { return }
        isCapturing = true
        
        Task { [weak self] in
            defer { self?.isCapturing = false }
            guard let self = self else { return }
            
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { return }
                
                // Find Simulator window
                let simWindow = content.windows.first {
                    ($0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator" ||
                     $0.owningApplication?.applicationName == "Simulator") &&
                    $0.frame.width > 200 && $0.frame.height > 400
                }
                
                let targetRect: CGRect
                let excludingWindows: [SCWindow]
                
                if let sim = simWindow {
                    targetRect = sim.frame
                    excludingWindows = [sim]
                } else {
                    // Fallback to center screen if simulator hidden
                    let dw = display.frame.width
                    let dh = display.frame.height
                    targetRect = CGRect(x: dw * 0.3, y: dh * 0.1, width: dw * 0.4, height: dh * 0.8)
                    excludingWindows = []
                }
                
                let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
                let config = SCStreamConfiguration()
                config.sourceRect = targetRect
                config.width = 1080
                config.height = 1920
                config.showsCursor = false
                
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                self.delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: cgImage)
            } catch {
                // Ignore transient frame capture errors
            }
        }
    }
}

// MARK: - Real Mac Camera Source
public final class CameraSource: NSObject, MediaSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public weak var delegate: MediaSourceDelegate?
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "opensimcam.camera.queue")
    private var isRunning = false
    private let preferredDeviceID: String?
    
    public init(preferredDeviceID: String? = nil) {
        self.preferredDeviceID = preferredDeviceID
        super.init()
    }
    
    public func start() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authStatus == .authorized {
            startSession()
        } else if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.startSession()
                } else {
                    print("[CameraSource] Camera permission denied by user")
                }
            }
        } else {
            print("[CameraSource] Camera access is not authorized (\(authStatus.rawValue))")
        }
    }
    
    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.setupCaptureSession()
            self.captureSession.startRunning()
            self.isRunning = true
            print("[CameraSource] Camera session started running")
        }
    }
    
    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.captureSession.stopRunning()
            self.isRunning = false
            print("[CameraSource] Camera session stopped")
        }
    }
    
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        
        var cameraDevice: AVCaptureDevice?
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        }
        if #available(macOS 13.0, *) {
            deviceTypes.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        if let id = preferredDeviceID {
            cameraDevice = discovery.devices.first(where: { $0.uniqueID == id })
        }
        if cameraDevice == nil {
            cameraDevice = discovery.devices.first
        }
        
        guard let device = cameraDevice else {
            print("[CameraSource] No matching capture device found")
            captureSession.commitConfiguration()
            return
        }
        
        print("[CameraSource] Using camera: \(device.localizedName) (\(device.uniqueID))")
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                print("[CameraSource] Cannot add camera input to session")
            }
        } catch {
            print("[CameraSource] Error creating device input: \(error)")
        }
        
        // Dynamically select the best preset supported by the device
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        } else if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        captureSession.commitConfiguration()
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: pixelBuffer, image: nil)
    }
}

// MARK: - Custom Static Image Source
public final class ImageSource: MediaSource {
    public weak var delegate: MediaSourceDelegate?
    public let imagePath: String
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "opensimcam.image.queue")
    private var cgImage: CGImage?
    private let fps: Double
    
    public init(imagePath: String, fps: Double = 30.0) {
        self.imagePath = imagePath
        self.fps = fps
        loadImage()
    }
    
    private func loadImage() {
        let url = URL(fileURLWithPath: imagePath)
        if let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.cgImage = cg
        }
    }
    
    public func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = 1.0 / self.fps
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self = self, let img = self.cgImage else { return }
                self.delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: img)
            }
            self.timer = timer
            timer.resume()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }
}

// MARK: - Video Source
public final class VideoSource: MediaSource {
    public weak var delegate: MediaSourceDelegate?
    public let videoPath: String
    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "opensimcam.video.queue")
    
    public init(videoPath: String) {
        self.videoPath = videoPath
    }
    
    public func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            self.restartReader()
            
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { [weak self] in
                self?.deliverNextFrame()
            }
            self.timer = timer
            timer.resume()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.assetReader?.cancelReading()
            self?.assetReader = nil
        }
    }
    
    private func restartReader() {
        let url = URL(fileURLWithPath: videoPath)
        let asset = AVAsset(url: url)
        
        let semaphore = DispatchSemaphore(value: 0)
        var targetTrack: AVAssetTrack?
        
        if #available(macOS 12.0, *) {
            asset.loadTracks(withMediaType: .video) { tracks, _ in
                targetTrack = tracks?.first
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.0)
        } else {
            targetTrack = asset.tracks(withMediaType: .video).first
        }
        
        guard let track = targetTrack else { return }
        
        do {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()
            self.assetReader = reader
            self.trackOutput = output
        } catch {
            print("[VideoSource] Reader setup error: \(error)")
        }
    }
    
    private func deliverNextFrame() {
        guard let output = trackOutput, let reader = assetReader else { return }
        if let sampleBuffer = output.copyNextSampleBuffer(),
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: pixelBuffer, image: nil)
        } else if reader.status == .completed {
            restartReader()
        }
    }
}

// MARK: - Dynamic QR Code Source
public final class QRCodeSource: MediaSource {
    public weak var delegate: MediaSourceDelegate?
    public let text: String
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "opensimcam.qr.queue")
    private var qrImage: CGImage?
    
    public init(text: String) {
        self.text = text
        generateQRImage()
    }
    
    private func generateQRImage() {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(text.data(using: .utf8), forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel")
        
        if let output = filter?.outputImage {
            let transform = CGAffineTransform(scaleX: 20, y: 20)
            let scaled = output.transformed(by: transform)
            let context = CIContext()
            self.qrImage = context.createCGImage(scaled, from: scaled.extent)
        }
    }
    
    public func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { [weak self] in
                guard let self = self, let img = self.qrImage else { return }
                self.delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: img)
                self.delegate?.mediaSourceDidOutputMetadata(self, metadataObjects: [
                    ["type": "org.iso.QRCode", "value": self.text]
                ])
            }
            self.timer = timer
            timer.resume()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }
}

// MARK: - SMPTE Test Pattern
public final class TestPatternSource: MediaSource {
    public weak var delegate: MediaSourceDelegate?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "opensimcam.testpattern.queue")
    private var tick = 0
    
    public init() {}
    
    public func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.tick += 1
                let img = self.renderPattern(tick: self.tick)
                self.delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: img)
            }
            self.timer = timer
            timer.resume()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }
    
    private func renderPattern(tick: Int) -> CGImage? {
        let width = 1080
        let height = 1920
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        
        let colors: [CGColor] = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 1, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 1, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        ]
        
        let barWidth = Double(width) / Double(colors.count)
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: Double(i) * barWidth, y: 0, width: barWidth, height: Double(height)))
        }
        
        let boxSize: Double = 140
        let posX = abs(Double((tick * 8) % (width * 2) - width))
        let posY = abs(Double((tick * 10) % (height * 2) - height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.9))
        ctx.fill(CGRect(x: posX, y: posY, width: boxSize, height: boxSize))
        
        return ctx.makeImage()
    }
}
