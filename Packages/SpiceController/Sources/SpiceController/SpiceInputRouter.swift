import AppKit
import CocoaSpice
import SpiceInputMap

/// Translates AppKit `NSEvent`s into CocoaSpice `CSInput` calls. The hosting view
/// forwards its responder events here; this class owns the running button mask,
/// the set of held modifier keys, and the absolute-coordinate transform.
public final class SpiceInputRouter {

    /// The active inputs channel. Set when `spiceInputAvailable:` fires.
    public weak var input: CSInput?

    /// Supplies the current guest display size (pixels) for absolute pointer
    /// mapping. If nil, the view's own bounds size is used. Retained as a
    /// fallback for callers that don't supply a `viewportInfoProvider`.
    public var displaySizeProvider: (() -> CGSize)?

    /// Everything needed to inverse-map a view point to a guest pixel through the
    /// renderer's active aspect-fit transform. When set, this is preferred over
    /// `displaySizeProvider` and correctly accounts for the fit-scale, the
    /// centering/letterbox offset, and the Retina backing scale.
    public var viewportInfoProvider: (() -> ViewportInfo?)?

    /// Mirror of the view's viewport snapshot (kept here to avoid a dependency on
    /// the AppKit view type). All sizes are in DRAWABLE (physical) pixels except
    /// `guestSize`, which is in guest pixels.
    public struct ViewportInfo {
        public var guestSize: CGSize      // guest pixels (W, H)
        public var drawableSize: CGSize   // physical pixels (Dw, Dh)
        public var scale: CGFloat         // drawable pixels per guest pixel
        public var origin: CGPoint        // viewportOrigin, drawable pixels
        public var backingScale: CGFloat  // points -> drawable pixels
        public init(guestSize: CGSize, drawableSize: CGSize, scale: CGFloat,
                    origin: CGPoint, backingScale: CGFloat) {
            self.guestSize = guestSize
            self.drawableSize = drawableSize
            self.scale = scale
            self.origin = origin
            self.backingScale = backingScale
        }
    }

    /// Positions the guest cursor overlay. In client (absolute) mouse mode the
    /// guest does not send cursor-move events, so the client must drive the cursor
    /// overlay itself (via CSCursor.moveTo) or it stays pinned to the top-left.
    public var cursorMover: ((CGPoint) -> Void)?

    private var buttonMask: CSInputButton = []
    private var heldModifiers: Set<UInt16> = []

    public init(input: CSInput? = nil) {
        self.input = input
    }

    // MARK: - Keyboard

    public func keyDown(_ event: NSEvent) {
        // Recover any modifier that was released while we weren't getting events
        // (e.g. a ⌘-combo the system intercepted) before sending the key.
        reconcileModifiers(event.modifierFlags)
        // Auto-repeats are forwarded as additional presses, which the guest expects.
        sendKey(event.keyCode, pressed: true)
    }

    public func keyUp(_ event: NSEvent) {
        reconcileModifiers(event.modifierFlags)
        sendKey(event.keyCode, pressed: false)
    }

    /// macOS reports a modifier transition via `flagsChanged` but not its
    /// direction. Rather than blind-toggle a held-set (which permanently inverts
    /// after a single missed key-up — the classic stuck-⌘ bug), drive press/release
    /// from the authoritative `event.modifierFlags`, then reconcile every other
    /// held modifier so a stuck one self-corrects on the next event.
    public func flagsChanged(_ event: NSEvent) {
        let kc = event.keyCode
        if let flag = Self.modifierFlag(for: kc) {
            let isDown = event.modifierFlags.contains(flag)
            if isDown && !heldModifiers.contains(kc) {
                heldModifiers.insert(kc)
                sendKey(kc, pressed: true)
            } else if !isDown && heldModifiers.contains(kc) {
                heldModifiers.remove(kc)
                sendKey(kc, pressed: false)
            }
            // No transition for this key (isDown&&held or !isDown&&!held). NB: when
            // both L+R of a class are held and one is released, the shared class flag
            // stays set, so we cannot tell which side went up — that side stays
            // "pressed" on the guest until the other is also released (macOS doesn't
            // expose L/R direction here). Benign: same keysym, and it self-clears
            // once the class flag finally clears.
        } else {
            // Lock keys (Caps Lock) are edges, not holds: macOS reports a single
            // flagsChanged per physical tap, so send a full press+release as one
            // keystroke. Tracking it as "held" would send press-now / release-on-
            // next-tap and latch it down on the guest in between.
            sendKey(kc, pressed: true)
            sendKey(kc, pressed: false)
        }
        reconcileModifiers(event.modifierFlags)
    }

    /// Release any held modifier whose macOS flag is no longer set — recovers from
    /// a missed key-up so a modifier never stays "stuck down" on the guest.
    private func reconcileModifiers(_ flags: NSEvent.ModifierFlags) {
        let stuck = heldModifiers.filter { kc in
            guard let flag = Self.modifierFlag(for: kc) else { return false }
            return !flags.contains(flag)
        }
        for kc in stuck {
            heldModifiers.remove(kc)
            sendKey(kc, pressed: false)
        }
    }

    /// The device-independent modifier flag for a modifier key code, or nil for
    /// keys that aren't a pressable modifier (Caps Lock is a lock, not a hold).
    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case MacVirtualKey.command, MacVirtualKey.rightCommand:   return .command
        case MacVirtualKey.shift, MacVirtualKey.rightShift:       return .shift
        case MacVirtualKey.control, MacVirtualKey.rightControl:   return .control
        case MacVirtualKey.option, MacVirtualKey.rightOption:     return .option
        case MacVirtualKey.function:                              return .function
        default:                                                  return nil
        }
    }

    private func sendKey(_ keyCode: UInt16, pressed: Bool) {
        guard let input else {
            spiceInputLog("key dropped (no input channel) keyCode=\(keyCode)")
            return
        }
        guard let code = SpiceScancode.cocoaSpiceCode(forMacVirtualKey: keyCode) else {
            spiceInputLog("key dropped (unmapped) keyCode=\(keyCode)")
            return
        }
        spiceInputLog("send key 0x\(String(code, radix: 16)) pressed=\(pressed)")
        // Swift imports CSInput's -sendKey:code: as send(_:code:).
        input.send(pressed ? .press : .release, code: Int32(code))
    }

    /// Release everything we believe is held — keys, modifiers, and mouse buttons.
    /// Call on focus loss so a modifier/button held during Cmd-Tab or click-away
    /// does not stay latched in the guest (and does not desync on return).
    public func releaseAll() {
        if let input {
            // releaseKeys() flushes keyboard/modifier keys, but NOT mouse buttons,
            // so release any latched buttons explicitly first.
            for b in [CSInputButton.left, .right, .middle, .side, .extra] where buttonMask.contains(b) {
                buttonMask.remove(b)
                input.sendMouseButton(b, mask: buttonMask, pressed: false)
            }
            input.releaseKeys()
        }
        heldModifiers.removeAll()
        buttonMask = []
    }

    // MARK: - Mouse

    public func mouseButton(_ event: NSEvent, pressed: Bool) {
        guard let input else {
            spiceInputLog("mouse button dropped (no input channel)")
            return
        }
        let b = Self.button(for: event.buttonNumber)
        if pressed { buttonMask.insert(b) } else { buttonMask.remove(b) }
        spiceInputLog("mouse button \(event.buttonNumber) pressed=\(pressed)")
        input.sendMouseButton(b, mask: buttonMask, pressed: pressed)
    }

    public func mouseMoved(_ event: NSEvent, in view: NSView) {
        guard let input else { return }
        if input.serverModeCursor {
            input.sendMouseMotion(buttonMask,
                                  relativePoint: CGPoint(x: event.deltaX, y: event.deltaY))
        } else {
            let p = absolutePoint(event, in: view)
            spiceInputLog("mouse move abs=(\(Int(p.x)),\(Int(p.y))) server=\(input.serverModeCursor)")
            input.sendMousePosition(buttonMask, absolutePoint: p)
            // Client mode: drive the guest cursor overlay ourselves.
            cursorMover?(p)
        }
    }

    public func scrollWheel(_ event: NSEvent) {
        guard let input else { return }
        let dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            input.sendMouseScroll(.smooth, buttonMask: buttonMask, dy: dy)
        } else if dy < 0 {
            // Match the smooth path's sign convention (CSInput maps negative dy to
            // scroll-up, positive to scroll-down) so a wheel and a trackpad send the
            // same guest direction for the same physical gesture.
            input.sendMouseScroll(.up, buttonMask: buttonMask, dy: 0)
        } else if dy > 0 {
            input.sendMouseScroll(.down, buttonMask: buttonMask, dy: 0)
        }
    }

    /// Map the guest mouse mode the server prefers (server = relative).
    public func requestMouseMode(server: Bool) {
        input?.requestMouseMode(server)
    }

    // MARK: - Helpers

    /// Map a view-local event location to integer guest pixels, inverse-mapping
    /// through the renderer's active aspect-fit transform so the result lands
    /// under the macOS pointer (used for both sendMousePosition and cursor.move).
    private func absolutePoint(_ event: NSEvent, in view: NSView) -> CGPoint {
        // AppKit point: window coords, bottom-left origin, in POINTS.
        let local = view.convert(event.locationInWindow, from: nil)

        if let info = viewportInfoProvider?(), info.guestSize.width > 0,
           info.guestSize.height > 0, info.scale > 0 {
            let W = info.guestSize.width, H = info.guestSize.height
            let Dw = info.drawableSize.width, Dh = info.drawableSize.height
            // 1) Flip Y to a top-left origin (use bounds.height, since the point
            //    is view-local), then 2) points -> drawable pixels via backingScale.
            let dx = local.x * info.backingScale
            let dy = (view.bounds.height - local.y) * info.backingScale
            // 3) Inverse the fit transform: the quad is centered, so the guest
            //    pixel under drawable (dx,dy) is
            //    guest = W/2 + (D - Dcenter - origin) / scale.
            let gx = W / 2 + (dx - Dw / 2 - info.origin.x) / info.scale
            let gy = H / 2 + (dy - Dh / 2 - info.origin.y) / info.scale
            // Clamp into [0, W-1] x [0, H-1] (clicks in the black bars snap to the
            // nearest edge). spice_inputs_channel_position takes integer pixels.
            let px = min(W - 1, max(0, gx.rounded(.down)))
            let py = min(H - 1, max(0, gy.rounded(.down)))
            return CGPoint(x: px, y: py)
        }

        // Fallback: assume the framebuffer fills view.bounds (no letterboxing).
        let bounds = view.bounds
        let size = displaySizeProvider?() ?? bounds.size
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let nx = max(0, min(1, local.x / bounds.width))
        let ny = max(0, min(1, 1.0 - local.y / bounds.height))
        let px = min(size.width - 1, (nx * size.width).rounded(.down))
        let py = min(size.height - 1, (ny * size.height).rounded(.down))
        return CGPoint(x: max(0, px), y: max(0, py))
    }

    private static func button(for buttonNumber: Int) -> CSInputButton {
        switch buttonNumber {
        case 0: return .left
        case 1: return .right
        case 2: return .middle
        case 3: return .side
        default: return .extra
        }
    }
}
