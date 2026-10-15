import Foundation
import FlutterMacOS
import AVFoundation

public final class OpenSimCamBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var channel: FlutterMethodChannel?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.opensimcam.studio/control", binaryMessenger: registrar.messenger)
        let eventChannel = FlutterEventChannel(name: "com.opensimcam.studio/preview", binaryMessenger: registrar.messenger)
        
        let instance = OpenSimCamBridge()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)
        
        // Start background socket server
        FrameHandshakeServer.shared.start()
        
        // Hook up preview frames
        FrameHandshakeServer.shared.onPreviewFrame = { [weak instance] data in
            instance?.eventSink?(data)
        }
        
        // Hook up client app connection notifications
        FrameHandshakeServer.shared.onClientConnected = { [weak instance] bundleID, simUDID in
            DispatchQueue.main.async {
                instance?.channel?.invokeMethod("onClientConnected", arguments: [
                    "bundleId": bundleID,
                    "simUDID": simUDID
                ])
            }
        }
        
        // Start automatic simulator detection & dynamic injection
        SimulatorManager.startAutoDetection { [weak instance] sims in
            let simData = sims.map { [
                "name": $0.name,
                "udid": $0.udid,
                "isInjected": $0.isInjected,
                "runningAppBundle": $0.runningAppBundle as Any
            ] }
            instance?.channel?.invokeMethod("onSimulatorsUpdated", arguments: simData)
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let server = FrameHandshakeServer.shared
        
        switch call.method {
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
            let mode = args?["mode"] as? String ?? "fill"
            server.setFitMode(mode)
            result(true)
            
        case "updateTransformSettings":
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
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
            server.updateTransformConfig(config)
            result(true)
            
        case "getCameras":
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
            result(cameras)
            
        case "getBootedSimulators":
            let sims = SimulatorManager.getBootedSimulators().map { [
                "name": $0.name,
                "udid": $0.udid,
                "isInjected": $0.isInjected,
                "runningAppBundle": $0.runningAppBundle as Any
            ] }
            result(sims)
            
        case "relaunchApp":
            guard let args = call.arguments as? [String: Any],
                  let bundleId = args["bundleId"] as? String,
                  let udid = args["udid"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "bundleId and udid required", details: nil))
                return
            }
            SimulatorManager.relaunchApp(bundleId: bundleId, simUDID: udid)
            result(true)
            
        case "injectSimulator":
            let args = call.arguments as? [String: Any]
            let udid = args?["udid"] as? String
            if let loader = SimulatorManager.getLoaderPath() {
                SimulatorManager.injectDylib(loaderPath: loader, intoUDID: udid)
                result(true)
            } else {
                result(FlutterError(code: "LOADER_NOT_FOUND", message: "OpenSimCam dylib not found", details: nil))
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
