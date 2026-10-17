import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  public static weak var shared: MainFlutterWindow?

  override func awakeFromNib() {
    MainFlutterWindow.shared = self

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    OpenSCBridge.register(with: flutterViewController.registrar(forPlugin: "OpenSCBridge"))

    self.title = "OpenSC"
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.styleMask.insert(.miniaturizable)
    self.delegate = self
    self.isMovableByWindowBackground = true
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false

    // Hide macOS traffic light buttons from view while keeping miniaturize enabled for AppKit
    self.standardWindowButton(.closeButton)?.isHidden = true
    self.standardWindowButton(.zoomButton)?.isHidden = true
    self.standardWindowButton(.closeButton)?.alphaValue = 0
    self.standardWindowButton(.zoomButton)?.alphaValue = 0

    if let minBtn = self.standardWindowButton(.miniaturizeButton) {
      minBtn.isHidden = false
      minBtn.isEnabled = true
      minBtn.alphaValue = 0.0
    }

    self.contentView?.wantsLayer = true
    self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    self.contentView?.layer?.isOpaque = false
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = NSColor.clear.cgColor
    flutterViewController.view.layer?.isOpaque = false
    flutterViewController.backgroundColor = .clear
    
    self.setContentSize(NSSize(width: 365, height: 885))
    self.minSize = NSSize(width: 320, height: 630)
    self.maxSize = NSSize(width: 440, height: 1200)
    self.center()

    super.awakeFromNib()

    // Show floating companion tools window on launch
    DispatchQueue.main.async { [weak self] in
      self?.makeKeyAndOrderFront(nil)
    }
  }

  override var canBecomeKey: Bool {
    return true
  }

  override var canBecomeMain: Bool {
    return true
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    self.makeKeyAndOrderFront(nil)
  }
}
