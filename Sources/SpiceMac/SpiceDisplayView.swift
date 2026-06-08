import AppKit
import MetalKit
import CocoaSpice
import CocoaSpiceRenderer
import SpiceController

/// The Metal-backed view that renders one SPICE display and is the keyboard/mouse
/// first responder. CocoaSpice draws into it via a `CSMetalRenderer` set as the
/// `MTKView` delegate; AppKit events are forwarded to a `SpiceInputRouter`.
final class SpiceDisplayView: MTKView {

    let router = SpiceInputRouter()
    private var renderer: CSMetalRenderer?
    private(set) weak var attachedDisplay: CSDisplay?

    /// KVO token for the attached display's `displaySize` (guest resolution may
    /// change after the agent connects / a mode switch).
    private var displaySizeObservation: NSKeyValueObservation?

    /// Whether we've hidden the macOS cursor (so only the guest cursor shows).
    /// Tracked so hide/unhide stay balanced and the cursor can't get stuck hidden.
    private var hostCursorHidden = false

    /// Observer for the "Hide Mac Cursor" preference toggling at runtime.
    private var hideCursorPrefObserver: NSObjectProtocol?

    /// Observer that restores the macOS cursor when the app deactivates (⌘-Tab,
    /// ⌘H, …) — those don't fire mouseExited/resignFirstResponder, so without this
    /// a hidden cursor could stay hidden system-wide.
    private var appResignObserver: NSObjectProtocol?

    init() {
        // CSMetalRenderer reads `mtkView.device` at init, so the device must exist
        // before -attachDisplay creates the renderer.
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 768),
                   device: MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if device == nil { device = MTLCreateSystemDefaultDevice() }
        commonInit()
    }

    private func commonInit() {
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        // Frames are pushed by CocoaSpice; run continuously so the latest texture
        // is always presented.
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        wantsLayer = true
        layer?.isOpaque = true

        hideCursorPrefObserver = NotificationCenter.default.addObserver(
            forName: .hideHostCursorChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateHostCursorVisibility()
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.showHostCursor()
        }
    }

    deinit {
        showHostCursor()
        for observer in [hideCursorPrefObserver, appResignObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func attachDisplay(_ display: CSDisplay) {
        detach()
        attachedDisplay = display
        let renderer = CSMetalRenderer(metalKitView: self)
        delegate = renderer
        self.renderer = renderer
        display.addRenderer(renderer)
        router.displaySizeProvider = { [weak display] in display?.displaySize ?? .zero }
        // In client mouse mode we must position the guest cursor overlay ourselves.
        router.cursorMover = { [weak display] point in display?.cursor?.move(to: point) }
        // The input router maps a view point -> guest pixel using the SAME fit math
        // the renderer uses, so the guest cursor lands under the macOS pointer.
        router.viewportInfoProvider = { [weak self] in
            guard let info = self?.viewportInfo() else { return nil }
            return SpiceInputRouter.ViewportInfo(
                guestSize: info.guestSize,
                drawableSize: info.drawableSize,
                scale: info.scale,
                origin: info.origin,
                backingScale: info.backingScale)
        }

        // Recompute the fit whenever the guest changes resolution (post-agent
        // connect, mode switches). Fire once immediately for the current size.
        displaySizeObservation = display.observe(\.displaySize, options: [.initial]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.updateViewport() }
        }
    }

    func detach() {
        showHostCursor()
        if let attachedDisplay, let renderer {
            attachedDisplay.removeRenderer(renderer)
        }
        displaySizeObservation = nil
        delegate = nil
        renderer = nil
        attachedDisplay = nil
        // NB: do NOT clear router.input here. The inputs channel is independent of
        // the display; its lifecycle is driven by spiceInput{Available,Unavailable}.
        // attachDisplay() calls detach() on every (re)attach (e.g. when the agent
        // connects and the display reconfigures), so clearing input here would
        // silently kill keyboard/mouse while the input channel is still alive.
    }

    // MARK: - Viewport fit (aspect-preserving, centered)

    /// Current backing scale (points -> physical/drawable pixels). Falls back to
    /// the view's `convertToBacking` so it is correct even before `window` is set.
    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? convertToBacking(CGSize(width: 1, height: 1)).width
    }

    /// Snapshot of everything the input router needs to inverse-map a view point
    /// to a guest pixel: the guest size, the drawable size, and the active
    /// fit-scale/origin. All sizes are in DRAWABLE (physical) pixels except
    /// `guestSize`, which is in guest pixels.
    struct ViewportInfo {
        var guestSize: CGSize       // guest pixels (W, H)
        var drawableSize: CGSize    // physical pixels (Dw, Dh)
        var scale: CGFloat          // drawable-pixels per guest-pixel
        var origin: CGPoint         // viewportOrigin, drawable pixels
        var backingScale: CGFloat   // points -> drawable pixels
    }

    func viewportInfo() -> ViewportInfo? {
        guard let guest = attachedDisplay?.displaySize,
              guest.width > 0, guest.height > 0 else { return nil }
        let drawable = drawableSize
        let scale = Self.fitScale(guest: guest, drawable: drawable)
        // We center via viewportOrigin = .zero (the renderer centers the quad).
        return ViewportInfo(guestSize: guest,
                            drawableSize: drawable,
                            scale: scale,
                            origin: .zero,
                            backingScale: backingScale)
    }

    /// Largest uniform scale that fits the guest display inside the drawable
    /// (aspect-preserving "fit with black bars"). Use `max` for cover/fill.
    private static func fitScale(guest: CGSize, drawable: CGSize) -> CGFloat {
        guard guest.width > 0, guest.height > 0,
              drawable.width > 0, drawable.height > 0 else { return 1.0 }
        return min(drawable.width / guest.width, drawable.height / guest.height)
    }

    /// Push the aspect-fit scale to the renderer. Centering is automatic: the
    /// renderer draws the guest quad centered on the drawable, so viewportOrigin
    /// stays .zero and the letterbox bars are split evenly.
    private func updateViewport() {
        guard let renderer, let info = viewportInfo() else { return }
        renderer.viewportScale = info.scale
        renderer.viewportOrigin = .zero
    }

    // Recompute on any geometry change. `drawableSize` tracks `bounds * backingScale`,
    // so frame resizes and Retina/non-Retina screen moves both land here.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateViewport()
    }

    // MARK: - Responder

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        spiceInputLog("becomeFirstResponder -> \(ok)")
        return ok
    }

    // Grab keyboard focus as soon as we're placed in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            // Backing scale is now known; refit so we don't draw at the wrong scale.
            updateViewport()
        }
    }

    override func resignFirstResponder() -> Bool {
        // Flush held keys/modifiers/buttons so nothing stays latched in the guest
        // when focus leaves (e.g. Cmd-Tab); also avoids the on-return modifier desync.
        router.releaseAll()
        showHostCursor()
        return super.resignFirstResponder()
    }

    // MARK: - Host cursor visibility (optional, gated on Preferences.hideHostCursor)

    /// Hide the macOS cursor only when the user opted in, the window is key, and the
    /// guest is in client (absolute) mouse mode (where the guest cursor overlay
    /// tracks the pointer). In server mode we keep the host cursor visible.
    private var shouldHideHostCursor: Bool {
        Preferences.hideHostCursor
            && window?.isKeyWindow == true
            && router.input != nil
            && router.input?.serverModeCursor == false
    }

    func updateHostCursorVisibility() {
        if shouldHideHostCursor { hideHostCursor() } else { showHostCursor() }
    }

    private func hideHostCursor() {
        guard !hostCursorHidden else { return }
        NSCursor.hide()
        hostCursorHidden = true
    }

    private func showHostCursor() {
        guard hostCursorHidden else { return }
        NSCursor.unhide()
        hostCursorHidden = false
    }

    override func mouseEntered(with event: NSEvent) { updateHostCursorVisibility() }
    override func mouseExited(with event: NSEvent) { showHostCursor() }

    override func keyDown(with event: NSEvent) {
        spiceInputLog("keyDown keyCode=\(event.keyCode) isFirstResponder=\(window?.firstResponder === self) hasInput=\(router.input != nil)")
        router.keyDown(event)
    }
    override func keyUp(with event: NSEvent) { router.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { router.flagsChanged(event) }

    override func mouseDown(with event: NSEvent) {
        // Clicking the guest should also take keyboard focus.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        spiceInputLog("mouseDown hasInput=\(router.input != nil)")
        router.mouseButton(event, pressed: true)
    }
    override func mouseUp(with event: NSEvent) { router.mouseButton(event, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { router.mouseButton(event, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { router.mouseButton(event, pressed: false) }
    override func otherMouseDown(with event: NSEvent) { router.mouseButton(event, pressed: true) }
    override func otherMouseUp(with event: NSEvent) { router.mouseButton(event, pressed: false) }

    override func mouseMoved(with event: NSEvent) {
        updateHostCursorVisibility()
        router.mouseMoved(event, in: self)
    }
    override func mouseDragged(with event: NSEvent) { router.mouseMoved(event, in: self) }
    override func rightMouseDragged(with event: NSEvent) { router.mouseMoved(event, in: self) }
    override func otherMouseDragged(with event: NSEvent) { router.mouseMoved(event, in: self) }
    override func scrollWheel(with event: NSEvent) { router.scrollWheel(event) }

    // Deliver mouseMoved while the window is key.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }
}
