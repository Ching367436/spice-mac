import AppKit
import Combine
import CocoaSpice
import SpiceController

/// Owns one SPICE session window: hosts the `SpiceDisplayView`, reflects
/// connection state, resizes to the guest, and exposes the Connection/USB menu
/// actions via the responder chain.
final class SpiceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private let client: SpiceClient
    private let sourceURL: URL
    private let displayView = SpiceDisplayView()
    private let containerView = NSView()
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private var cancellables = Set<AnyCancellable>()

    /// Called when the window closes so the app can drop its reference.
    var onClose: (() -> Void)?

    init(client: SpiceClient, sourceURL: URL) {
        self.client = client
        self.sourceURL = sourceURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.title = baseTitle
        window.center()
        setupViews()
        wireClient()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var baseTitle: String {
        client.title ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Views

    private func setupViews() {
        guard let window else { return }
        containerView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        displayView.autoresizingMask = [.width, .height]
        displayView.frame = containerView.bounds
        containerView.addSubview(displayView)

        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, multiplier: 0.8),
        ])

        window.contentView = containerView
        window.initialFirstResponder = displayView
    }

    // MARK: - Client wiring

    private func wireClient() {
        client.onDisplayCreated = { [weak self] display in self?.attachDisplay(display) }
        // NB: do NOT resize the window when the guest resolution changes. The view
        // re-fits the viewport via its displaySize KVO, so the window stays the
        // user's size. Resizing here would chase the guest size and, combined with
        // requestResolution, oscillate (the guest reconfigures → window resizes →
        // we request a new resolution → …).
        client.onDisplayDestroyed = { [weak self] _ in self?.displayView.detach() }
        client.onInputAvailable = { [weak self] input in
            guard let self else { return }
            self.displayView.router.input = input
            self.displayView.router.requestMouseMode(server: false)
            self.window?.makeFirstResponder(self.displayView)
            spiceInputLog("onInputAvailable wired; firstResponder set on displayView")
        }
        client.onInputUnavailable = { [weak self] _ in self?.displayView.router.input = nil }

        client.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update(for: $0) }
            .store(in: &cancellables)

        client.$agentConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in if connected { self?.requestResolutionForCurrentSize() } }
            .store(in: &cancellables)
    }

    private func attachDisplay(_ display: CSDisplay) {
        displayView.attachDisplay(display)
        resizeToDisplay(display.displaySize)
        statusLabel.isHidden = true
        window?.makeFirstResponder(displayView)
        if client.prefersFullscreen, window?.styleMask.contains(.fullScreen) == false {
            window?.toggleFullScreen(nil)
        }
    }

    private func update(for status: SpiceClient.Status) {
        switch status {
        case .idle:
            statusLabel.stringValue = ""
        case .connecting:
            showStatus("Connecting…")
        case .connected:
            statusLabel.isHidden = true
            client.usbManager?.delegate = self
            refreshUSBMenu()
        case .disconnected:
            // The SPICE ticket is single-use, so reconnecting needs a fresh file.
            showStatus("Disconnected.\nOpen a fresh .vv file to reconnect.")
        case .failed(let message):
            showStatus("Connection failed.\n\(message)")
        }
        window?.title = title(for: status)
    }

    private func title(for status: SpiceClient.Status) -> String {
        switch status {
        case .connecting:   return "\(baseTitle) — Connecting…"
        case .disconnected: return "\(baseTitle) — Disconnected"
        case .failed:       return "\(baseTitle) — Failed"
        case .connected, .idle: return baseTitle
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    // MARK: - Sizing

    private func resizeToDisplay(_ size: CGSize) {
        guard size.width > 1, size.height > 1, let window,
              window.styleMask.contains(.fullScreen) == false else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? size
        let scale = min(1, min(visible.width / size.width, visible.height / size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        window.setContentSize(target)
        window.center()
    }

    private func requestResolutionForCurrentSize() {
        guard client.supportsDynamicResolution, let display = displayView.attachedDisplay else { return }
        // requestResolution expects guest pixels; convert points→backing pixels so
        // Retina displays request full resolution rather than half.
        display.requestResolution(displayView.convertToBacking(displayView.bounds))
    }

    // Request a matching guest resolution only at DISCRETE moments — never on the
    // continuous windowDidResize, which (during a live drag, or when a programmatic
    // resize fires it) creates the resize↔request oscillation.
    func windowDidEndLiveResize(_ notification: Notification) {
        requestResolutionForCurrentSize()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        requestResolutionForCurrentSize()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        requestResolutionForCurrentSize()
    }

    // MARK: - Window lifecycle

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(displayView)
        client.usbManager?.delegate = self
        refreshUSBMenu()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Release any held input so it does not stay latched in the guest when the
        // user switches away, and restore the macOS cursor — the window is no longer
        // key, so updateHostCursorVisibility() shows it (covers same-app window
        // switches / miniaturize that don't deactivate the app).
        displayView.router.releaseAll()
        displayView.updateHostCursorVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        displayView.router.releaseAll()
        client.disconnect()
        displayView.detach()
        onClose?()
    }

    // MARK: - Connection actions (responder chain targets)

    @objc func sendCtrlAltDel(_ sender: Any?) {
        guard let input = displayView.router.input else { return }
        // Left Ctrl (0x1D) + Left Alt (0x38) + Delete (extended 0xE053 → 0x153).
        let combo: [Int32] = [0x1D, 0x38, 0x153]
        for code in combo { input.send(.press, code: code) }
        for code in combo.reversed() { input.send(.release, code: code) }
    }

    @objc func releaseCursor(_ sender: Any?) {
        displayView.router.releaseAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(sendCtrlAltDel(_:)), #selector(releaseCursor(_:)):
            return displayView.router.input != nil
        default:
            return true
        }
    }

    // MARK: - USB menu

    @objc func toggleUSBDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? CSUSBDevice,
              let usb = client.usbManager else { return }
        if usb.isUsbDeviceConnected(device) {
            usb.disconnectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        } else {
            var message: NSString?
            guard usb.canRedirectUsbDevice(device, errorMessage: &message) else {
                presentTransientError((message as String?) ?? "This USB device cannot be redirected.")
                return
            }
            usb.connectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        }
    }

    private func handleUSBResult(_ error: Error?) {
        DispatchQueue.main.async {
            if let error { self.presentTransientError(error.localizedDescription) }
            self.refreshUSBMenu()
        }
    }

    private func refreshUSBMenu() {
        // The USB submenu is shared app-wide; only the key window owns it, so
        // background windows' USB delegate callbacks don't retarget its items.
        guard window?.isKeyWindow == true, let menu = MainMenu.usbSubmenu else { return }
        menu.removeAllItems()
        guard let usb = client.usbManager else {
            menu.addItem(disabledItem("Not connected"))
            return
        }
        let devices = usb.usbDevices
        if devices.isEmpty {
            menu.addItem(disabledItem("No USB devices"))
            return
        }
        for device in devices {
            let item = NSMenuItem(title: label(for: device),
                                  action: #selector(toggleUSBDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = usb.isUsbDeviceConnected(device) ? .on : .off
            menu.addItem(item)
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func label(for device: CSUSBDevice) -> String {
        let name = device.name ?? device.usbProductName ?? "USB Device"
        return String(format: "%@ (%04lx:%04lx)", name, device.usbVendorId, device.usbProductId)
    }

    private func presentTransientError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "USB Redirection"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - CSUSBManagerDelegate

extension SpiceWindowController: CSUSBManagerDelegate {
    func spiceUsbManager(_ usbManager: CSUSBManager, deviceAttached device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceRemoved device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceError error: String, for device: CSUSBDevice) {
        DispatchQueue.main.async { self.presentTransientError(error) }
    }
}
