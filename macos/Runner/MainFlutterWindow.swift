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
    self.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1.0)
    
    self.setContentSize(NSSize(width: 360, height: 720))
    self.minSize = NSSize(width: 340, height: 600)
    self.maxSize = NSSize(width: 440, height: 860)
    self.center()

    super.awakeFromNib()
  }
}
