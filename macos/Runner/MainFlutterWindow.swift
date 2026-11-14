import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let clipboardChannel = FlutterMethodChannel(
      name: "wechat_selkies/clipboard_image",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    let nudgeChannel = FlutterMethodChannel(
      name: "wechat_selkies/wkwebview_nudge",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    nudgeChannel.setMethodCallHandler { call, result in
      guard call.method == "nudge" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // 遍历视图树找 WKWebView,做 1px frame 抖动强制一次渲染事务。
      // WKWebView 在 App 失焦后可能把内部 visibility 卡在 hidden(occlusion
      // 不回传),合成层暂停上帧;JS 层覆写 document.hidden 无效(内部用
      // C++ 侧状态)。frame 变更会强制 WebKit 重新布局并恢复上帧。
      // isKindOfClass 匹配任意 WKWebView 子类(插件可能用子类,类名不含
      // "WKWebView",按类名字符串匹配会漏);视图树找不到再兜底遍历本 app
      // 所有窗口的 contentView。
      func findWKWebView(_ view: NSView) -> WKWebView? {
        if let wv = view as? WKWebView { return wv }
        for sub in view.subviews {
          if let hit = findWKWebView(sub) { return hit }
        }
        return nil
      }
      var target: WKWebView? = findWKWebView(flutterViewController.view)
      if target == nil {
        for win in NSApp.windows {
          if let cv = win.contentView, let hit = findWKWebView(cv) {
            target = hit
            break
          }
        }
      }
      guard let web = target else {
        result(FlutterError(code: "no_webview", message: "WKWebView not found", details: nil))
        return
      }
      // 实测定案:view 级/窗口缩放级抖动都唤不醒深度冻结的合成层;
      // 唯一有效 = 整窗 orderOut 再 makeKeyAndOrderFront(把窗口短暂
      // 摘出屏幕,强制 WindowServer 重建该窗口的全部图层)。
      if let win = web.window {
        win.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
          win.makeKeyAndOrderFront(nil)
        }
      } else {
        let origFrame = web.frame
        var nudgedFrame = origFrame
        nudgedFrame.size.height += 1
        web.frame = nudgedFrame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          web.frame = origFrame
        }
      }
      result(nil)
    }

    clipboardChannel.setMethodCallHandler { call, result in
      guard call.method == "writeImage",
            let args = call.arguments as? [String: Any],
            let typed = args["data"] as? FlutterStandardTypedData,
            !typed.data.isEmpty else {
        result(FlutterMethodNotImplemented)
        return
      }
      let mime = (args["mimeType"] as? String) ?? "image/png"
      // NSPasteboard 只认 UTI(如 public.png);直接把 MIME 字符串
      // "image/png" 当类型写入会变成无人能读的自定义类型,粘贴时拿不到内容。
      let uti: NSPasteboard.PasteboardType
      switch mime {
      case "image/png", "image/apng":
        uti = NSPasteboard.PasteboardType("public.png")
      case "image/jpeg", "image/jpg":
        uti = NSPasteboard.PasteboardType("public.jpeg")
      case "image/tiff", "image/tif":
        uti = NSPasteboard.PasteboardType("public.tiff")
      case "image/gif":
        uti = NSPasteboard.PasteboardType("com.compuserve.gif")
      case "image/bmp":
        uti = NSPasteboard.PasteboardType("com.microsoft.bmp")
      case "image/webp":
        uti = NSPasteboard.PasteboardType("public.webp")
      default:
        uti = NSPasteboard.PasteboardType(mime)
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      var ok = pasteboard.setData(typed.data, forType: uti)
      if !ok, let img = NSImage(data: typed.data) {
        // 原始字节写不进去(如 mime 未映射)时经 NSImage 转写,
        // macOS 会自动提供 TIFF 等转换格式。
        pasteboard.clearContents()
        ok = pasteboard.writeObjects([img])
      }
      if ok {
        result(nil)
      } else {
        result(FlutterError(code: "write_failed",
                            message: "NSPasteboard write failed",
                            details: mime))
      }
    }

    super.awakeFromNib()
  }
}
