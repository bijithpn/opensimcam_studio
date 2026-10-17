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
    @Published var activeCamera = "back"
    @Published var isMirrored = false

    var onOpenStudio: (() -> Void)?
    var onStartSetup: (() -> Void)?
    var onOpenSimulator: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSourceChanged: ((String) -> Void)?
    var onToggleMirror: (() -> Void)?
    var onSwitchCamera: ((String) -> Void)?
}

@MainActor
final class StudioTrayController: NSObject, NSPopoverDelegate {
    static let shared = StudioTrayController()

    let model = StudioTrayModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var lastPreviewUpdate = CFAbsoluteTimeGetCurrent()

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    func install(
        onOpenStudio: @escaping () -> Void,
        onStartSetup: @escaping () -> Void,
        onOpenSimulator: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onSourceChanged: @escaping (String) -> Void,
        onToggleMirror: (() -> Void)? = nil,
        onSwitchCamera: ((String) -> Void)? = nil
    ) {
        guard statusItem == nil else { return }
        model.onOpenStudio = onOpenStudio
        model.onStartSetup = onStartSetup
        model.onOpenSimulator = onOpenSimulator
        model.onRefresh = onRefresh
        model.onSourceChanged = onSourceChanged
        model.onToggleMirror = onToggleMirror
        model.onSwitchCamera = onSwitchCamera

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let trayImage = NSImage(named: "TrayIcon") ?? NSImage(
            systemSymbolName: "camera.aperture",
            accessibilityDescription: "OpenSC (Open Source Simulator Cam)"
        )
        trayImage?.isTemplate = true
        item.button?.image = trayImage
        item.button?.toolTip = "OpenSC (Open Source Simulator Cam)"
        item.button?.setAccessibilityLabel("OpenSC menu")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        // Use applicationDefined behavior so that the popover stays open in
        // fullscreen spaces when the menu bar autohides, rather than AppKit
        // immediately dismissing transient popovers on active space changes.
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 435)
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

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        configurePopoverWindow()
    }

    func popoverDidShow(_ notification: Notification) {
        configurePopoverWindow()
    }

    func popoverDidClose(_ notification: Notification) {
        stopEventMonitors()
        statusItem?.button?.highlight(false)
    }

    private func configurePopoverWindow() {
        guard let window = popover.contentViewController?.view.window else { return }
        // Ensure popover appears on all spaces (including macOS Full Screen spaces)
        // and above fullscreen applications.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .popUpMenu
        window.orderFrontRegardless()
    }

    private func startEventMonitors() {
        stopEventMonitors()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            let mouseLocation = NSEvent.mouseLocation

            if let button = self.statusItem?.button,
               let buttonWindow = button.window {
                let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
                if buttonScreenRect.contains(mouseLocation) {
                    return
                }
            }

            if let popoverWindow = self.popover.contentViewController?.view.window {
                if !popoverWindow.frame.contains(mouseLocation) {
                    self.closePopover()
                }
            } else {
                self.closePopover()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }

            if event.type == .keyDown && event.keyCode == 53 {
                self.closePopover()
                return nil
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let mouseLocation = NSEvent.mouseLocation

                if let button = self.statusItem?.button,
                   let buttonWindow = button.window {
                    let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
                    if buttonScreenRect.contains(mouseLocation) {
                        return event
                    }
                }

                if let popoverWindow = self.popover.contentViewController?.view.window {
                    if !popoverWindow.frame.contains(mouseLocation) {
                        self.closePopover()
                    }
                }
            }
            return event
        }
    }

    private func stopEventMonitors() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    func closePopover() {
        guard popover.isShown else { return }
        stopEventMonitors()
        popover.performClose(nil)
        statusItem?.button?.highlight(false)
    }

    func showPopover(retriesRemaining: Int = 0) {
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
        // Anchor slightly inside the status item rather than at its full lower
        // edge to avoid any gap between the tray and the menu bar.
        let anchor = NSRect(
            x: button.bounds.midX - 1,
            y: button.bounds.minY + min(6, button.bounds.height / 3),
            width: 2,
            height: 1
        )
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        button.highlight(true)
        configurePopoverWindow()
        startEventMonitors()
    }

    func openStudioWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = MainFlutterWindow.shared
            ?? NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }

    func updatePreview(_ data: Data) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewUpdate >= 0.08 else { return }
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

    func setActiveCamera(_ camera: String) {
        model.activeCamera = camera
    }

    func setMirrored(_ mirrored: Bool) {
        model.isMirrored = mirrored
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

private struct SourceOption: Identifiable {
    let id: String
    let title: String
    let icon: String
}

private struct StudioTrayContent: View {
    @ObservedObject var model: StudioTrayModel
    @State private var isRefreshing = false

    private let sources: [SourceOption] = [
        SourceOption(id: "webcam", title: "FaceTime / Webcam", icon: "camera.fill"),
        SourceOption(id: "passthrough", title: "Screen Passthrough", icon: "display"),
        SourceOption(id: "demoVideo", title: "Demo Video Loop", icon: "play.rectangle.fill"),
        SourceOption(id: "image", title: "Custom Image", icon: "photo.fill"),
        SourceOption(id: "video", title: "Custom Video", icon: "film.fill"),
        SourceOption(id: "qrCode", title: "Dynamic QR Code", icon: "qrcode"),
        SourceOption(id: "testPattern", title: "SMPTE Color Bars", icon: "checkerboard.rectangle"),
    ]

    private var activeSourceOption: SourceOption {
        sources.first(where: { $0.id == model.selectedSource }) ?? sources[2]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Bar: App Identity, Status Capsule, Refresh, Quick Utilities Menu
            HStack(spacing: 8) {
                if let trayImage = NSImage(named: "TrayIcon") {
                    Image(nsImage: trayImage)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(Color(red: 0.12, green: 0.52, blue: 1.0))
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.12, green: 0.52, blue: 1.0))
                }

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
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.08), in: Capsule())

                Spacer(minLength: 0)

                // Refresh Button
                Button {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        isRefreshing = true
                    }
                    model.onRefresh?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        withAnimation { isRefreshing = false }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Refresh simulators and camera devices")

                // Utilities & Settings Menu (replaces repeated button)
                Menu {
                    Button {
                        model.onOpenSimulator?()
                    } label: {
                        Label("Launch iOS Simulator", systemImage: "iphone.badge.play")
                    }

                    if model.hasBootedSimulator {
                        Button {
                            model.onStartSetup?()
                        } label: {
                            Label("Re-apply Camera Setup", systemImage: "bolt.fill")
                        }
                    }

                    Divider()

                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Camera Privacy Settings…", systemImage: "camera.badge.ellipsis")
                    }

                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Screen Recording Settings…", systemImage: "display.badge.plus")
                    }

                    Divider()

                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit OpenSC", systemImage: "power")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("More utilities and system settings")
            }
            .padding(.top, 1)

            // Live Camera Viewfinder Card with Quick Overlays
            ZStack(alignment: .bottom) {
                // Background preview or placeholder
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
                                .font(.system(size: 22, weight: .light))
                            Text("Waiting for camera stream…")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.45))
                    }
                }

                // Top stream & camera badges overlay
                VStack {
                    HStack {
                        HStack(spacing: 4.5) {
                            Circle()
                                .fill(model.isConnected ? Color.green : Color.gray)
                                .frame(width: 5, height: 5)
                            Text(model.isConnected ? "STREAMING" : "STANDBY")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.4)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)

                        Spacer()

                        // Active Camera Tag
                        Text(model.activeCamera.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.5)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    .padding(6)

                    Spacer()

                    // Bottom utility actions overlay on preview
                    HStack(spacing: 5) {
                        Spacer()

                        // Quick Camera Flip (Front <-> Back)
                        Button {
                            let next = model.activeCamera == "front" ? "back" : "front"
                            model.activeCamera = next
                            model.onSwitchCamera?(next)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "camera.rotate.fill")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(model.activeCamera == "front" ? "Back" : "Front")
                                    .font(.system(size: 8.5, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(.black.opacity(0.72), in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Switch between front and back simulator camera")

                        // Quick Mirror Toggle
                        Button {
                            model.isMirrored.toggle()
                            model.onToggleMirror?()
                        } label: {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(4)
                                .background(
                                    model.isMirrored ? Color.blue.opacity(0.85) : Color.black.opacity(0.72),
                                    in: Circle()
                                )
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle camera mirror")
                    }
                    .padding(6)
                }
            }
            .frame(height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            // Simulator & App Status Card
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.hasBootedSimulator ? Color.blue.opacity(0.14) : Color.white.opacity(0.06))
                        .frame(width: 28, height: 28)
                    Image(systemName: model.hasBootedSimulator ? "iphone" : "iphone.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(model.hasBootedSimulator ? Color.blue : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.simulatorName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(model.appName) · \(model.connectionStatus)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            // Media Source Selector Card with Custom Icons
            HStack(spacing: 8) {
                Image(systemName: activeSourceOption.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.52, blue: 1.0))
                    .frame(width: 20, height: 20)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

                Text("Source")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("", selection: $model.selectedSource) {
                    ForEach(sources) { source in
                        Label(source.title, systemImage: source.icon).tag(source.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 185)
                .onChange(of: model.selectedSource) { _, source in
                    model.onSourceChanged?(source)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))

            // Primary Setup / Simulator Launch Action
            if !model.hasBootedSimulator {
                Button {
                    model.onOpenSimulator?()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Launch iOS Simulator")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.46, blue: 0.88))
            } else if !model.isConnected {
                Button {
                    model.onStartSetup?()
                } label: {
                    HStack(spacing: 6) {
                        if model.isSettingUp {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                        }
                        Text(model.isSettingUp ? "Applying Camera Setup…" : "Apply Camera Setup")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.46, blue: 0.88))
                .disabled(model.isSettingUp)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.green)
                    Text("Camera Hook Active in Simulator")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
            }

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

            // Footer Toolbar: Single Open Studio window button & Quit (NO REPEATED BUTTONS)
            HStack {
                Button {
                    model.onOpenStudio?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 10.5))
                        Text("Open Studio Window")
                            .font(.system(size: 11, weight: .medium))
                    }
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
        .padding(13)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}
