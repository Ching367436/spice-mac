import AppKit

/// Builds the application main menu programmatically (no nib). Connection-specific
/// actions (release cursor, send Ctrl-Alt-Del, USB) use `nil` targets so they
/// travel the responder chain to the front `SpiceWindowController`.
enum MainMenu {
    static func build() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit menu (standard responder-chain selectors so clipboard works)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Connection menu (routed to SpiceWindowController via responder chain)
        let connItem = NSMenuItem()
        mainMenu.addItem(connItem)
        let connMenu = NSMenu(title: "Connection")
        connItem.submenu = connMenu
        connMenu.addItem(withTitle: "Send Ctrl-Alt-Del",
                         action: #selector(SpiceWindowController.sendCtrlAltDel(_:)), keyEquivalent: "")
        let release = NSMenuItem(title: "Release Cursor",
                                 action: #selector(SpiceWindowController.releaseCursor(_:)), keyEquivalent: "r")
        release.keyEquivalentModifierMask = [.control, .option]
        connMenu.addItem(release)
        connMenu.addItem(.separator())
        // USB submenu, populated dynamically by the window controller.
        let usbItem = NSMenuItem(title: "USB Devices", action: nil, keyEquivalent: "")
        let usbMenu = NSMenu(title: "USB Devices")
        usbItem.submenu = usbMenu
        usbSubmenu = usbMenu
        connMenu.addItem(usbItem)

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(.separator())
        let hideCursor = NSMenuItem(title: "Hide Mac Cursor",
                                    action: #selector(AppDelegate.toggleHideMacCursor(_:)), keyEquivalent: "")
        hideCursor.state = Preferences.hideHostCursor ? .on : .off
        viewMenu.addItem(hideCursor)

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    /// The USB submenu, populated dynamically by the front `SpiceWindowController`.
    static weak var usbSubmenu: NSMenu?
}
