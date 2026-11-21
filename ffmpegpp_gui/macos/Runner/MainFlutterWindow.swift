import Cocoa
import FlutterMacOS
// 独立面板窗口（desktop_multi_window）：子窗口是独立引擎，插件不会自动注册。
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 新建子窗口时，给那个引擎也注册一遍插件，否则子窗口里
    // window_manager（窗口拖动/关闭）等插件都调不动。
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }

    super.awakeFromNib()
  }
}
