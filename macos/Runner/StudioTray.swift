import AppKit
import SwiftUI

@MainActor
final class StudioTrayModel: ObservableObject {
    @Published var previewImage: NSImage?
    @Published var simulatorName = "Looking for simulator…"
    @Published var appName = "Waiting for an app"
    @Published var connectionStatus = "Searching"
    @Published var hasBootedSimulator = false
    @Published var isConnected = false
    @Published var isSettingUp = false
    @Published var setupError: String?
    @Published var selectedSource = "demoVideo"

    var onOpenStudio: (() -> Void)?
    var onStartSetup: (() -> Void)?
    var onOpenSimulator: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSourceChanged: ((String) -> Void)?
}

@MainActor
final class StudioTrayController: NSObject, NSPopoverDelegate {
    static let shared = StudioTrayController()

    let model = StudioTrayModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var lastPreviewUpdate = CFAbsoluteTimeGetCurrent()

    func install(
        onOpenStudio: @escaping () -> Void,
        onStartSetup: @escaping () -> Void,
        onOpenSimulator: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onSourceChanged: @escaping (String) -> Void
    ) {
        guard statusItem == nil else { return }
        model.onOpenStudio = onOpenStudio
        model.onStartSetup = onStartSetup
        model.onOpenSimulator = onOpenSimulator
        model.onRefresh = onRefresh
        model.onSourceChanged = onSourceChanged

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.aperture",
            accessibilityDescription: "OpenSC (Open Source Simulator Cam)"
        )
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "OpenSC (Open Source Simulator Cam)"
        item.button?.setAccessibilityLabel("OpenSC menu")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        // Let AppKit manage outside-click dismissal so the status item remains
        // responsive without custom global/local event monitors.
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 315, height: 385)
        popover.contentViewController = NSHostingController(
            rootView: StudioTrayContent(model: model)
        )

        // Show the tray when the app launches so its live status and controls
        // are immediately discoverable. Defer until AppKit has attached the
        // status item to the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
            self?.showPopover(retriesRemaining: 8)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }

    private func showPopover(retriesRemaining: Int = 0) {
        guard !popover.isShown else { return }
        guard let button = statusItem?.button,
              button.window != nil,
              button.bounds.width > 0,
              button.bounds.height > 0 else {
            guard retriesRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
                self?.showPopover(retriesRemaining: retriesRemaining - 1)
            }
            return
        }
        // Anchor a little inside the status item rather than at its full lower
        // edge. AppKit's default popover offset otherwise leaves a visible gap
        // between the tray and the menu bar on recent macOS releases.
        let anchor = NSRect(
            x: button.bounds.midX - 1,
            y: button.bounds.minY + min(6, button.bounds.height / 3),
            width: 2,
            height: 1
        )
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func openStudioWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .compactMap { $0 as? MainFlutterWindow }
            .first?
            .makeKeyAndOrderFront(nil)
    }

    func updatePreview(_ data: Data) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewUpdate >= 0.09 else { return }
        lastPreviewUpdate = now
        guard let image = NSImage(data: data) else { return }
        model.previewImage = image
    }

    func updateSimulators(_ simulators: [BootedSimulator]) {
        let simulator = simulators.first
        model.hasBootedSimulator = simulator != nil
        model.simulatorName = simulator?.name ?? "No booted simulator"
        model.appName = simulator?.runningAppBundle.map {
            $0.components(separatedBy: ".").last ?? $0
        } ?? "Waiting for an app"
        if simulator == nil {
            model.connectionStatus = "No simulator"
            model.isConnected = false
        } else if model.isConnected {
            model.connectionStatus = "Camera connected"
        } else if simulator?.isInjected == true {
            model.connectionStatus = "Camera ready"
        } else {
            model.connectionStatus = "Preparing camera"
        }
    }

    func updateConnection(isConnected: Bool, camera: String? = nil) {
        model.isConnected = isConnected
        if isConnected {
            model.connectionStatus = camera.map { "Camera active · \($0)" } ?? "Connected"
        } else {
            model.connectionStatus = "Waiting for app connection"
        }
    }

    func updateCameraState(isActive: Bool, camera: String) {
        guard model.isConnected else { return }
        model.connectionStatus = isActive ? "Camera active · \(camera)" : "App connected · camera idle"
    }

    func setSetupRunning(_ value: Bool) {
        model.isSettingUp = value
        if value { model.setupError = nil }
    }

    func setSetupError(_ message: String?) {
        model.setupError = message
    }

    func setSource(_ value: String) {
        model.selectedSource = value
    }
}

private struct StudioTrayContent: View {
    @ObservedObject var model: StudioTrayModel

    private let sources: [(String, String)] = [
        ("webcam", "FaceTime HD Camera"),
        ("passthrough", "Screen Passthrough"),
        ("demoVideo", "Demo Video Loop"),
        ("image", "Custom Image"),
        ("video", "Custom Video"),
        ("qrCode", "Dynamic QR Code"),
        ("testPattern", "SMPTE Test Bars"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: App icon, Title, Connection Dot & Badge, Refresh and Open buttons
            HStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.52, blue: 1.0))

                Text("OpenSC")
                    .font(.system(size: 13, weight: .bold))

                HStack(spacing: 4) {
                    Circle()
                        .fill(model.isConnected ? Color.green : (model.hasBootedSimulator ? Color.blue : Color.gray))
                        .frame(width: 6, height: 6)
                    Text(model.isConnected ? "Live" : (model.hasBootedSimulator ? "Ready" : "Offline"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.08), in: Capsule())

                Spacer(minLength: 0)

                Button {
                    model.onRefresh?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh simulator status")

                Button {
                    model.onOpenStudio?()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Studio window")
            }
            .padding(.top, 2)

            // Compact Camera Preview
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = model.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.85))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 20, weight: .light))
                            Text("No preview stream")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.4))
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isConnected ? Color.green : Color.gray)
                        .frame(width: 5, height: 5)
                    Text(model.isConnected ? "STREAMING" : "STANDBY")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.5)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.68), in: Capsule())
                .foregroundStyle(.white)
                .padding(8)
            }
            .frame(height: 125)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )

            // Simulator & App Status Line
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "iphone")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(model.simulatorName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text("\(model.appName) · \(model.connectionStatus)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)

            Divider()

            // Quick Camera Source Picker
            HStack {
                Text("Source")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.selectedSource) {
                    ForEach(sources, id: \.0) { source in
                        Text(source.1).tag(source.0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .onChange(of: model.selectedSource) { _, source in
                    model.onSourceChanged?(source)
                }
            }

            // Primary Setup / Launch Action Button
            Button {
                if model.hasBootedSimulator {
                    model.onStartSetup?()
                } else {
                    model.onOpenSimulator?()
                }
            } label: {
                HStack(spacing: 6) {
                    if model.isSettingUp {
                        Image(systemName: "hourglass")
                    } else {
                        Image(systemName: model.hasBootedSimulator ? "bolt.fill" : "play.fill")
                    }
                    Text(model.isSettingUp
                         ? "Applying setup…"
                         : model.hasBootedSimulator ? "Apply Camera Setup" : "Open Simulator")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.12, green: 0.46, blue: 0.88))
            .disabled(model.isSettingUp)

            if let setupError = model.setupError {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(setupError)
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color(red: 0.96, green: 0.48, blue: 0.48))
            }

            Divider()

            // Footer Toolbar: Open Studio & Quit
            HStack {
                Button("Open Studio") {
                    model.onOpenStudio?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 315)
        .background(.ultraThinMaterial)
    }
}
