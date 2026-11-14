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
      if call.method == "sampleWindow" {
        // 捕获本窗口当前**屏幕合成结果**并返回像素哈希;两次采样相同
        // 且 WS 帧在流动 = 合成层死锁的铁证(JS 探针看不见这个状态)。
        let wid = CGWindowID(self.windowNumber)
        guard let shot = CGWindowListCreateImage(
                .null, .optionOnScreenBelowWindow, wid,
                [.bestResolution, .boundsIgnoreFraming]) else {
          result(FlutterError(code: "capture_failed", message: nil, details: nil))
          return
        }
        let rep = NSBitmapImageRep(cgImage: shot)
        var hash: UInt64 = 0xcbf29ce484222325
        let w = rep.pixelsWide, h = rep.pixelsHigh
        if let data = rep.bitmapData {
          for y in stride(from: 0, to: h, by: max(1, h / 48)) {
            let row = data + y * rep.bytesPerRow
            for x in stride(from: 0, to: w, by: max(1, w / 48)) {
              let px = row + x * 4
              for b in 0..<4 {
                hash ^= UInt64(px[b])
                hash = hash &* 0x100000001b3
              }
            }
          }
        }
        result(String(hash))
        return
      }

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
      // 实测定案:能唤醒冻结合成层的是 **app 级 hide/unhide**(手动
      // System Events visible 开关验证过);窗口级 orderOut 在部分遮挡
      // 场景不足。顺序:hide → 80ms → unhide + 前台。
      NSApp.hide(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
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
