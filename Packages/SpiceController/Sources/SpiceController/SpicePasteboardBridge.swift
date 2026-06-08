import AppKit
import CocoaSpice

/// Bridges the SPICE shared clipboard to the macOS general `NSPasteboard`.
///
/// Two directions:
///  - **guest → host**: CocoaSpice calls this delegate's `setString:`/`setData:forType:`
///    when the guest copies. Driven by SPICE; works out of the box.
///  - **host → guest**: CocoaSpice only offers the host clipboard to the guest when
///    it receives `kCSPasteboardChangedNotification`. macOS `NSPasteboard` has no
///    native change notification, so we poll `changeCount` and post it ourselves
///    (tracking our own writes to avoid a guest→host→guest feedback loop).
///
/// Note: clipboard sharing only takes effect when the guest runs the SPICE vdagent.
public final class SpicePasteboardBridge: NSObject, CSPasteboardDelegate {

    private let pasteboard: NSPasteboard
    private var monitorTimer: Timer?
    private var lastChangeCount: Int
    /// changeCount produced by our own (guest→host) writes, so the poller ignores them.
    private var selfWriteChangeCount: Int = -1

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
        super.init()
    }

    // MARK: - Host clipboard monitoring (host → guest)

    /// Begin polling the host pasteboard. Call once the session is connected.
    public func startMonitoring() {
        stopMonitoring()
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    public func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func pollPasteboard() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        // Ignore changes we caused by writing guest data to the host pasteboard.
        if current == selfWriteChangeCount { return }
        NotificationCenter.default.post(name: .csPasteboardChanged, object: nil)
    }

    /// Record that the pasteboard's current state is one we just wrote (guest→host).
    private func markSelfWrite() {
        selfWriteChangeCount = pasteboard.changeCount
        lastChangeCount = selfWriteChangeCount
    }

    // MARK: - CSPasteboardDelegate

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
        markSelfWrite()
    }

    @objc(string)
    public func string() -> String? {
        pasteboard.string(forType: .string)
    }

    @objc(setString:)
    public func setString(_ string: String) {
        pasteboard.setString(string, forType: .string)
        markSelfWrite()
    }

    @objc(clearContents)
    public func clearContents() {
        pasteboard.clearContents()
        markSelfWrite()
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
