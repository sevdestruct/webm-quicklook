import QuickLookThumbnailing
import WebKit
import AppKit

private class ThumbnailSchemeHandler: NSObject, WKURLSchemeHandler {
  var fileURL: URL?

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let fileURL = fileURL,
          let data = try? Data(contentsOf: fileURL) else {
      task.didFailWithError(URLError(.cannotOpenFile))
      return
    }
    let response = URLResponse(
      url: task.request.url!,
      mimeType: "video/webm",
      expectedContentLength: data.count,
      textEncodingName: nil
    )
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private class ThumbnailRenderer: NSObject, WKScriptMessageHandler {
  private var webView: WKWebView?
  private var window: NSWindow?
  private var timer: Timer?
  private var done = false
  private let maxSize: CGSize
  let completion: (QLThumbnailReply?, Error?) -> Void

  init(request: QLFileThumbnailRequest, completion: @escaping (QLThumbnailReply?, Error?) -> Void) {
    self.completion = completion
    self.maxSize = request.maximumSize
    super.init()

    let scheme = ThumbnailSchemeHandler()
    scheme.fileURL = request.fileURL

    let config = WKWebViewConfiguration()
    config.mediaTypesRequiringUserActionForPlayback = []
    config.setURLSchemeHandler(scheme, forURLScheme: "webm-ql")
    config.userContentController.add(self, name: "frameReady")

    // Start at max size; we'll resize once we know the video dimensions
    let wv = WKWebView(frame: CGRect(origin: .zero, size: maxSize), configuration: config)
    self.webView = wv

    let win = NSWindow(
      contentRect: CGRect(x: -30000, y: -30000, width: maxSize.width, height: maxSize.height),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    // Hosting an offscreen WKWebView used to crash on teardown:
    // _NSWindowTransformAnimation's dealloc fires from CA::Transaction::commit
    // *after* the window has been released, and its retained Block touches
    // freed memory → SIGSEGV. Killing the implicit close/order-out animation
    // closes that window — nothing here is user-visible anyway.
    win.animationBehavior = .none
    win.contentView?.addSubview(wv)
    wv.frame = win.contentView!.bounds
    win.orderBack(nil)
    self.window = win

    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
      self?.fail()
    }

    let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <style>
    * { margin: 0; padding: 0; }
    html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
    video { width: 100%; height: 100%; display: block; }
    </style>
    </head>
    <body>
    <video id="v" src="webm-ql://video" autoplay muted preload="auto"></video>
    <script>
    var v = document.getElementById('v');
    v.addEventListener('loadedmetadata', function() {
      v.currentTime = 0.001;
    });
    v.addEventListener('seeked', function() {
      window.webkit.messageHandlers.frameReady.postMessage({
        width: v.videoWidth,
        height: v.videoHeight
      });
    });
    </script>
    </body>
    </html>
    """
    wv.loadHTMLString(html, baseURL: nil)
  }

  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !done,
          let body = message.body as? [String: Any],
          let vw = body["width"] as? Double,
          let vh = body["height"] as? Double,
          vw > 0, vh > 0 else {
      fail()
      return
    }

    // Fit the video's native aspect ratio inside maxSize
    let aspect = CGFloat(vw) / CGFloat(vh)
    let fitW: CGFloat
    let fitH: CGFloat
    if aspect > maxSize.width / maxSize.height {
      // Video is wider than the box
      fitW = maxSize.width
      fitH = maxSize.width / aspect
    } else {
      // Video is taller than the box
      fitH = maxSize.height
      fitW = maxSize.height * aspect
    }
    let thumbW = floor(fitW)
    let thumbH = floor(fitH)
    let thumbSize = CGSize(width: thumbW, height: thumbH)

    // Resize window and webview to exactly the thumb dimensions
    // so the video element fills edge-to-edge with no gaps
    window?.setContentSize(thumbSize)
    webView?.frame = CGRect(origin: .zero, size: thumbSize)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self = self, !self.done, let wv = self.webView else { return }
      self.done = true
      self.timer?.invalidate()

      let snapConfig = WKSnapshotConfiguration()
      snapConfig.rect = CGRect(origin: .zero, size: thumbSize)
      wv.takeSnapshot(with: snapConfig) { [weak self] image, error in
        guard let self = self else { return }
        self.cleanup()
        guard let image = image else {
          self.completion(nil, error)
          return
        }
        // contextSize MUST equal the actual image size — any mismatch = black bars
        let reply = QLThumbnailReply(contextSize: thumbSize) {
          image.draw(in: CGRect(origin: .zero, size: thumbSize))
          return true
        }
        self.completion(reply, nil)
      }
    }
  }

  private func fail() {
    guard !done else { return }
    done = true
    timer?.invalidate()
    cleanup()
    completion(nil, nil)
  }

  private func cleanup() {
    webView?.stopLoading()
    webView = nil
    window?.close()
    window = nil
  }
}

class ThumbnailProvider: QLThumbnailProvider {
  private var renderers: [UUID: ThumbnailRenderer] = [:]

  override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
    let id = UUID()
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { handler(nil, nil); return }
      let renderer = ThumbnailRenderer(request: request) { [weak self] reply, error in
        DispatchQueue.main.async { self?.renderers.removeValue(forKey: id) }
        handler(reply, error)
      }
      self.renderers[id] = renderer
    }
  }
}
