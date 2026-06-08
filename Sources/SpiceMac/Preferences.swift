import Foundation

/// App preferences, backed by `UserDefaults`.
enum Preferences {
    private static let hideHostCursorKey = "HideHostCursor"

    /// When true, the macOS cursor is hidden over the display so only the guest
    /// cursor shows. Default off. Changing it posts `.hideHostCursorChanged`.
    static var hideHostCursor: Bool {
        get { UserDefaults.standard.bool(forKey: hideHostCursorKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: hideHostCursorKey)
            NotificationCenter.default.post(name: .hideHostCursorChanged, object: nil)
        }
    }

    private static let shareClipboardKey = "ShareClipboard"

    /// Whether to share the clipboard with the guest (both directions). Default
    /// ON (matches virt-viewer and the working behavior). Disable it when
    /// connecting to an untrusted VM — while on, anything you copy on the Mac is
    /// sent to the guest. Takes effect on the next connection.
    static var shareClipboard: Bool {
        get { (UserDefaults.standard.object(forKey: shareClipboardKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shareClipboardKey) }
    }
}

extension Notification.Name {
    static let hideHostCursorChanged = Notification.Name("SpiceMac.hideHostCursorChanged")
}
