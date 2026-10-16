import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import AppKit
import ScreenCaptureKit
import CoreMedia

public protocol MediaSourceDelegate: AnyObject {
    func mediaSourceDidOutputFrame(
        _ source: MediaSource,
        pixelBuffer: CVPixelBuffer?,
        image: CGImage?,
        ciImage: CIImage?
    )
    func mediaSourceDidOutputMetadata(_ source: MediaSource, metadataObjects: [[String: Any]])
}

public protocol MediaSource: AnyObject {
    var delegate: MediaSourceDelegate? { get set }
    func start()
    func stop()
}

// MARK: - Passthrough Mode (Mac Screen Behind Simulator Window)
public final class PassthroughSource: NSObject, MediaSource, SCStreamOutput, SCStreamDelegate {
    public weak var delegate: MediaSourceDelegate?
    private let captureQueue = DispatchQueue(label: "opensimcam.passthrough.capture")
    private let stateLock = NSLock()
    private let geometryQueue = DispatchQueue(label: "opensimcam.passthrough.geometry", qos: .utility)
    private let fps: Double
    private var generation: UInt64 = 0
    private var stream: SCStream?
    private var geometryTimer: DispatchSourceTimer?
    private var displayFrame: CGRect?
    private var captureDisplay: SCDisplay?
    private var simulatorWindowFrame: CGRect?
    private var simulatorProcessID: pid_t?
    private var fallbackFrame: CGRect?
    private var simulatorFilterInstalled = false
    private var filterRefreshPending = false
    
    public init(fps: Double = 30.0) {
        self.fps = fps
        super.init()
    }
    
    public func start() {
        if #available(macOS 10.15, *) {
            guard CGPreflightScreenCaptureAccess() else {
                print("[PassthroughSource] Screen capture permission not granted. Not starting timer.")
                return
            }
        }
        
        stateLock.lock()
        generation &+= 1
        let activeGeneration = generation
        let previousStream = stream
        let previousTimer = geometryTimer
        stream = nil
        geometryTimer = nil
        displayFrame = nil
        captureDisplay = nil
        simulatorWindowFrame = nil
        simulatorProcessID = nil
        fallbackFrame = nil
        simulatorFilterInstalled = false
        filterRefreshPending = false
        stateLock.unlock()

        previousTimer?.cancel()
        Task { [weak self] in
            if let previousStream {
                try? await previousStream.stopCapture()
            }
            await self?.startCapture(generation: activeGeneration)
        }
    }
    
    public func stop() {
        stateLock.lock()
        generation &+= 1
        let activeStream = stream
        let activeTimer = geometryTimer
        stream = nil
        geometryTimer = nil
        displayFrame = nil
        captureDisplay = nil
        simulatorWindowFrame = nil
        simulatorProcessID = nil
        fallbackFrame = nil
        simulatorFilterInstalled = false
        filterRefreshPending = false
        stateLock.unlock()

        activeTimer?.cancel()
        guard let activeStream else { return }
        Task {
            try? await activeStream.stopCapture()
        }
    }

    private func startCapture(generation requestedGeneration: UInt64) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard isCurrent(generation: requestedGeneration), !content.displays.isEmpty else { return }

            let simulatorWindow = content.windows
                .filter {
                    ($0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator" ||
                     $0.owningApplication?.applicationName == "Simulator") &&
                    $0.frame.width > 200 && $0.frame.height > 400
                }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

            let display = simulatorWindow.flatMap { window in
                content.displays.max { lhs, rhs in
                    area(of: window.frame.intersection(lhs.frame)) < area(of: window.frame.intersection(rhs.frame))
                }
            } ?? content.displays.first
            guard let display else { return }

            let fallbackFrame = centeredPortraitFrame(in: display.frame)
            let simulatorApp = content.applications.first {
                $0.bundleIdentifier == "com.apple.iphonesimulator"
            }
            let filter: SCContentFilter
            if let simulatorApp {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: [simulatorApp],
                    exceptingWindows: []
                )
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let config = makeConfiguration(for: display.frame)

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)

            let initialWindowFrame = simulatorWindow?.frame.intersection(display.frame)
            let processID = simulatorWindow?.owningApplication?.processID ?? simulatorApp?.processID
            guard store(
                newStream,
                displayFrame: display.frame,
                captureDisplay: display,
                simulatorWindowFrame: initialWindowFrame,
                simulatorProcessID: processID,
                fallbackFrame: fallbackFrame,
                simulatorFilterInstalled: simulatorApp != nil,
                for: requestedGeneration
            ) else {
                return
            }

            try await newStream.startCapture()
            guard isCurrent(generation: requestedGeneration) else {
                try? await newStream.stopCapture()
                return
            }
            installGeometryMonitor(for: requestedGeneration)
        } catch {
            clearStream(for: requestedGeneration)
            print("[PassthroughSource] Unable to start screen capture: \(error.localizedDescription)")
        }
    }

    private func store(
        _ stream: SCStream,
        displayFrame: CGRect,
        captureDisplay: SCDisplay,
        simulatorWindowFrame: CGRect?,
        simulatorProcessID: pid_t?,
        fallbackFrame: CGRect,
        simulatorFilterInstalled: Bool,
        for requestedGeneration: UInt64
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == requestedGeneration else { return false }
        self.stream = stream
        self.displayFrame = displayFrame
        self.captureDisplay = captureDisplay
        self.simulatorWindowFrame = simulatorWindowFrame
        self.simulatorProcessID = simulatorProcessID
        self.fallbackFrame = fallbackFrame
        self.simulatorFilterInstalled = simulatorFilterInstalled
        return true
    }

    private func clearStream(for requestedGeneration: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == requestedGeneration else { return }
        stream = nil
    }

    private func installGeometryMonitor(for requestedGeneration: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: geometryQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(50),
            repeating: .milliseconds(50),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in
            self?.refreshWindowGeometry(generation: requestedGeneration)
        }
        timer.resume()

        stateLock.lock()
        guard generation == requestedGeneration else {
            stateLock.unlock()
            timer.cancel()
            return
        }
        let previousTimer = geometryTimer
        geometryTimer = timer
        stateLock.unlock()
        previousTimer?.cancel()
    }

    private func refreshWindowGeometry(generation requestedGeneration: UInt64) {
        stateLock.lock()
        guard generation == requestedGeneration, stream != nil,
              let displayFrame else {
            stateLock.unlock()
            return
        }
        let processID = simulatorProcessID
        let shouldInstallFilter = !simulatorFilterInstalled && !filterRefreshPending
        stateLock.unlock()

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let candidates = windows.compactMap { window -> (CGRect, pid_t)? in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "Simulator",
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 200, rect.height > 400,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                return nil
            }
            if let processID, processID != pid { return nil }
            return (rect, pid)
        }
        guard let next = candidates.max(by: {
            $0.0.width * $0.0.height < $1.0.width * $1.0.height
        }) else { return }

        let nextFrame = next.0.intersection(displayFrame)
        guard !nextFrame.isNull, nextFrame.width > 50, nextFrame.height > 50 else { return }
        stateLock.lock()
        var needsFilterUpdate = false
        if generation == requestedGeneration {
            simulatorProcessID = next.1
            simulatorWindowFrame = nextFrame
            if shouldInstallFilter && !filterRefreshPending {
                filterRefreshPending = true
                needsFilterUpdate = true
            }
        }
        stateLock.unlock()
        if needsFilterUpdate {
            Task { [weak self] in
                await self?.installSimulatorExclusion(generation: requestedGeneration)
            }
        }
    }

    private func installSimulatorExclusion(generation requestedGeneration: UInt64) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard isCurrent(generation: requestedGeneration) else { return }
            guard let app = content.applications.first(where: {
                $0.bundleIdentifier == "com.apple.iphonesimulator"
            }) else {
                finishSimulatorFilterRefresh(generation: requestedGeneration)
                return
            }
            guard let (activeStream, display) = filterUpdateSnapshot(
                generation: requestedGeneration
            ) else { return }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [app],
                exceptingWindows: []
            )
            try await activeStream.updateContentFilter(filter)
            finishSimulatorFilterRefresh(
                generation: requestedGeneration,
                processID: app.processID,
                installed: true
            )
        } catch {
            finishSimulatorFilterRefresh(generation: requestedGeneration)
            print("[PassthroughSource] Unable to exclude Simulator from passthrough: \(error.localizedDescription)")
        }
    }

    private func filterUpdateSnapshot(
        generation requestedGeneration: UInt64
    ) -> (SCStream, SCDisplay)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == requestedGeneration,
              let stream,
              let captureDisplay else { return nil }
        return (stream, captureDisplay)
    }

    private func finishSimulatorFilterRefresh(
        generation requestedGeneration: UInt64,
        processID: pid_t? = nil,
        installed: Bool = false
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == requestedGeneration else { return }
        filterRefreshPending = false
        if installed {
            simulatorFilterInstalled = true
            simulatorProcessID = processID
        }
    }

    private func makeConfiguration(for rect: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        // Capture the whole selected display once. A software crop follows the
        // Simulator window on every frame without reconfiguring ScreenCaptureKit.
        let maxDimension: CGFloat = 1440
        let scale = min(maxDimension / max(rect.width, rect.height), 2.0)
        config.width = max(2, Int((rect.width * scale).rounded()))
        config.height = max(2, Int((rect.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(
            seconds: 1.0 / max(1.0, min(fps, 30.0)),
            preferredTimescale: 600
        )
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        return config
    }

    private func isCurrent(generation requestedGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == requestedGeneration
    }

    private func centeredPortraitFrame(in frame: CGRect) -> CGRect {
        let height = min(frame.height, frame.width * 16 / 9)
        let width = height * 9 / 16
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    private func area(of rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let snapshot = geometryForCurrentFrame()
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let cropRect = sourceCropRect(
            windowFrame: snapshot.windowFrame ?? snapshot.fallbackFrame,
            displayFrame: snapshot.displayFrame,
            imageExtent: image.extent
        )
        let cropped = image.cropped(to: cropRect).transformed(
            by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        )
        delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: nil, ciImage: cropped)
    }

    private func geometryForCurrentFrame() -> (displayFrame: CGRect, windowFrame: CGRect?, fallbackFrame: CGRect) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let display = displayFrame ?? .zero
        return (display, simulatorWindowFrame, fallbackFrame ?? centeredPortraitFrame(in: display))
    }

    private func sourceCropRect(windowFrame: CGRect, displayFrame: CGRect, imageExtent: CGRect) -> CGRect {
        let clipped = windowFrame.intersection(displayFrame)
        guard !clipped.isNull, displayFrame.width > 0, displayFrame.height > 0 else { return imageExtent }
        let scaleX = imageExtent.width / displayFrame.width
        let scaleY = imageExtent.height / displayFrame.height
        return CGRect(
            x: imageExtent.minX + (clipped.minX - displayFrame.minX) * scaleX,
            y: imageExtent.minY + (displayFrame.maxY - clipped.maxY) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        ).intersection(imageExtent)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[PassthroughSource] Screen capture stopped: \(error.localizedDescription)")
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
        delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: pixelBuffer, image: nil, ciImage: nil)
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
                self.delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: img, ciImage: nil)
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
    private var isLoadingReader = false
    
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
            self?.trackOutput = nil
            self?.isLoadingReader = false
        }
    }
    
    private func restartReader() {
        guard !isLoadingReader else { return }
        isLoadingReader = true
        let url = URL(fileURLWithPath: videoPath)
        let asset = AVAsset(url: url)

        if #available(macOS 12.0, *) {
            asset.loadTracks(withMediaType: .video) { [weak self] tracks, error in
                guard let self else { return }
                self.queue.async {
                    guard self.timer != nil else {
                        self.isLoadingReader = false
                        return
                    }
                    guard let track = tracks?.first else {
                        self.isLoadingReader = false
                        print("[VideoSource] Could not load video track: \(error?.localizedDescription ?? "No video track")")
                        return
                    }
                    self.configureReader(asset: asset, track: track)
                }
            }
        } else {
            guard let track = asset.tracks(withMediaType: .video).first else {
                isLoadingReader = false
                print("[VideoSource] No video track at \(videoPath)")
                return
            }
            configureReader(asset: asset, track: track)
        }

    }

    private func configureReader(asset: AVAsset, track: AVAssetTrack) {
        defer { isLoadingReader = false }
        do {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                print("[VideoSource] Could not start video reader: \(reader.error?.localizedDescription ?? "unknown error")")
                return
            }
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
            delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: pixelBuffer, image: nil, ciImage: nil)
        } else if reader.status == .completed {
            assetReader = nil
            trackOutput = nil
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
                self.delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: img, ciImage: nil)
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
                self.delegate?.mediaSourceDidOutputFrame(self, pixelBuffer: nil, image: img, ciImage: nil)
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
