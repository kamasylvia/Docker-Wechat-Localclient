/// macOS WebCodecs 资源泄漏的页面级兜底。
///
/// 已知问题：macOS 上 WebCodecs 的 `VideoDecoder` 在页面不可见时不会自动
/// 释放 VideoToolbox/CoreMedia 资源；Selkies 页面只停止绘制，仍继续解码，
/// 于是 WebContent 进程的 `CMSampleBuffer` 持续累积（实测 26 小时约 3.1M 个，
/// 进程 footprint 2.7 GB）。Chromium/WebCodecs 同一问题的结论是：页面隐藏时
/// 必须显式 `decoder.close()`，可见时再重建。
///
/// 本脚本在 document-start 包装 `VideoDecoder`：
/// 1. 记录页面创建的所有 decoder；
/// 2. 页面隐藏/停止 requestAnimationFrame（被遮挡、最小化、切到后台）时关闭
///    全部 decoder，并丢弃隐藏期间的 decode 调用；
/// 3. 恢复可见时再关闭一次（丢弃隐藏期间重建的实例），让页面按自己的
///    “decoder closed → initializeDecoder” 路径重建。
///
/// 不改变可见期间的解码/绘制路径；只影响隐藏期间的解码资源。
String videoDecoderVisibilityGuardScript() => r'''
(function(){
  if (window.__selkiesVideoDecoderGuard) return;
  window.__selkiesVideoDecoderGuard = true;

  var decoders = [];
  var lastRaf = Date.now();
  var hidden = false;
  var forcedBackground = false;

  function raf(){
    lastRaf = Date.now();
    try { window.__selkiesRafPulse = lastRaf; } catch (e) {}
    window.requestAnimationFrame(raf);
  }
  window.requestAnimationFrame(raf);

  // document.hidden 覆盖最小化/切后台；rAF 停止覆盖窗口被遮挡但页面仍报
  // visible 的情况。两者任一成立都视为后台。
  // ⚠️ 2026-11-15 定案(二分实锤):rAF/hidden 判据在窗口遮挡场景会把
  // decode 永久早退(页面无 x264 重建路径)→ 冻屏。decode 门控只认 Dart
  // 显式挂起(app 真后台 ≥30s);遮挡期间 decode 照跑,内存由 30s 路径兜底。
  function isBackground(){
    if (forcedBackground) return true;
    return false;
  }

  function closeAll(){
    for (var i = 0; i < decoders.length; i++) {
      var d = decoders[i];
      try { if (d && d.state !== 'closed') d.close(); } catch(e) {}
    }
    decoders.length = 0;
  }

  // Flutter 生命周期信号：WKWebView 不一定会把“应用失焦/被遮挡”反映成
  // document.hidden，rAF 也可能继续跑；此时由 Dart 侧在失焦 30s 后调用
  // setActive(false)，回前台再调用 setActive(true)。
  window.__selkiesDecoderGuardSetActive = function(active){
    forcedBackground = !active;
    closeAll();
  };

  function install(){
    var VD = window.VideoDecoder;
    if (!VD || VD.__guardInstalled) return false;

    var origDecode = VD.prototype.decode;
    VD.prototype.decode = function(chunk){
      if (isBackground()) return;
      return origDecode.apply(this, arguments);
    };

    var Wrapped = new Proxy(VD, {
      construct: function(target, args){
        var d = Reflect.construct(target, args);
        try { decoders.push(d); } catch(e) {}
        return d;
      }
    });
    try {
      Object.defineProperty(window, 'VideoDecoder', {
        value: Wrapped, configurable: true, writable: true
      });
    } catch(e) {
      try { window.VideoDecoder = Wrapped; } catch(e2) { return false; }
    }
    if (window.VideoDecoder !== Wrapped) return false;
    VD.__guardInstalled = true;
    return true;
  }

  if (!install()) {
    var tries = 0;
    var t = setInterval(function(){
      if (install() || ++tries > 100) clearInterval(t);
    }, 50);
  }

  function update(){
    var h = isBackground();
    if (h === hidden) return;
    hidden = h;
    // ⚠️ 状态迁移不 closeAll:关闭后页面无法重建解码器(x264 无 rt() 路径),
    // 切回即冻屏。深度释放仅由 Dart 30s 挂起路径(setActive)执行。
  }

  setInterval(update, 500);
  document.addEventListener('visibilitychange', update);
  update();
})();
''';
