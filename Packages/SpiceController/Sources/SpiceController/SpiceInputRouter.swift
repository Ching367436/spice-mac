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
    /// mapping. If nil, the view's own bounds size is used.
    public var displaySizeProvider: (() -> CGSize)?

    private var buttonMask: CSInputButton = []
    private var heldModifiers: Set<UInt16> = []

    public init(input: CSInput? = nil) {
        self.input = input
    }

    // MARK: - Keyboard

    public func keyDown(_ event: NSEvent) {
        // Auto-repeats are forwarded as additional presses, which the guest expects.
        sendKey(event.keyCode, pressed: true)
    }

    public func keyUp(_ event: NSEvent) {
        sendKey(event.keyCode, pressed: false)
    }

    /// macOS reports modifier presses/releases as `flagsChanged` without telling
    /// us the direction, so we toggle on a held-set keyed by the modifier's
    /// virtual key code (which distinguishes left/right modifiers).
    public func flagsChanged(_ event: NSEvent) {
        let kc = event.keyCode
        if heldModifiers.contains(kc) {
            heldModifiers.remove(kc)
            sendKey(kc, pressed: false)
        } else {
            heldModifiers.insert(kc)
            sendKey(kc, pressed: true)
        }
    }

    private func sendKey(_ keyCode: UInt16, pressed: Bool) {
        guard let input,
              let code = SpiceScancode.cocoaSpiceCode(forMacVirtualKey: keyCode) else { return }
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
        guard let input else { return }
        let b = Self.button(for: event.buttonNumber)
        if pressed { buttonMask.insert(b) } else { buttonMask.remove(b) }
        input.sendMouseButton(b, mask: buttonMask, pressed: pressed)
    }

    public func mouseMoved(_ event: NSEvent, in view: NSView) {
        guard let input else { return }
        if input.serverModeCursor {
            input.sendMouseMotion(buttonMask,
                                  relativePoint: CGPoint(x: event.deltaX, y: event.deltaY))
        } else {
            input.sendMousePosition(buttonMask, absolutePoint: absolutePoint(event, in: view))
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

    /// Map a view-local event location to integer guest pixels. Assumes the
    /// rendered framebuffer fills `view.bounds` (no aspect-fit letterboxing).
    private func absolutePoint(_ event: NSEvent, in view: NSView) -> CGPoint {
        let local = view.convert(event.locationInWindow, from: nil)
        let bounds = view.bounds
        let size = displaySizeProvider?() ?? bounds.size
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return .zero }
        // AppKit's origin is bottom-left; the SPICE guest framebuffer is top-left.
        let nx = max(0, min(1, local.x / bounds.width))
        let ny = max(0, min(1, 1.0 - local.y / bounds.height))
        // spice_inputs_channel_position takes integer pixels; floor and clamp to
        // the last valid column/row so the far edge does not overshoot by one.
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
