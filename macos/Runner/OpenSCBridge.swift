import Foundation
import FlutterMacOS
import AVFoundation
import AppKit

public final class OpenSCBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var channel: FlutterMethodChannel?
    private var flutterAssetPathResolver: ((String) -> String?)?
    private var flutterIsReady = false
    private var pendingTrayCalls: [(String, Any?)] = []

    private func invokeFlutterFromTray(_ method: String, arguments: Any? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            guard self.flutterIsReady else {
                self.pendingTrayCalls.append((method, arguments))
                return
            }
            channel.invokeMethod(method, arguments: arguments)
        }
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.opensimcam.studio/control", binaryMessenger: registrar.messenger)
        let eventChannel = FlutterEventChannel(name: "com.opensimcam.studio/preview", binaryMessenger: registrar.messenger)
        
        let instance = OpenSCBridge()
        instance.channel = channel
        instance.flutterAssetPathResolver = { asset in
            let assetKey = registrar.lookupKey(forAsset: asset)
            guard !assetKey.isEmpty else { return nil }
            let frameworkAssets = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets")
            let assetURL = frameworkAssets.appendingPathComponent(asset)
            let resourcePath = Bundle.main.path(forResource: assetKey, ofType: nil)
                ?? URL(string: assetKey, relativeTo: Bundle.main.bundleURL)?.path
            let candidates: [String?] = [resourcePath, assetURL.path]
            for path in candidates {
                if let path, FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
            return nil
        }
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)

        Task { @MainActor in
            StudioTrayController.shared.install(
                onOpenStudio: {
                    Task { @MainActor in
                        StudioTrayController.shared.openStudioWindow()
                    }
                },
                onStartSetup: { [weak instance] in
                    instance?.invokeFlutterFromTray("onTrayStartSetup")
                },
                onOpenSimulator: { [weak instance] in
                    instance?.invokeFlutterFromTray("onTrayOpenSimulator")
                },
                onRefresh: { [weak instance] in
                    instance?.invokeFlutterFromTray("onTrayRefresh")
                },
                onSourceChanged: { [weak instance] source in
                    instance?.invokeFlutterFromTray(
                        "onTraySourceChanged",
                        arguments: ["source": source]
                    )
                },
                onToggleMirror: { [weak instance] in
                    instance?.invokeFlutterFromTray("onTrayToggleMirror")
                },
                onSwitchCamera: { [weak instance] camera in
                    instance?.invokeFlutterFromTray(
                        "onTraySwitchCamera",
                        arguments: ["camera": camera]
                    )
                }
            )
        }
        
        // Start background socket server
        FrameHandshakeServer.shared.start()
        FrameHandshakeServer.shared.scanExistingProcessSockets()
        
        // Hook up preview frames
        FrameHandshakeServer.shared.onPreviewFrame = { [weak instance] data in
            instance?.eventSink?(data)
            Task { @MainActor in
                StudioTrayController.shared.updatePreview(data)
            }
        }
        
        // Hook up client app connection notifications
        FrameHandshakeServer.shared.onClientConnected = { [weak instance] bundleID, simUDID in
            SimulatorManager.recordSuccessfulHandshake(simUDID: simUDID)
            DispatchQueue.main.async {
                Task { @MainActor in
                StudioTrayController.shared.updateConnection(isConnected: true)
                }
                instance?.channel?.invokeMethod("onClientConnected", arguments: [
                    "bundleId": bundleID,
                    "simUDID": simUDID
                ])
            }
        }
        
        // Hook up client app disconnection notifications
        FrameHandshakeServer.shared.onClientDisconnected = { [weak instance] bundleID in
            DispatchQueue.main.async {
                Task { @MainActor in
                StudioTrayController.shared.updateConnection(isConnected: false)
                }
                instance?.channel?.invokeMethod("onClientDisconnected", arguments: [
                    "bundleId": bundleID
                ])
            }
        }
        
        // Hook up camera active state and camera switch notifications
        FrameHandshakeServer.shared.onCameraStateChanged = { [weak instance] bundleID, isActive, camera in
            DispatchQueue.main.async {
                Task { @MainActor in
                StudioTrayController.shared.updateCameraState(
                    isActive: isActive,
                    camera: camera
                )
                }
                instance?.channel?.invokeMethod("onCameraStateChanged", arguments: [
                    "bundleId": bundleID,
                    "isActive": isActive,
                    "camera": camera
                ])
            }
        }
        
        // Start automatic simulator detection & dynamic injection
        SimulatorManager.startAutoDetection { [weak instance] sims in
            Task { @MainActor in
                StudioTrayController.shared.updateSimulators(sims)
            }
            let simData = sims.map { [
                "name": $0.name,
                "udid": $0.udid,
                "isInjected": $0.isInjected,
                "runningAppBundle": ($0.runningAppBundle as Any?) ?? NSNull()
            ] }
            instance?.channel?.invokeMethod("onSimulatorsUpdated", arguments: simData)
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let server = FrameHandshakeServer.shared
        
        switch call.method {
        case "flutterReady":
            flutterIsReady = true
            let pendingCalls = pendingTrayCalls
            pendingTrayCalls.removeAll()
            for (method, arguments) in pendingCalls {
                channel?.invokeMethod(method, arguments: arguments)
            }
            server.scanExistingProcessSockets()
            // A simulator app can complete its native handshake before the
            // Dart method handler is attached. Replay the current native
            // connection state so already-running apps appear immediately.
            for connection in server.connectionSnapshot() {
                SimulatorManager.recordSuccessfulHandshake(simUDID: connection.simUDID)
                Task { @MainActor in
                    StudioTrayController.shared.updateConnection(isConnected: true)
                    StudioTrayController.shared.updateCameraState(
                        isActive: connection.isCameraActive,
                        camera: connection.camera
                    )
                }
                channel?.invokeMethod("onClientConnected", arguments: [
                    "bundleId": connection.bundleID,
                    "simUDID": connection.simUDID
                ])
                channel?.invokeMethod("onCameraStateChanged", arguments: [
                    "bundleId": connection.bundleID,
                    "isActive": connection.isCameraActive,
                    "camera": connection.camera
                ])
            }
            result(true)

        case "updateTraySource":
            let args = call.arguments as? [String: Any]
            let source = args?["source"] as? String ?? "demoVideo"
            Task { @MainActor in
                StudioTrayController.shared.setSource(source)
            }
            result(true)

        case "setTraySetupState":
            let args = call.arguments as? [String: Any]
            let isRunning = args?["isRunning"] as? Bool ?? false
            Task { @MainActor in
                StudioTrayController.shared.setSetupRunning(isRunning)
            }
            result(true)

        case "setTraySetupError":
            let args = call.arguments as? [String: Any]
            let message = args?["message"] as? String
            Task { @MainActor in
                StudioTrayController.shared.setSetupError(message)
            }
            result(true)

        case "openSimulator":
            guard let simulatorURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.iphonesimulator"
            ) else {
                result(FlutterError(
                    code: "SIMULATOR_APP_NOT_FOUND",
                    message: "Simulator.app was not found. Install or select Xcode in Xcode Settings > Locations.",
                    details: nil
                ))
                return
            }
            NSWorkspace.shared.openApplication(
                at: simulatorURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        result(FlutterError(
                            code: "SIMULATOR_LAUNCH_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    } else {
                        result(true)
                    }
                }
            }

        case "startPassthrough":
            server.currentMediaSource = PassthroughSource(fps: 30.0)
            result(true)
            
        case "startCamera":
            let args = call.arguments as? [String: Any]
            let deviceId = args?["deviceId"] as? String
            server.currentMediaSource = CameraSource(preferredDeviceID: deviceId)
            result(true)
            
        case "startImage":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Path required", details: nil))
                return
            }
            server.currentMediaSource = ImageSource(imagePath: path)
            result(true)
            
        case "startVideo":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Path required", details: nil))
                return
            }
            server.currentMediaSource = VideoSource(videoPath: path)
            result(true)

        case "getBundledVideoPath":
            let args = call.arguments as? [String: Any]
            let asset = args?["asset"] as? String ?? ""
            guard asset.hasPrefix("assets/"),
                  !asset.split(separator: "/").contains(".."),
                  ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: asset).pathExtension.lowercased()) else {
                result(nil)
                return
            }
            result(flutterAssetPathResolver?(asset))
            
        case "startQR":
            guard let args = call.arguments as? [String: Any],
                  let text = args["text"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Text required", details: nil))
                return
            }
            server.currentMediaSource = QRCodeSource(text: text)
            result(true)
            
        case "startTestPattern":
            server.currentMediaSource = TestPatternSource()
            result(true)
            
        case "setFitMode":
            let args = call.arguments as? [String: Any]
            let target = args?["target"] as? String ?? "both"
            let mode = args?["mode"] as? String ?? "fill"
            server.setFitMode(target: target, mode: mode)
            result(true)
            
        case "setPreviewCamera":
            let args = call.arguments as? [String: Any]
            let camera = args?["camera"] as? String ?? "back"
            server.previewTargetCamera = camera
            Task { @MainActor in
                StudioTrayController.shared.setActiveCamera(camera)
            }
            result(true)
            
        case "updateTransformSettings":
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            let target = args["target"] as? String ?? "both"
            let fitMode = args["fitMode"] as? String ?? "fill"
            let zoom = CGFloat(args["zoom"] as? Double ?? 1.0)
            let offsetX = CGFloat(args["offsetX"] as? Double ?? 0.0)
            let offsetY = CGFloat(args["offsetY"] as? Double ?? 0.0)
            let rotation = args["rotation"] as? Int ?? 0
            let mirror = args["mirror"] as? Bool ?? false
            
            let config = TransformConfig(
                fitMode: fitMode,
                zoom: zoom,
                offsetX: offsetX,
                offsetY: offsetY,
                rotation: rotation,
                mirror: mirror
            )
            server.updateTransformConfig(target: target, config: config)
            Task { @MainActor in
                StudioTrayController.shared.setMirrored(mirror)
            }
            result(true)

        case "updateTrayCameraState":
            let args = call.arguments as? [String: Any]
            let camera = args?["camera"] as? String
            let mirror = args?["mirror"] as? Bool
            Task { @MainActor in
                if let camera { StudioTrayController.shared.setActiveCamera(camera) }
                if let mirror { StudioTrayController.shared.setMirrored(mirror) }
            }
            result(true)
            
        case "getCameras":
            DispatchQueue.global(qos: .userInitiated).async {
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
                let cameras = discovery.devices.map { [
                    "name": $0.localizedName,
                    "id": $0.uniqueID
                ] }
                DispatchQueue.main.async { result(cameras) }
            }
            
        case "getBootedSimulators":
            SimulatorManager.backgroundQueue.async {
                FrameHandshakeServer.shared.scanExistingProcessSockets()
                let connections = server.connectionSnapshot()
                let sims = SimulatorManager.getBootedSimulators(includeRunningApps: true).map { sim in
                    let activeConnection = connections.first { $0.simUDID == sim.udid }
                    return [
                        "name": sim.name,
                        "udid": sim.udid,
                        "isInjected": sim.isInjected || activeConnection != nil,
                        "runningAppBundle": activeConnection?.bundleID ?? (sim.runningAppBundle as Any?) ?? NSNull()
                    ]
                }
                DispatchQueue.main.async { result(sims) }
            }
            
        case "injectSimulator":
            let args = call.arguments as? [String: Any]
            let udid = args?["udid"] as? String
            SimulatorManager.backgroundQueue.async {
                guard let loader = SimulatorManager.getLoaderPath() else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "LOADER_NOT_FOUND",
                            message: "OpenSC camera loader was not found.",
                            details: nil
                        ))
                    }
                    return
                }
                let injected = SimulatorManager.injectDylib(loaderPath: loader, intoUDID: udid)
                DispatchQueue.main.async {
                    if injected {
                        result(true)
                    } else {
                        result(FlutterError(
                            code: "SIMULATOR_SETUP_FAILED",
                            message: "Could not apply the camera loader to the booted simulator.",
                            details: nil
                        ))
                    }
                }
            }
            
        case "checkScreenCapturePermission":
            if #available(macOS 10.15, *) {
                result(CGPreflightScreenCaptureAccess())
            } else {
                result(true)
            }
            
        case "requestScreenCapturePermission":
            if #available(macOS 10.15, *) {
                result(CGRequestScreenCaptureAccess())
            } else {
                result(true)
            }
            
        case "openSystemPreferencesScreenCapture":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            result(true)
            
        case "checkCameraPermission":
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            result(status == .authorized)
            
        case "requestCameraPermission":
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    result(granted)
                }
            }

        case "closeWindow":
            DispatchQueue.main.async {
                let window = MainFlutterWindow.shared
                    ?? (NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first)
                    ?? NSApp.keyWindow
                    ?? NSApp.mainWindow
                window?.orderOut(nil)
            }
            result(true)

        case "minimizeWindow":
            DispatchQueue.main.async {
                let window = MainFlutterWindow.shared
                    ?? (NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first)
                    ?? NSApp.keyWindow
                    ?? NSApp.mainWindow

                guard let window else { return }

                if !window.styleMask.contains(.miniaturizable) {
                    window.styleMask.insert(.miniaturizable)
                }

                if let minBtn = window.standardWindowButton(.miniaturizeButton) {
                    minBtn.isEnabled = true
                    minBtn.isHidden = false
                    minBtn.alphaValue = 0.0
                }

                window.miniaturize(window)
                if !window.isMiniaturized {
                    window.performMiniaturize(window)
                }
                if !window.isMiniaturized {
                    window.orderOut(nil)
                }
            }
            result(true)

        case "dragWindow":
            DispatchQueue.main.async {
                let window = MainFlutterWindow.shared
                    ?? (NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first)
                    ?? NSApp.keyWindow
                    ?? NSApp.mainWindow
                if let window, let event = NSApp.currentEvent {
                    window.performDrag(with: event)
                }
            }
            result(true)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
