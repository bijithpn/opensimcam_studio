import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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
    self.isMovableByWindowBackground = true
    self.isOpaque = false
    self.backgroundColor = .clear
    self.contentView?.wantsLayer = true
    self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    self.contentView?.layer?.isOpaque = false
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = NSColor.clear.cgColor
    flutterViewController.view.layer?.isOpaque = false
    
    self.setContentSize(NSSize(width: 360, height: 720))
    self.minSize = NSSize(width: 340, height: 600)
    self.maxSize = NSSize(width: 440, height: 860)
    self.center()

    super.awakeFromNib()
  }
}
