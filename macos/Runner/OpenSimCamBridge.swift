import Foundation
import FlutterMacOS
import AVFoundation

public final class OpenSimCamBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var channel: FlutterMethodChannel?
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
        
        let instance = OpenSimCamBridge()
        instance.channel = channel
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
                onRefresh: { [weak instance] in
                    instance?.invokeFlutterFromTray("onTrayRefresh")
                },
                onSourceChanged: { [weak instance] source in
                    instance?.invokeFlutterFromTray(
                        "onTraySourceChanged",
                        arguments: ["source": source]
                    )
                }
            )
        }
        
        // Start background socket server
        FrameHandshakeServer.shared.start()
        
        // Hook up preview frames
        FrameHandshakeServer.shared.onPreviewFrame = { [weak instance] data in
            instance?.eventSink?(data)
            Task { @MainActor in
                StudioTrayController.shared.updatePreview(data)
            }
        }
        
        // Hook up client app connection notifications
        FrameHandshakeServer.shared.onClientConnected = { [weak instance] bundleID, simUDID in
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
                StudioTrayController.shared.updateConnection(
                    isConnected: isActive,
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
                let sims = SimulatorManager.getBootedSimulators().map { [
                    "name": $0.name,
                    "udid": $0.udid,
                    "isInjected": $0.isInjected,
                    "runningAppBundle": ($0.runningAppBundle as Any?) ?? NSNull()
                ] }
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
                            message: "OpenSimCam camera loader was not found.",
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
