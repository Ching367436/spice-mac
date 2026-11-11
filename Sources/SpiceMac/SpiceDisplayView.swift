// SPDX-License-Identifier: MIT
import AppKit
import MetalKit
import CocoaSpice
import CocoaSpiceRenderer
import SpiceController
import DisplayScale

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

    /// Called when the backing scale factor ACTUALLY changes. The view knows
    /// nothing about zoom; the window controller owns what guest resolution that
    /// should imply.
    var onBackingScaleChange: ((CGFloat) -> Void)?
    private var lastBackingScale: CGFloat = 0

    /// The sampler filter currently installed. `changeUpscaler:` rebuilds an
    /// `MTLSamplerState` and `updateViewport()` runs on every live-resize step, so
    /// only touch it on an actual transition.
    private var currentFilter: MTLSamplerMinMagFilter?

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
        currentFilter = nil   // the next renderer starts with CocoaSpice's linear default
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
    var backingScale: CGFloat {
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

    /// The view's size in PHYSICAL pixels — what the guest has to be fitted into.
    ///
    /// Deliberately NOT `MTKView.drawableSize`, which refreshes lazily: on a real
    /// 2.0↔1.0 drag the callback reports the new backing scale while `drawableSize`
    /// still says 1800×1200 for a view that is now 900×600. `convertToBacking`
    /// follows the backing store, and it matters because such a move does NOT change
    /// the point size, so no `setFrameSize` follows to recompute the fit.
    private var physicalSize: CGSize {
        let size = convertToBacking(bounds).size
        return size.width > 1 && size.height > 1 ? size : drawableSize
    }

    func viewportInfo() -> ViewportInfo? {
        guard let guest = attachedDisplay?.displaySize,
              guest.width > 0, guest.height > 0 else { return nil }
        let drawable = physicalSize
        // Single source of truth: the renderer and the input router MUST see the
        // same number, snap included, or the guest cursor drifts from the macOS
        // pointer.
        let scale = DisplayScale.renderScale(guest: guest, drawable: drawable)
        // Nudges the centred quad onto whole drawable pixels. The input router
        // subtracts the same origin, so both stay on the identical transform.
        return ViewportInfo(guestSize: guest,
                            drawableSize: drawable,
                            scale: scale,
                            origin: DisplayScale.pixelAlignedOrigin(guest: guest,
                                                                    drawable: drawable,
                                                                    scale: scale),
                            backingScale: backingScale)
    }

    /// Push the aspect-fit scale and origin to the renderer, and pick the sampler.
    ///
    /// The renderer centres the quad, but `align` floors the guest onto the 8/2
    /// grid, so the leftover slack is often ODD and the centre lands on a half
    /// pixel; `pixelAlignedOrigin` gives one letterbox bar the odd pixel instead.
    /// At a whole-number magnification — which zoom aims for, 1:1 included —
    /// nearest-neighbour keeps guest text crisp; fractional scales and downscales
    /// stay linear.
    private func updateViewport() {
        guard let renderer, let info = viewportInfo() else { return }
        renderer.viewportScale = info.scale
        renderer.viewportOrigin = info.origin

        let filter: MTLSamplerMinMagFilter =
            DisplayScale.usesNearestFilter(scale: info.scale) ? .nearest : .linear
        if filter != currentFilter {
            currentFilter = filter
            // upscaler = magFilter, downscaler = minFilter; downscaling stays
            // linear. NB: -changeUpscaler:downscaler: does not set
            // renderNeedsUpdate, which is fine because the filter only changes when
            // the scale does, and -setViewportScale: above already did.
            renderer.changeUpscaler(filter, downscaler: .linear)
        }
    }

    // Recompute on any geometry change. `drawableSize` tracks `bounds * backingScale`,
    // so frame resizes and Retina/non-Retina screen moves both land here.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Pull MTKView's drawable up rather than waiting for its lazy refresh: it
        // is what the renderer draws into, so while it lags the guest is presented
        // at the old screen's scale. A no-op when it already agrees.
        let physical = physicalSize
        if physical.width > 1, physical.height > 1, physical != drawableSize {
            drawableSize = physical
        }
        updateViewport()
        // Report a real backing-scale transition upward. AppKit also fires this for
        // a colour-space change and on first insertion, so filter on the value.
        let scale = backingScale
        if scale > 0, abs(scale - lastBackingScale) > 0.001 {
            lastBackingScale = scale
            onBackingScaleChange?(scale)
        }
    }

    // MARK: - Responder

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
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

    override func keyDown(with event: NSEvent) { router.keyDown(event) }
    override func keyUp(with event: NSEvent) { router.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { router.flagsChanged(event) }

    override func mouseDown(with event: NSEvent) {
        // Clicking the guest should also take keyboard focus.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        router.mouseButton(event, pressed: true)
    }
    override func mouseUp(with event: NSEvent) { router.mouseButton(event, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { router.mouseButton(event, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { router.mouseButton(event, pressed: false) }
    override func otherMouseDown(with event: NSEvent) { router.mouseButton(event, pressed: true) }
    override func otherMouseUp(with event: NSEvent) { router.mouseButton(event, pressed: false) }

    override func mouseMoved(with event: NSEvent) {
        // The window accepts mouse-moved events, so these also arrive while the
        // pointer is outside the view. Only hide the Mac cursor over the guest:
        // outside, the router ignores the motion, so nothing else would show
        // where the pointer is.
        if isMousePoint(convert(event.locationInWindow, from: nil), in: bounds) {
            updateHostCursorVisibility()
        } else {
            showHostCursor()
        }
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
