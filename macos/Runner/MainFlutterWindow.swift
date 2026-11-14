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

    // 视图树 + 全窗口兜底查找 WKWebView(插件可能子类化,须 isKindOfClass)。
    func findWKWebViewAll() -> WKWebView? {
      func find(_ v: NSView) -> WKWebView? {
        if let wv = v as? WKWebView { return wv }
        for sub in v.subviews {
          if let hit = find(sub) { return hit }
        }
        return nil
      }
      if let hit = find(flutterViewController.view) { return hit }
      for win in NSApp.windows {
        if let cv = win.contentView, let hit = find(cv) { return hit }
      }
      return nil
    }

    // 对 web 区域当前**屏幕合成结果**取像素哈希(冻结探测)。
    // 只采 WKWebView 区域并裁掉底部 snackbar 带:整窗哈希会被活着的
    // Flutter 工具栏/覆盖层重绘污染,造成"假活"误判(实测踩过)。
    func sampleWebViewHash() -> String? {
      let wid = CGWindowID(self.windowNumber)
      guard let web = findWKWebViewAll(),
            let win = web.window,
            let cv = win.contentView,
            let shot = CGWindowListCreateImage(
              .null, .optionOnScreenBelowWindow, wid,
              [.bestResolution, .boundsIgnoreFraming]) else { return nil }
      // web.frame(view 坐标)→窗口坐标→截图像素(backing 缩放)。
      let inWin = cv.convert(web.frame, from: web)
      let scale = CGFloat(shot.width) / max(1, cv.bounds.width)
      var crop = CGRect(x: inWin.origin.x * scale,
                        y: inWin.origin.y * scale,
                        width: inWin.width * scale,
                        height: max(10, inWin.height * scale - 96 * scale))
      crop = crop.intersection(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
      guard let cg = shot.cropping(to: crop) else { return nil }
      let rep = NSBitmapImageRep(cgImage: cg)
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
      return String(hash)
    }

    let nudgeChannel = FlutterMethodChannel(
      name: "wechat_selkies/wkwebview_nudge",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    nudgeChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "nudge":
        // 唤醒冻结合成层:app 级 hide/unhide。⚠️ hide 后必须给足间隔再
        // unhide(80ms 实测会竞态失败,app 卡在隐藏态——比冻结更糟),
        // 且 unhide 后要 activate + 对不可见窗口 orderFrontRegardless
        // 双兜底。仅在探测器确认冻结后才会被调用(见 Dart 侧)。
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          NSApp.unhide(nil)
          if #available(macOS 14.0, *) {
            NSApp.activate()
          } else {
            NSApp.activate(ignoringOtherApps: true)
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for w in NSApp.windows where w.canBecomeMain && !w.isVisible {
              w.orderFrontRegardless()
            }
          }
        }
        result(nil)
      case "sampleWindow":
        if let h = sampleWebViewHash() {
          result(h)
        } else {
          result(FlutterError(code: "capture_failed", message: nil, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let clipboardChannel = FlutterMethodChannel(
      name: "wechat_selkies/clipboard_image",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
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
