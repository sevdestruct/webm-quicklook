import Cocoa
import Quartz
import WebKit

// MARK: - Scheme handler

private class WebMSchemeHandler: NSObject, WKURLSchemeHandler {
  var fileURL: URL?
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let fileURL = fileURL, let data = try? Data(contentsOf: fileURL) else {
      task.didFailWithError(URLError(.cannotOpenFile)); return
    }
    let r = URLResponse(url: task.request.url!, mimeType: "video/webm",
                        expectedContentLength: data.count, textEncodingName: nil)
    task.didReceive(r); task.didReceive(data); task.didFinish()
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) { self.target = target }
  func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
    target?.userContentController(ucc, didReceive: msg)
  }
}

// MARK: - Root view with mouse tracking

private class TrackingView: NSView {
  var onMouseMoved:  ((NSEvent) -> Void)?
  var onMouseExited: ((NSEvent) -> Void)?

  // Prevent the QL preview window from being dragged by clicks in the video area.
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(NSTrackingArea(rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
      owner: self, userInfo: nil))
  }
  override func mouseMoved(with event: NSEvent)  { onMouseMoved?(event)  }
  override func mouseExited(with event: NSEvent) { onMouseExited?(event) }
}

// MARK: - Native icon button

class IconButton: NSView {
  var symbolName: String = "" { didSet { img = makeImage(); needsDisplay = true } }
  var tint: NSColor = .white  { didSet { img = makeImage(); needsDisplay = true } }
  var showSlash: Bool = false  { didSet { needsDisplay = true } }

  private var img: NSImage?

  init(symbol: String) {
    super.init(frame: .zero)
    wantsLayer = true
    symbolName = symbol
  }
  required init?(coder: NSCoder) { fatalError() }

  private func makeImage() -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
      .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
    return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(cfg)
  }

  override func draw(_ dirtyRect: NSRect) {
    // Draw icon at natural size, centered in the button frame
    if let img = img {
      let s = img.size
      let r = NSRect(x: (bounds.width  - s.width)  / 2,
                     y: (bounds.height - s.height) / 2,
                     width: s.width, height: s.height)
      img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    }

    guard showSlash else { return }
    let inset: CGFloat = 9
    let path = NSBezierPath()
    path.move(to: NSPoint(x: bounds.width - inset, y: inset))
    path.line(to: NSPoint(x: inset, y: bounds.height - inset))
    path.lineCapStyle = .round

    // Knock out icon pixels along the slash — creates a transparent cutout
    // so the gradient/video shows through rather than painting black over white.
    NSGraphicsContext.current?.compositingOperation = .clear
    path.lineWidth = 2.5; path.stroke()

    // Thin white stroke traces the slash over the cutout
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    NSColor.white.withAlphaComponent(0.85).setStroke()
    path.lineWidth = 1.0; path.stroke()
  }

  // Build a CATransform3D that scales by `s` around the visual center of the
  // button, regardless of what anchorPoint AppKit has set on the backing layer.
  private func centerScaleTransform(_ s: CGFloat) -> CATransform3D {
    let cx = bounds.width  / 2
    let cy = bounds.height / 2
    // Translate center to origin → scale → translate back
    var t = CATransform3DIdentity
    t = CATransform3DTranslate(t,  cx,  cy, 0)
    t = CATransform3DScale(t, s, s, 1)
    t = CATransform3DTranslate(t, -cx, -cy, 0)
    return t
  }

  func animatePress() {
    layer?.removeAnimation(forKey: "scale")
    let a = CABasicAnimation(keyPath: "transform")
    a.toValue    = centerScaleTransform(0.78)
    a.duration   = 0.1
    a.timingFunction     = CAMediaTimingFunction(name: .easeIn)
    a.fillMode           = .forwards
    a.isRemovedOnCompletion = false
    layer?.add(a, forKey: "scale")
  }

  func animateRelease() {
    let a = CAKeyframeAnimation(keyPath: "transform")
    a.values   = [0.78, 1.1, 1.0].map { centerScaleTransform($0) }
    a.keyTimes = [0, 0.5, 1]
    a.duration = 0.22
    a.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer?.add(a, forKey: "scale")
  }
}

// MARK: - Progress bar

private class ProgressBarView: NSView {
  var progress: Double = 0 { didSet { needsDisplay = true } }

  // Callbacks the controller wires up. Owning the mouse session here (instead
  // of via a global NSEvent monitor) is what lets scrubbing work in Finder's
  // column-view inline preview — once an NSView claims mouseDown, AppKit
  // routes subsequent drag/up to the same view and Finder's file-drag
  // tracker doesn't intercept the movement as a file drag.
  var onScrubBegan: ((Double) -> Void)?
  var onScrubMoved: ((Double) -> Void)?
  var onScrubEnded: ((Double) -> Void)?
  var isInteractive: Bool = false   // controller flips this with the overlay's visibility

  override var isOpaque: Bool { false }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // Don't accept hits when the overlay is faded out — the underlying
  // click-on-video toggle should run instead.
  override func hitTest(_ point: NSPoint) -> NSView? {
    isInteractive ? super.hitTest(point) : nil
  }

  private func fraction(for event: NSEvent) -> Double {
    let p = convert(event.locationInWindow, from: nil)
    return max(0, min(1, Double(p.x / bounds.width)))
  }

  override func mouseDown(with event: NSEvent) {
    // Synchronous nextEvent(matching:) tracking — the same approach NSSlider
    // uses. Without this, Finder's column-view inline preview pane treats the
    // drag as a file drag: even with our mouseDown override, Finder's host
    // process is still watching the bridged events for a drag threshold and
    // kicks off an NSDraggingSession before our mouseDragged fires. Pulling
    // events off the queue directly suspends normal distribution for the
    // gesture's lifetime, so the host never sees the moves.
    let f0 = fraction(for: event)
    progress = f0
    onScrubBegan?(f0)
    var tracking = true
    while tracking, let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      let f = fraction(for: next)
      progress = f
      switch next.type {
      case .leftMouseDragged: onScrubMoved?(f)
      case .leftMouseUp:      onScrubEnded?(f); tracking = false
      default: break
      }
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let h: CGFloat = 3, y = (bounds.height - h) / 2, r: CGFloat = 1.5
    NSColor.white.withAlphaComponent(0.3).setFill()
    NSBezierPath(roundedRect: .init(x: 0, y: y, width: bounds.width, height: h), xRadius: r, yRadius: r).fill()
    let w = bounds.width * CGFloat(max(0, min(1, progress)))
    if w > 0 {
      NSColor.white.setFill()
      NSBezierPath(roundedRect: .init(x: 0, y: y, width: w, height: h), xRadius: r, yRadius: r).fill()
    }
  }
}


// MARK: - Preview view controller

class PreviewViewController: NSViewController, QLPreviewingController, WKScriptMessageHandler {

  private let schemeHandler = WebMSchemeHandler()
  private var webView: WKWebView!
  private var dimensionsContinuation: CheckedContinuation<CGSize, Never>?

  // Native controls
  private var controlsContainer: NSView!
  private var playBtn:     IconButton!
  private var muteBtn:     IconButton!
  private var loopBtn:     IconButton!
  private var progressBar: ProgressBarView!

  // Event monitors — intercept before WKWebView consumes them
  private var mouseDownMonitor: Any?
  private var mouseUpMonitor:   Any?
  private var mouseDragMonitor: Any?
  private var pressedButton:    IconButton?
  private var isDraggingProgress    = false
  private var wasPlayingBeforeScrub = false
  private var lastSeekTime: Date    = .distantPast
  private var pendingSeekFraction   = 0.0
  private var hideTimer:        Timer?
  private var gradientLayer:    CAGradientLayer?

  // Video state mirrored in Swift so actions are instant
  private var isPlaying = true
  // Default muted so Finder's column / gallery inline preview pane doesn't
  // start blasting audio the moment the user clicks a file. The QL Space
  // popup gets unmuted automatically once its window appears (see
  // `unmuteIfQuickLookPopup()` below).
  private var isMuted   = true
  private var isLooping = true
  private var duration  = 0.0
  private var muteAutoDecided = false

  // Rollover guard: first mouseMoved sets the baseline; controls only
  // appear once the cursor has actually moved away from that position.
  private var baselineScreenLoc: NSPoint? = nil
  private var controlsUnlocked = false

  // Progress interpolation
  private var lastReportedTime = 0.0
  private var lastReportedWall = Date()
  private var progressTimer: Timer?

  // Catch-up: target time to reach at elevated playback rate after scrub release
  private var catchUpTarget: Double? = nil

  // MARK: - View setup

  override func loadView() {
    let cfg = WKWebViewConfiguration()
    cfg.mediaTypesRequiringUserActionForPlayback = []
    cfg.setURLSchemeHandler(schemeHandler, forURLScheme: "webm-ql")
    let proxy = ScriptMessageProxy(self)
    cfg.userContentController.add(proxy, name: "videoDimensions")
    cfg.userContentController.add(proxy, name: "videoState")
    cfg.userContentController.add(proxy, name: "videoProgress")

    webView = WKWebView(frame: .zero, configuration: cfg)
    webView.allowsMagnification = true
    webView.autoresizingMask = [.width, .height]
    webView.translatesAutoresizingMaskIntoConstraints = true
    // Transparent webView so the rounded corners (below) and the host pane
    // show through instead of a hard black rectangle.
    webView.setValue(false, forKey: "drawsBackground")

    let root = TrackingView()
    root.onMouseMoved  = { [weak self] _ in self?.handleMouseMoved() }
    root.onMouseExited = { [weak self] _ in self?.scheduleHide(0.4)  }
    // Clear background so the letterbox area blends into the host pane (no
    // black frame). No corner rounding — the preview fills the pane as a plain
    // rectangle; fastest path, no transcode, whole frame always visible.
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.clear.cgColor

    self.view = root
    root.addSubview(webView)
    buildControlsBar()
    installEventMonitors()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    baselineScreenLoc = nil   // cleared so first mouseMoved re-establishes it
    controlsUnlocked  = false
  }

  private func buildControlsBar() {
    controlsContainer = NSView()
    controlsContainer.wantsLayer = true
    controlsContainer.alphaValue = 0
    controlsContainer.autoresizingMask = [.width, .minYMargin]
    // Round the controls bar's BOTTOM corners so its opaque gradient follows
    // the rounded corners of the host (the QuickLook Space window is always
    // rounded by macOS) instead of poking square nubs into them. Top corners
    // stay sharp — they sit mid-pane where the gradient is already transparent.
    // (.layerMinXMinYCorner / .layerMaxXMinYCorner = bottom corners; NSView's
    // layer isn't geometry-flipped, so minY is the bottom edge.)
    controlsContainer.layer?.cornerRadius  = 10
    controlsContainer.layer?.cornerCurve   = .continuous
    controlsContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    controlsContainer.layer?.masksToBounds = true
    view.addSubview(controlsContainer)

    // Raw CAGradientLayer as the bottom-most sublayer — sits outside the
    // button screen-blend contexts so it composites cleanly beneath them.
    let grad = CAGradientLayer()
    grad.colors    = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.75)]
    grad.locations = [0, 1]
    grad.startPoint = CGPoint(x: 0.5, y: 1)   // transparent at top
    grad.endPoint   = CGPoint(x: 0.5, y: 0)   // dark at bottom
    controlsContainer.layer?.insertSublayer(grad, at: 0)
    gradientLayer = grad

    playBtn = IconButton(symbol: "pause.fill")
    muteBtn = IconButton(symbol: "speaker.fill")
    loopBtn = IconButton(symbol: "repeat")
    progressBar = ProgressBarView()
    progressBar.onScrubBegan = { [weak self] f in self?.scrubBegan(fraction: f) }
    progressBar.onScrubMoved = { [weak self] f in self?.scrubMoved(fraction: f) }
    progressBar.onScrubEnded = { [weak self] f in self?.scrubEnded(fraction: f) }

    for v in [playBtn!, muteBtn!, loopBtn!, progressBar!] as [NSView] {
      controlsContainer.addSubview(v)
    }

    progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
      self?.tickProgress()
    }
  }

  // MARK: - Event monitors (bypass WKWebView event interception entirely)

  private func installEventMonitors() {
    mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      return self?.interceptMouseDown(event) ?? event
    }
    mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      self?.interceptMouseUp()
      return event
    }
    mouseDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
      return self?.interceptMouseDragged(event) ?? event
    }
  }

  private func interceptMouseDown(_ event: NSEvent) -> NSEvent? {
    func loc(in view: NSView) -> NSPoint { view.convert(event.locationInWindow, from: nil) }
    func hit(_ view: NSView) -> Bool { view.bounds.contains(loc(in: view)) }

    // Button & progress-bar hits only register when the controls overlay is
    // actually showing — otherwise we'd be hitting invisible targets.
    let controlsVisible = controlsContainer.alphaValue > 0.1
    if controlsVisible {
      if hit(playBtn) { pressedButton = playBtn; playBtn.animatePress(); togglePlay(); return nil }
      if hit(muteBtn) { pressedButton = muteBtn; muteBtn.animatePress(); toggleMute(); return nil }
      if hit(loopBtn) { pressedButton = loopBtn; loopBtn.animatePress(); toggleLoop(); return nil }
      // Progress-bar hits are handled by ProgressBarView's own mouseDown/
      // Dragged/Up overrides — that's what lets scrubbing survive Finder's
      // column-view file-drag tracker. Don't claim the event here, just
      // step out of the way so AppKit can route it to the bar.
      if hit(progressBar) { return event }
    }
    // Click-anywhere-on-video toggles play/pause — works whether or not the
    // controls overlay is visible. When the overlay IS visible, treat its
    // strip as UI (so dead-clicking between buttons doesn't toggle); when
    // hidden, the strip is just empty pixels and a click there is fair game.
    let inControlsStrip = controlsVisible && controlsContainer.bounds.contains(loc(in: controlsContainer))
    if !inControlsStrip, hit(webView) {
      togglePlay()
      return nil
    }
    return event
  }

  private func interceptMouseDragged(_ event: NSEvent) -> NSEvent? {
    // Scrubbing drag is handled inside ProgressBarView itself.
    return event
  }

  private func interceptMouseUp() {
    pressedButton?.animateRelease()
    pressedButton = nil
    // Scrub end is handled inside ProgressBarView.
  }

  // MARK: - Scrub callbacks (wired up in loadView)

  fileprivate func scrubBegan(fraction f: Double) {
    wasPlayingBeforeScrub = isPlaying
    isDraggingProgress    = true
    catchUpTarget         = nil
    // reset to 1× in case we were catching up
    webView.evaluateJavaScript("document.getElementById('v').playbackRate=1", completionHandler: nil)
    if wasPlayingBeforeScrub {
      webView.evaluateJavaScript("document.getElementById('v').pause()", completionHandler: nil)
    }
    pendingSeekFraction = f
    seek(fraction: f)
  }

  fileprivate func scrubMoved(fraction f: Double) {
    guard isDraggingProgress else { return }
    pendingSeekFraction = f
    // Throttle actual video seeks to ~15fps so the decoder isn't flooded.
    let now = Date()
    if now.timeIntervalSince(lastSeekTime) >= 0.066 {
      lastSeekTime = now
      let t = duration * f
      webView.evaluateJavaScript("document.getElementById('v').currentTime=\(t)", completionHandler: nil)
      lastReportedTime = t; lastReportedWall = now
    }
  }

  fileprivate func scrubEnded(fraction f: Double) {
    guard isDraggingProgress else { return }
    isDraggingProgress = false
    pendingSeekFraction = f
    let t = duration * f
    webView.evaluateJavaScript("document.getElementById('v').currentTime=\(t)", completionHandler: nil)
    lastReportedTime = t; lastReportedWall = Date()
    if wasPlayingBeforeScrub {
      // Record target so the progress handler can ramp up playbackRate to
      // close any decoder lag (video frame vs. scrubber position).
      catchUpTarget = t
      webView.evaluateJavaScript("document.getElementById('v').play()", completionHandler: nil)
      scheduleHide(0.4)
    }
  }

  // MARK: - Layout

  override func viewDidLayout() {
    super.viewDidLayout()
    let w = view.bounds.width
    webView.frame = view.bounds
    unmuteIfQuickLookPopup()

    let btnH:  CGFloat = 30
    let barH:  CGFloat = 44
    let gradH: CGFloat = barH + 32
    let margin: CGFloat = 10
    let gap:    CGFloat = 4

    controlsContainer.frame = NSRect(x: 0, y: 0, width: w, height: gradH)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer?.frame = controlsContainer.bounds
    CATransaction.commit()

    let btnY  = (barH - btnH) / 2
    let progH: CGFloat = 20
    let progY = (barH - progH) / 2

    let playX = margin
    let loopX = w - margin - btnH
    let muteX = loopX - gap - btnH
    let progX = playX + btnH + gap
    let progW = muteX - progX - gap

    playBtn.frame     = NSRect(x: playX, y: btnY, width: btnH, height: btnH)
    muteBtn.frame     = NSRect(x: muteX, y: btnY, width: btnH, height: btnH)
    loopBtn.frame     = NSRect(x: loopX, y: btnY, width: btnH, height: btnH)
    progressBar.frame = NSRect(x: progX, y: progY, width: progW, height: progH)
  }

  // MARK: - Controls visibility

  private func handleMouseMoved() {
    let cur = NSEvent.mouseLocation
    if !controlsUnlocked {
      guard let baseline = baselineScreenLoc else {
        // First event after appearing: just record position, show nothing.
        baselineScreenLoc = cur
        return
      }
      // Only unlock once the cursor has genuinely moved from that first position.
      guard abs(cur.x - baseline.x) > 4 || abs(cur.y - baseline.y) > 4 else { return }
      controlsUnlocked = true
    }
    showControls()
    scheduleHide(1.0)
  }

  private func showControls() {
    progressBar.isInteractive = true
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      controlsContainer.animator().alphaValue = 1
    }
  }

  private func hideControls() {
    guard !isDraggingProgress else { return }
    progressBar.isInteractive = false
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.4
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      controlsContainer.animator().alphaValue = 0
    }
  }

  private func scheduleHide(_ seconds: Double) {
    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.hideControls()
    }
  }

  // MARK: - Actions (called from event monitor — zero latency)

  private func togglePlay() {
    isPlaying.toggle()
    refreshPlayButton()
    if isPlaying {
      webView.evaluateJavaScript("document.getElementById('v').play()", completionHandler: nil)
      scheduleHide(0.4)
    } else {
      // Cancel any catch-up and restore normal rate before pausing
      if catchUpTarget != nil {
        webView.evaluateJavaScript("document.getElementById('v').playbackRate=1", completionHandler: nil)
        catchUpTarget = nil
      }
      webView.evaluateJavaScript("document.getElementById('v').pause()", completionHandler: nil)
      scheduleHide(1.0)
    }
  }

  private func toggleMute() {
    isMuted.toggle()
    refreshMuteButton()
    webView.evaluateJavaScript("document.getElementById('v').muted=\(isMuted)", completionHandler: nil)
  }

  private func toggleLoop() {
    isLooping.toggle()
    refreshLoopButton()
    let js = "var v=document.getElementById('v');v.loop=\(isLooping);if(\(isLooping)&&v.ended)v.play()"
    webView.evaluateJavaScript(js, completionHandler: nil)
  }

  private func seek(fraction: Double) {
    let f = max(0, min(1, fraction))
    let t = duration * f
    webView.evaluateJavaScript("document.getElementById('v').currentTime=\(t)", completionHandler: nil)
    lastReportedTime = t
    lastReportedWall = Date()
    progressBar.progress = f
  }

  private func refreshPlayButton() {
    playBtn.symbolName = isPlaying ? "pause.fill" : "play.fill"
    playBtn.tint = .white
  }

  private func refreshMuteButton() {
    muteBtn.symbolName  = isMuted ? "speaker.slash.fill" : "speaker.fill"
    muteBtn.tint        = .white
    muteBtn.alphaValue  = isMuted ? 0.35 : 1.0
  }

  private func refreshLoopButton() {
    loopBtn.symbolName = "repeat"
    loopBtn.tint       = .white          // always white — opacity on the view handles dimming
    if isLooping {
      loopBtn.alphaValue = 1.0
      loopBtn.showSlash  = false
    } else {
      loopBtn.alphaValue = 0.35          // dims icon + slash together as one unit
      loopBtn.showSlash  = true
    }
  }

  // MARK: - Smooth progress (60fps native interpolation from 10fps JS reports)

  private func tickProgress() {
    guard isPlaying, duration > 0 else { return }
    let interpolated = min(duration, lastReportedTime + Date().timeIntervalSince(lastReportedWall))
    progressBar.progress = interpolated / duration
  }

  // MARK: - Script messages

  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
    switch message.name {
    case "videoDimensions":
      guard let b = message.body as? [String: Any],
            let w = b["width"] as? Double, let h = b["height"] as? Double,
            w > 0, h > 0 else { return }
      dimensionsContinuation?.resume(returning: CGSize(width: w, height: h))
      dimensionsContinuation = nil

    case "videoState":
      guard let b = message.body as? [String: Any] else { return }
      if let paused = b["paused"]  as? Bool { isPlaying = !paused; refreshPlayButton() }
      if let muted  = b["muted"]   as? Bool { isMuted   = muted;   refreshMuteButton() }
      if let loop   = b["loop"]    as? Bool { isLooping = loop;    refreshLoopButton() }
      if let dur    = b["duration"] as? Double, dur > 0 { duration = dur }
      if let ct     = b["currentTime"] as? Double { lastReportedTime = ct; lastReportedWall = Date() }

    case "videoProgress":
      guard let b = message.body as? [String: Any],
            let ct  = b["currentTime"] as? Double,
            let dur = b["duration"]    as? Double, dur > 0 else { return }
      duration = dur
      lastReportedTime = ct
      lastReportedWall = Date()

      // Dynamic catch-up: if the decoder is behind the scrub release point,
      // scale playbackRate proportionally to the lag so playback rushes ahead
      // to meet the target, then drops back to 1×.
      if let target = catchUpTarget, isPlaying, !isDraggingProgress {
        let lag = target - ct
        if lag > 0.08 {
          // rate grows with lag: e.g. 0.5s → 1.75×, 1.5s → 3.25×, cap at 4×
          let rate = min(4.0, 1.0 + lag * 1.5)
          webView.evaluateJavaScript(
            "document.getElementById('v').playbackRate=\(String(format: "%.2f", rate))",
            completionHandler: nil)
        } else {
          // Close enough — snap back to normal speed
          webView.evaluateJavaScript("document.getElementById('v').playbackRate=1",
                                     completionHandler: nil)
          catchUpTarget = nil
        }
      }

    default: break
    }
  }

  // MARK: - Preview lifecycle

  func preparePreviewOfFile(at url: URL) async {
    schemeHandler.fileURL = url

    let html = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
    * { margin:0; padding:0; }
    /* Transparent (not black): the letterbox area blends into the host pane
       instead of showing black bars, so there's no visible "frame" around the
       video even though Finder fixes the pane size. No rounding — plain fill. */
    html, body { width:100%; height:100%; overflow:hidden; background:transparent; }
    video { width:100%; height:100%; object-fit:contain; display:block; }
    </style></head><body>
    <video id="v" autoplay muted loop preload="auto" src="webm-ql://video"></video>
    <script>
    var v = document.getElementById('v');
    function sendState() {
      window.webkit.messageHandlers.videoState.postMessage({
        paused: v.paused, muted: v.muted, loop: v.loop,
        duration: v.duration || 0, currentTime: v.currentTime
      });
    }
    v.addEventListener('play',  sendState);
    v.addEventListener('pause', sendState);
    v.addEventListener('ended', sendState);
    v.addEventListener('loadedmetadata', function() {
      if (v.videoWidth > 0 && v.videoHeight > 0) {
        window.webkit.messageHandlers.videoDimensions.postMessage(
          {width: v.videoWidth, height: v.videoHeight});
      }
      sendState();
    });
    setInterval(function() {
      if (v.duration) window.webkit.messageHandlers.videoProgress.postMessage(
        {currentTime: v.currentTime, duration: v.duration});
    }, 100);
    </script></body></html>
    """

    let size: CGSize = await withCheckedContinuation { continuation in
      self.dimensionsContinuation = continuation
      self.webView.loadHTMLString(html, baseURL: nil)
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if self.dimensionsContinuation != nil {
          self.dimensionsContinuation?.resume(returning: .zero)
          self.dimensionsContinuation = nil
        }
      }
    }

    if size != .zero { preferredContentSize = Self.fittedSize(size) }
  }

  private static func fittedSize(_ s: CGSize) -> CGSize {
    let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
    let scale = min(screen.width * 0.9 / s.width, screen.height * 0.85 / s.height)
    return CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
  }

  /// Decide whether this preview instance is being shown in the QuickLook
  /// Space-bar popup (sound on) vs Finder's column / gallery inline preview
  /// pane (stay muted). Finder's inline pane is fixed-size and noticeably
  /// narrow; the QL popup gets sized to fit the video and lands well above
  /// that threshold.
  ///
  /// Called on every viewDidLayout because the QL popup is hosted at an
  /// initial small size, then resized to fit the video once dimensions
  /// arrive — locking the decision on the first measurement would leave the
  /// popup permanently muted. We only lock the decision when we positively
  /// identify the QL popup; while we still think we're in Finder, we keep
  /// re-checking in case a later layout reveals a popup-sized window.
  private func unmuteIfQuickLookPopup() {
    guard !muteAutoDecided else { return }
    guard let hostWidth = view.window?.frame.width, hostWidth > 0 else { return }
    // Finder column / gallery inline preview is fixed around the 280pt mark;
    // QL Space popup is sized to fit the actual video (480p+ in practice).
    // 380pt is comfortably between the two.
    guard hostWidth >= 380 else { return }
    muteAutoDecided = true
    isMuted = false
    webView.evaluateJavaScript("document.getElementById('v').muted=false", completionHandler: nil)
    refreshMuteButton()
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    if let m = mouseDownMonitor { NSEvent.removeMonitor(m); mouseDownMonitor = nil }
    if let m = mouseUpMonitor   { NSEvent.removeMonitor(m); mouseUpMonitor   = nil }
    if let m = mouseDragMonitor { NSEvent.removeMonitor(m); mouseDragMonitor = nil }
    progressTimer?.invalidate(); progressTimer = nil
    hideTimer?.invalidate();     hideTimer     = nil
    dimensionsContinuation?.resume(returning: .zero)
    dimensionsContinuation = nil
    webView.stopLoading()
    webView.loadHTMLString("", baseURL: nil)
    schemeHandler.fileURL = nil
  }
}
