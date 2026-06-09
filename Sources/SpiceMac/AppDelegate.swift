// SPDX-License-Identifier: MIT
import AppKit
import VVConfig
import SpiceController

/// App entry: builds the menu and opens Proxmox `.vv` SPICE files (via
/// double-click, File ▸ Open, or drag-and-drop), spawning a window per session.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var windowControllers: [SpiceWindowController] = []
    private var didOpenAny = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSApp.activate(ignoringOtherApps: true)

        // Allow opening a .vv passed on the command line (scripting / testing).
        for arg in CommandLine.arguments.dropFirst() where arg.hasSuffix(".vv") {
            openVV(at: URL(fileURLWithPath: arg))
        }

        // If launched without a document, prompt to open one.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didOpenAny else { return }
            self.presentOpenPanel()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Modern multi-URL open (double-click / drag onto the app / `open file.vv`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openVV(at: url) }
    }

    // MARK: - Opening

    @objc func openDocument(_ sender: Any?) {
        presentOpenPanel()
    }

    // MARK: - Preferences

    @objc func toggleHideMacCursor(_ sender: NSMenuItem) {
        Preferences.hideHostCursor.toggle()
        sender.state = Preferences.hideHostCursor ? .on : .off
    }

    @objc func toggleShareClipboard(_ sender: NSMenuItem) {
        Preferences.shareClipboard.toggle()
        sender.state = Preferences.shareClipboard ? .on : .off
    }

    @objc func toggleTrashConnectionFile(_ sender: NSMenuItem) {
        Preferences.trashConnectionFileAfterUse.toggle()
        sender.state = Preferences.trashConnectionFileAfterUse ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHideMacCursor(_:)):
            menuItem.state = Preferences.hideHostCursor ? .on : .off
        case #selector(toggleShareClipboard(_:)):
            menuItem.state = Preferences.shareClipboard ? .on : .off
        case #selector(toggleTrashConnectionFile(_:)):
            menuItem.state = Preferences.trashConnectionFileAfterUse ? .on : .off
        default:
            break
        }
        return true
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let types = VVDocument.contentTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = "Open"
        panel.message = "Open a Proxmox SPICE connection file (.vv)"
        if panel.runModal() == .OK, let url = panel.url {
            openVV(at: url)
        }
    }

    private func openVV(at url: URL) {
        didOpenAny = true
        do {
            let config = try VVConfig(contentsOf: url)
            let params = try SpiceConnectionParameters(from: config)
            let client = SpiceClient(parameters: params)
            client.shareClipboard = Preferences.shareClipboard
            let controller = SpiceWindowController(client: client, sourceURL: url)
            controller.onClose = { [weak self, weak controller] in
                self?.windowControllers.removeAll { $0 === controller }
            }
            windowControllers.append(controller)
            controller.showWindow(nil)
            client.connect()
            // The .vv has been read into `params`; its SPICE ticket is single-use and
            // it carries the cluster CA, so move it to the Trash once we've used it to
            // connect. The file content is already in memory, so this can't affect the
            // live connection. Only reached on a successful parse (failures go to catch).
            if Preferences.trashConnectionFileAfterUse {
                trashConnectionFile(at: url)
            }
        } catch {
            presentError(error, url: url)
        }
    }

    /// Move a used `.vv` to the Trash (best-effort). Trash, not a hard delete, so it's
    /// recoverable; failures (e.g. a read-only volume) are logged, never fatal.
    private func trashConnectionFile(at url: URL) {
        guard url.isFileURL else { return }
        // When launched as root (scripts/run-as-root.sh, for USB capture), recycle
        // would move the file into ROOT's Trash (/var/root/.Trash), not the user's —
        // surprising and unhelpful. The single-use ticket is already spent, so just
        // leave the file where the user put it; they can remove it themselves.
        if getuid() == 0 { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            if let error {
                NSLog("SpiceMac: could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)")
            }
        }
    }

    private func presentError(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open “\(url.lastPathComponent)”"
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
