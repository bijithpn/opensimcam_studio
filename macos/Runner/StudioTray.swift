import AppKit
import SwiftUI

@MainActor
final class StudioTrayModel: ObservableObject {
    @Published var previewImage: NSImage?
    @Published var simulatorName = "Looking for simulator…"
    @Published var appName = "Waiting for an app"
    @Published var connectionStatus = "Searching"
    @Published var isConnected = false
    @Published var isSettingUp = false
    @Published var selectedSource = "demoVideo"

    var onOpenStudio: (() -> Void)?
    var onStartSetup: (() -> Void)?
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
        onRefresh: @escaping () -> Void,
        onSourceChanged: @escaping (String) -> Void
    ) {
        guard statusItem == nil else { return }
        model.onOpenStudio = onOpenStudio
        model.onStartSetup = onStartSetup
        model.onRefresh = onRefresh
        model.onSourceChanged = onSourceChanged

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.aperture",
            accessibilityDescription: "OpenSimCam Studio"
        )
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "OpenSimCam Studio"
        item.button?.setAccessibilityLabel("OpenSimCam Studio menu")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        // Let AppKit manage outside-click dismissal so the status item remains
        // responsive without custom global/local event monitors.
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 330, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: StudioTrayContent(model: model)
        )

        // Show the tray when the app launches so its live status and controls
        // are immediately discoverable. Defer until AppKit has attached the
        // status item to the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
            self?.showPopover()
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

    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

    func setSetupRunning(_ value: Bool) {
        model.isSettingUp = value
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
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = model.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.78))
                    } else {
                        VStack(spacing: 9) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 26, weight: .light))
                            Text("Waiting for live preview")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.32))
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isConnected ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(model.isConnected ? "LIVE VIEW" : "CURRENT VIEW")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.black.opacity(0.62), in: Capsule())
                .foregroundStyle(.white)
                .padding(10)
            }
            .frame(height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(.secondary)
                Text("OpenSimCam Studio")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    model.onRefresh?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh simulator status")
            }
            .padding(.top, 14)

            Text(model.simulatorName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            Text("\(model.appName) · \(model.connectionStatus)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 3)

            Divider().padding(.vertical, 12)

            Text("CAMERA SOURCE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Picker("Camera source", selection: $model.selectedSource) {
                ForEach(sources, id: \.0) { source in
                    Text(source.1).tag(source.0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: model.selectedSource) { _, source in
                model.onSourceChanged?(source)
            }
            .padding(.top, 4)

            Button {
                model.isSettingUp = true
                model.onStartSetup?()
            } label: {
                HStack(spacing: 7) {
                    if model.isSettingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(model.isSettingUp ? "Applying camera setup…" : "Apply Camera Setup")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 31)
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor.opacity(0.86))
            .disabled(model.isSettingUp || model.simulatorName == "No booted simulator")
            .padding(.top, 10)

            Divider().padding(.vertical, 12)

            Text("UPDATES & CHANGES")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            changeRow("Automatic simulator detection and camera setup")
            changeRow("Live viewfinder and camera framing controls")

            HStack {
                Button("Open Studio") {
                    model.onOpenStudio?()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        }
        .padding(14)
        .frame(width: 330)
        .background(.ultraThinMaterial)
    }

    private func changeRow(_ title: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green.opacity(0.85))
                .padding(.top, 2)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 7)
    }
}
