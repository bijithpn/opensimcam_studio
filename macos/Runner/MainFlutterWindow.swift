import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    OpenSimCamBridge.register(with: flutterViewController.registrar(forPlugin: "OpenSimCamBridge"))

    self.title = "OpenSimCam Studio"
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.styleMask.remove(.miniaturizable)
    self.delegate = self
    self.isMovableByWindowBackground = true
    self.isOpaque = true
    self.backgroundColor = NSColor(srgbRed: 0.08, green: 0.085, blue: 0.095, alpha: 1)
    self.contentView?.wantsLayer = true
    self.contentView?.layer?.backgroundColor = self.backgroundColor.cgColor
    self.contentView?.layer?.isOpaque = true
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = self.backgroundColor.cgColor
    flutterViewController.view.layer?.isOpaque = true
    
    self.setContentSize(NSSize(width: 360, height: 720))
    self.minSize = NSSize(width: 340, height: 600)
    self.maxSize = NSSize(width: 440, height: 860)
    self.center()

    super.awakeFromNib()

    // Run the camera and status tray as a background utility by default.
    // The user can bring Studio forward from the tray when needed.
    DispatchQueue.main.async { [weak self] in
      self?.orderOut(nil)
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
}
