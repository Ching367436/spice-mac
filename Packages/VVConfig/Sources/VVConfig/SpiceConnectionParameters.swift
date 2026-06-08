import Foundation

/// The connection knobs a SPICE client needs, derived from a `VVConfig`.
///
/// This is the bridge between the parsed `.vv` file and the (forked) CocoaSpice
/// `CSConnection`. For Proxmox, `host` is the opaque `pvespiceproxy` token and the
/// real endpoint is `proxy`; the server certificate is validated against
/// `certSubject` (from `host-subject`) using the supplied `caPEM`, because the
/// proxy/token never matches a normal hostname.
public struct SpiceConnectionParameters: Equatable, Sendable {
    /// Hostname, or — for Proxmox — the opaque `pvespiceproxy:...` token.
    public var host: String
    /// Plaintext SPICE port, if any.
    public var port: Int?
    /// TLS SPICE port, if any.
    public var tlsPort: Int?
    /// Connection ticket / password.
    public var password: String?
    /// Proxy endpoint (`http://node:3128`) for Proxmox; nil for direct connections.
    public var proxy: String?
    /// CA certificate (expanded PEM) to trust for the TLS handshake.
    public var caPEM: String?
    /// X.509 subject the server certificate must match.
    public var certSubject: String?
    /// When true, verify the peer by `certSubject` (SPICE "verify subject" mode)
    /// rather than by hostname/public-key. Required for Proxmox.
    public var verifySubject: Bool
    /// Window title hint.
    public var title: String?
    /// Open fullscreen.
    public var fullscreen: Bool

    public init(
        host: String,
        port: Int? = nil,
        tlsPort: Int? = nil,
        password: String? = nil,
        proxy: String? = nil,
        caPEM: String? = nil,
        certSubject: String? = nil,
        verifySubject: Bool = false,
        title: String? = nil,
        fullscreen: Bool = false
    ) {
        self.host = host
        self.port = port
        self.tlsPort = tlsPort
        self.password = password
        self.proxy = proxy
        self.caPEM = caPEM
        self.certSubject = certSubject
        self.verifySubject = verifySubject
        self.title = title
        self.fullscreen = fullscreen
    }

    /// True when this requires the forked CocoaSpice proxy/CA/subject extension.
    public var requiresProxyExtension: Bool {
        (proxy?.isEmpty == false) || verifySubject || (caPEM?.isEmpty == false)
    }

    /// True when TLS must be used (a TLS port is present and no plaintext fallback
    /// is intended). Proxmox is always TLS.
    public var isTLS: Bool { tlsPort != nil }
}

extension SpiceConnectionParameters {
    /// Derive connection parameters from a parsed, validated `.vv` config.
    /// Calls `VVConfig.validate()` first and rethrows any `VVConfigError`.
    public init(from cfg: VVConfig) throws {
        try cfg.validate()
        // validate() guarantees host is present and non-empty.
        let host = cfg.host ?? ""
        let subject = cfg.hostSubject
        self.init(
            host: host,
            port: cfg.port,
            tlsPort: cfg.tlsPort,
            password: cfg.password,
            proxy: cfg.proxy,
            caPEM: cfg.caCertificate,
            certSubject: subject,
            // Proxmox supplies a host-subject and a proxy; verify by subject.
            verifySubject: (subject?.isEmpty == false),
            title: cfg.title,
            fullscreen: cfg.fullscreen ?? false
        )
    }
}
