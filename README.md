# OpenSC (Open Source Simulator Cam)

OpenSC is a macOS camera utility for iOS Simulator development. It provides camera sources, framing controls, a live viewfinder, and a menu bar tray so developers can test camera features in a running simulator app without restarting the simulator or interrupting the Flutter development session.

## What it does

- Supplies a selected video, image, Mac webcam, screen passthrough, QR code, or test pattern to an iOS Simulator camera session.
- Provides independent front and back camera framing controls, including fit mode, zoom, pan, rotation, and mirroring.
- Shows the current source in the Studio window, a live preview, and a macOS menu bar popover.
- Detects booted iOS Simulators and configures the camera loader for apps launched after setup.
- Keeps the Simulator and already-running development app under the developer's control. OpenSC does not restart them to apply camera setup.

> If an app was already running before camera setup, relaunch that app in the Simulator to load the camera plugin. This does not require restarting the Simulator or stopping the Flutter tool; the app can be relaunched from the existing Flutter session.

## Requirements

- macOS 14 or later (the native Runner target is configured for macOS 14).
- Xcode with the macOS SDK and iOS Simulator runtimes installed.
- Flutter and Dart versions that satisfy the SDK constraint in `pubspec.yaml`.
- A booted iOS Simulator for simulator camera integration.

## Run locally

From the repository root:

```sh
flutter pub get
flutter run -d macos
```

OpenSC starts as a menu bar utility. Its tray popover opens on launch; select **Open Studio** to show the full workspace. Closing the Studio window hides it while leaving the tray and native camera service running. Use **Quit** in the tray to stop the app and clean up its native services.

To create a debug build:

```sh
flutter build macos --debug
```

The built application is named `OpenSC.app` under `build/macos/Build/Products/Debug/`.

## Camera sources

Choose a source from the Camera Configuration controls or from the menu bar popover.

| Source | Description |
| --- | --- |
| Demo Video Loop | Plays a video bundled under `assets/`. Use the asset dropdown to choose a bundled clip. Supported bundled extensions are `.mp4`, `.mov`, and `.m4v`. |
| FaceTime HD Camera | Streams a selected Mac camera. macOS asks for camera permission when required. |
| Screen Passthrough | Captures the desktop behind the Simulator window and follows its movement. macOS screen recording permission is required. |
| Custom Image File | Streams a selected local image. |
| Custom Video File | Streams a selected local video. |
| Dynamic QR Code | Generates frames for the configured text or URL. |
| SMPTE Test Bars | Generates a test pattern for camera-pipeline checks. |

Bundled videos are enumerated from Flutter's asset manifest, so adding a supported video below `assets/` makes it available in the Demo Video dropdown on the next app build. Bundled clips are opened directly from the application bundle when possible. A temporary-file extraction fallback handles bundle layouts that do not expose a direct file path.

The included demo clips are H.264 MP4s optimized for the Simulator camera feed. The current assets are 1920×1080 and 1080×1920; they retain their original durations and frame rates while using less storage and decoding work than the source files.

## Simulator setup and lifecycle

OpenSC polls for booted Simulators in the background and publishes device and running-app status to the Studio and tray. When the native camera loader is available, it applies the loader environment to booted Simulators so subsequently launched apps can connect through the local frame-handshake service.

Setup does not force-quit or restart a Simulator, relaunch a user's app, or terminate the Flutter development process. If setup is applied after the target app has already launched, relaunch only that app from the existing development workflow. A successful connection appears in the Studio and tray when the app's camera plugin connects.

## macOS permissions

- **Camera:** required for the FaceTime HD Camera source.
- **Screen & System Audio Recording / Screen Recording:** required for Screen Passthrough. OpenSC only captures the display used for the passthrough source and excludes the Simulator app where ScreenCaptureKit permits it.

Permission controls are available in the app when macOS has not granted access. You can also manage access in **System Settings → Privacy & Security**.

## Project structure

```text
lib/
  main.dart                         Flutter app entry point and app metadata
  screens/studio_screen.dart        Studio UI, source selection, and controls
  models/                           Camera source and framing models
  theme/                            Shared colors and glass material settings
  widgets/                          Glass panels, source controls, preview, and viewfinder
assets/                             Bundled demo videos and other app assets
macos/Runner/
  OpenSCBridge.swift                Flutter/native method and preview channels
  StudioTray.swift                  Menu bar item and tray popover
  SimulatorManager.swift            Simulator discovery and loader setup
  FrameHandshakeServer.swift        Local app connections and frame routing
  MediaSource.swift                 Webcam, passthrough, image, video, QR, and pattern sources
  ProcessChannel.swift              Per-app socket and camera frame delivery
  SharedMemoryBuffer.swift          Frame transforms and shared-memory output
```

### Frame and control flow

Flutter owns the Studio interface and sends control requests over the macOS method channel. Native Swift code enumerates sources, captures or generates frames, applies front/back transforms, and sends camera frames to connected Simulator apps through Unix-domain sockets and shared-memory buffers. Preview JPEGs are delivered over a Flutter event channel and also update the native tray preview.

The macOS bundle identifier (`com.opensimcam.opensimcamStudio`), method/event channel names, loader filenames, and `com.swmansion.SimCam` shared-memory/socket paths remain compatible with existing installations and the native camera-loader integration. They are internal interoperability identifiers and are intentionally retained while the product name changes.

## Performance notes

- Bundled video playback avoids a first-launch 16 MB asset copy when the native bundle exposes the asset path.
- Demo clips are scaled and encoded as H.264 with fast-start metadata for lower storage use and quicker playback startup.
- Core Image rendering contexts are reused for shared-memory output.
- Passthrough captures a display stream once and crops the latest Simulator window region rather than reconfiguring capture on every window movement.
- Frame delivery and camera transforms use synchronized state snapshots to avoid races between capture and control queues.

## Validation

Run the checks from the repository root:

```sh
dart format lib
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --debug
```

## Troubleshooting

### The tray says it is waiting for a Simulator

Boot an iOS Simulator and allow a few seconds for background discovery. Use the tray refresh action or the Studio refresh control to request an immediate refresh.

### The Simulator app does not connect to the camera

Confirm that setup completed and the desired source is active. If the target app was running before setup, relaunch that app in the same Simulator. Check that macOS permissions are granted for the selected source.

### Passthrough is blank or frozen

Grant screen recording permission, then switch away from Passthrough and back to restart capture. Ensure the Simulator window is visible on the captured display.

### A bundled video is missing from the selector

Place an `.mp4`, `.mov`, or `.m4v` file below `assets/`, ensure it is included by the `assets/` entry in `pubspec.yaml`, then rebuild the app. Flutter's asset manifest is generated during the build.

## License

No license file is currently included in this repository. Add a `LICENSE` file before distributing OpenSC if you intend to publish it as open-source software.
