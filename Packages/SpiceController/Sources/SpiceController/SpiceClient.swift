import Foundation
import VVConfig
import CocoaSpice
import CocoaSpiceRenderer

/// Drives a single SPICE session on top of (the forked) CocoaSpice: starts the
/// GLib worker, builds and configures the `CSConnection` (including the Proxmox
/// TLS-via-proxy knobs), implements `CSConnectionDelegate`, and surfaces state to
/// the UI. Delegate callbacks arrive on the GLib worker thread, so all observable
/// state is mutated on the main queue.
public final class SpiceClient: NSObject, ObservableObject {

    public enum Status: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    /// High-level connection state, for the UI.
    @Published public private(set) var status: Status = .idle
    /// Whether the guest SPICE agent (vdagent) is connected — required for
    /// clipboard sharing and dynamic resolution.
    @Published public private(set) var agentConnected = false
    /// Whether the connected agent advertises dynamic monitor configuration.
    @Published public private(set) var supportsDynamicResolution = false

    // The UI sets these to receive channel lifecycle on the main thread.
    public var onDisplayCreated: ((CSDisplay) -> Void)?
    public var onDisplayUpdated: ((CSDisplay) -> Void)?
    public var onDisplayDestroyed: ((CSDisplay) -> Void)?
    public var onInputAvailable: ((CSInput) -> Void)?
    public var onInputUnavailable: ((CSInput) -> Void)?

    public private(set) var connection: CSConnection?
    /// The most recently announced inputs channel (keyboard/mouse).
    public private(set) var primaryInput: CSInput?

    /// USB redirection manager for the active connection, if any.
    public var usbManager: CSUSBManager? { connection?.usbManager }

    private let parameters: SpiceConnectionParameters
    private let pasteboard: SpicePasteboardBridge
    /// Whether a connection attempt has already been made. The Proxmox ticket is
    /// single-use, so we never silently reconnect with the same parameters — the
    /// user must open a fresh `.vv`.
    private var didAttemptConnect = false

    public init(parameters: SpiceConnectionParameters,
                pasteboard: SpicePasteboardBridge = SpicePasteboardBridge()) {
        self.parameters = parameters
        self.pasteboard = pasteboard
        super.init()
    }

    /// The window title hint from the `.vv` file, if any.
    public var title: String? { parameters.title }
    /// Whether the `.vv` requested fullscreen.
    public var prefersFullscreen: Bool { parameters.fullscreen }

    // MARK: - Lifecycle

    /// Build the connection and start connecting. Safe to call once; subsequent
    /// calls are ignored (the SPICE ticket is single-use). Always runs on the main
    /// queue so observable state is mutated there.
    public func connect() {
        onMain { self.performConnect() }
    }

    private func performConnect() {
        guard connection == nil, !didAttemptConnect else { return }
        didAttemptConnect = true

        let main = CSMain.shared
        if !main.running {
            guard main.spiceStart() else {
                status = .failed("Could not start the SPICE worker thread.")
                return
            }
        }

        status = .connecting

        let conn: CSConnection
        if parameters.isTLS {
            // TLS path. For Proxmox we verify by certificate subject + CA rather
            // than a pinned public key, so pass an empty key and override
            // verification below via the fork's setProxy:ca:certSubject:.
            conn = CSConnection(host: parameters.host,
                                tlsPort: String(parameters.tlsPort ?? 0),
                                serverPublicKey: Data())
        } else {
            conn = CSConnection(host: parameters.host,
                                port: String(parameters.port ?? 0))
        }

        conn.delegate = self
        conn.password = parameters.password
        conn.audioEnabled = true

        if parameters.requiresProxyExtension {
            conn.setProxy(parameters.proxy,
                          ca: parameters.caPEM,
                          certSubject: parameters.certSubject)
        }

        // Clipboard sharing (requires the guest vdagent to actually take effect).
        conn.session.shareClipboard = true
        conn.session.pasteboardDelegate = pasteboard

        connection = conn

        if !conn.connect() {
            status = .failed("Failed to initiate the SPICE connection.")
            connection = nil
            return
        }

        // Poll the host pasteboard so host→guest copy works (macOS has no native
        // pasteboard-change notification).
        pasteboard.startMonitoring()
    }

    /// Request disconnect. Final teardown is reported via `spiceDisconnected:`.
    public func disconnect() {
        onMain { self.connection?.disconnect() }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - CSConnectionDelegate

extension SpiceClient: CSConnectionDelegate {

    public func spiceConnected(_ connection: CSConnection) {
        onMain { self.status = .connected }
    }

    public func spiceDisconnected(_ connection: CSConnection) {
        onMain {
            self.pasteboard.stopMonitoring()
            self.status = .disconnected
            self.agentConnected = false
            self.supportsDynamicResolution = false
            self.primaryInput = nil
            self.connection = nil
        }
    }

    public func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        onMain {
            self.status = .failed(message ?? "SPICE connection error (code \(code.rawValue)).")
        }
    }

    public func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        onMain {
            spiceInputLog("spiceInputAvailable: inputs channel ready")
            self.primaryInput = input
            self.onInputAvailable?(input)
        }
    }

    public func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        onMain {
            spiceInputLog("spiceInputUnavailable: inputs channel TORN DOWN")
            if self.primaryInput === input { self.primaryInput = nil }
            self.onInputUnavailable?(input)
        }
    }

    public func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        onMain { self.onDisplayCreated?(display) }
    }

    public func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        onMain { self.onDisplayUpdated?(display) }
    }

    public func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        onMain { self.onDisplayDestroyed?(display) }
    }

    public func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        onMain {
            spiceInputLog("spiceAgentConnected (monitorsConfig=\(features.contains(.monitorsConfig)))")
            self.agentConnected = true
            self.supportsDynamicResolution = features.contains(.monitorsConfig)
        }
    }

    public func spiceAgentDisconnected(_ connection: CSConnection) {
        onMain {
            self.agentConnected = false
            self.supportsDynamicResolution = false
        }
    }

    public func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    public func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}
