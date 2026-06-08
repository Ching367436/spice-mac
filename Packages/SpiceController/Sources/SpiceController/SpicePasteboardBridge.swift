import AppKit
import CocoaSpice

/// Bridges the SPICE shared clipboard to the macOS general `NSPasteboard`.
///
/// CocoaSpice calls into this delegate to read the host clipboard (host→guest
/// copy) and to write guest clipboard contents (guest→host copy). Selectors are
/// matched explicitly with `@objc(...)` so conformance to the `@objc`
/// `CSPasteboardDelegate` protocol is unambiguous.
///
/// Note: clipboard sharing only takes effect when the guest is running the SPICE
/// vdagent.
public final class SpicePasteboardBridge: NSObject, CSPasteboardDelegate {

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init()
    }

    @objc(canReadItemForType:)
    public func canReadItem(for type: CSPasteboardType) -> Bool {
        guard let nsType = Self.nsType(type) else { return false }
        return pasteboard.availableType(from: [nsType]) != nil
    }

    @objc(dataForType:)
    public func data(for type: CSPasteboardType) -> Data? {
        guard let nsType = Self.nsType(type) else { return nil }
        return pasteboard.data(forType: nsType)
    }

    @objc(setData:forType:)
    public func setData(_ data: Data, for type: CSPasteboardType) {
        guard let nsType = Self.nsType(type) else { return }
        // Assumes -clearContents was already sent for this guest→host update
        // (CocoaSpice clears before pushing new contents).
        pasteboard.setData(data, forType: nsType)
    }

    @objc(string)
    public func string() -> String? {
        pasteboard.string(forType: .string)
    }

    @objc(setString:)
    public func setString(_ string: String) {
        pasteboard.setString(string, forType: .string)
    }

    @objc(clearContents)
    public func clearContents() {
        pasteboard.clearContents()
    }

    /// Map a SPICE pasteboard type to the closest `NSPasteboard` UTI type.
    static func nsType(_ type: CSPasteboardType) -> NSPasteboard.PasteboardType? {
        switch type {
        case .string:       return .string
        case .html:         return .html
        case .rtf:          return .rtf
        case .rtfd:         return .rtfd
        case .pdf:          return .pdf
        case .png:          return .png
        case .tiff:         return .tiff
        case .fileURL:      return .fileURL
        case .URL:          return .URL
        case .tabularText:  return .tabularText
        case .font:         return .font
        case .sound:        return .sound
        case .jpg:          return NSPasteboard.PasteboardType("public.jpeg")
        case .bmp:          return NSPasteboard.PasteboardType("com.microsoft.bmp")
        @unknown default:   return nil
        }
    }
}
