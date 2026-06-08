import Foundation

/// A parsed virt-viewer connection file (`.vv`), as emitted by Proxmox VE's
/// `spiceproxy` endpoint (and by other SPICE servers via `remote-viewer`).
///
/// The file is INI-shaped with a single `[virt-viewer]` group. Proxmox fills it
/// with a short-lived, single-use SPICE ticket and routes the real connection
/// through the node's `spiceproxy` on port 3128, so the `host` value is an
/// **opaque token** (`pvespiceproxy:...`) — never a TCP hostname — and the
/// reachable endpoint lives in `proxy`.
///
/// Reference: virt-viewer `.vv` format and Proxmox `spice-example-sh`.
public struct VVConfig: Equatable, Sendable {
    /// Connection type. For SPICE this is `"spice"`.
    public var type: String?
    /// For Proxmox this is an opaque `pvespiceproxy:...` token, **not** a hostname.
    public var host: String?
    /// Plaintext SPICE port. Usually absent for Proxmox (TLS-only).
    public var port: Int?
    /// TLS SPICE port (e.g. `61000`). Proxmox uses TLS exclusively.
    public var tlsPort: Int?
    /// Short-lived (~30s), single-use SPICE ticket used as the connection password.
    public var password: String?
    /// X.509 subject the server certificate must match, e.g.
    /// `OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=node.example.com`.
    public var hostSubject: String?
    /// CA certificate in PEM. In the raw file newlines are escaped as the literal
    /// two-character sequence `\n`; this property holds the **expanded** PEM.
    public var caCertificate: String?
    /// Proxy endpoint that is actually reachable, e.g. `http://node.example.com:3128`.
    public var proxy: String?
    /// Window title hint.
    public var title: String?
    /// Whether the client should open fullscreen.
    public var fullscreen: Bool?
    /// Hotkey hint for toggling fullscreen (virt-viewer syntax, e.g. `shift+f11`).
    public var toggleFullscreen: String?
    /// Hotkey hint for releasing the cursor grab (e.g. `shift+f12`).
    public var releaseCursor: String?
    /// Hotkey hint for sending secure-attention / SAS (e.g. `ctrl+alt+end`).
    public var secureAttention: String?
    /// Whether the file should be deleted after use. We keep everything in memory,
    /// so this is informational only.
    public var deleteThisFile: Bool?

    /// Every key/value parsed from the `[virt-viewer]` group, keys lowercased.
    /// Preserved so callers can read fields this model does not surface explicitly.
    public var raw: [String: String]

    public init(
        type: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        tlsPort: Int? = nil,
        password: String? = nil,
        hostSubject: String? = nil,
        caCertificate: String? = nil,
        proxy: String? = nil,
        title: String? = nil,
        fullscreen: Bool? = nil,
        toggleFullscreen: String? = nil,
        releaseCursor: String? = nil,
        secureAttention: String? = nil,
        deleteThisFile: Bool? = nil,
        raw: [String: String] = [:]
    ) {
        self.type = type
        self.host = host
        self.port = port
        self.tlsPort = tlsPort
        self.password = password
        self.hostSubject = hostSubject
        self.caCertificate = caCertificate
        self.proxy = proxy
        self.title = title
        self.fullscreen = fullscreen
        self.toggleFullscreen = toggleFullscreen
        self.releaseCursor = releaseCursor
        self.secureAttention = secureAttention
        self.deleteThisFile = deleteThisFile
        self.raw = raw
    }
}

public enum VVConfigError: Error, Equatable, CustomStringConvertible {
    /// No `[virt-viewer]` group was found in the file.
    case missingGroup
    /// The `type` is not `spice` (we only support SPICE).
    case unsupportedType(String?)
    /// Neither a `tls-port` nor a `port` was present, so there is nothing to connect to.
    case missingPort
    /// No `host` value was present.
    case missingHost

    public var description: String {
        switch self {
        case .missingGroup:
            return "Not a virt-viewer file: missing the [virt-viewer] section."
        case .unsupportedType(let t):
            return "Unsupported connection type \(t.map { "'\($0)'" } ?? "(none)"); only 'spice' is supported."
        case .missingPort:
            return "Connection file has neither 'tls-port' nor 'port'."
        case .missingHost:
            return "Connection file is missing 'host'."
        }
    }
}

extension VVConfig {
    /// The INI group virt-viewer files use.
    static let groupName = "virt-viewer"

    /// Parse `.vv` text. Tolerant of the quirks real Proxmox files exhibit:
    /// CRLF line endings, `#`/`;` comments, blank lines, surrounding whitespace,
    /// values containing `=` (subjects, base64 tokens), and `ca` values whose
    /// newlines are escaped as the literal two characters `\n`.
    public static func parse(_ text: String) throws -> VVConfig {
        var raw: [String: String] = [:]
        var inGroup = false

        // Normalize line endings first. NB: Swift treats "\r\n" as a single grapheme
        // cluster, so splitting on the Character "\n" would NOT split a CRLF file —
        // collapse CRLF and lone CR to LF before splitting.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Comments. (Note: do not treat ';' inside values as a comment — only
            // a line that *starts* with a comment marker is a comment.)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            // Group header: [name]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let name = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                inGroup = (name == groupName)
                continue
            }

            guard inGroup else { continue }

            // key=value — split on the FIRST '=' only.
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            raw[key] = value
        }

        // A usable file must have a non-empty [virt-viewer] group. If the file had
        // no such group (or only comments under it), `raw` is empty and we reject it.
        guard raw.isEmpty == false else {
            throw VVConfigError.missingGroup
        }

        var cfg = VVConfig(raw: raw)
        cfg.type = raw["type"]
        cfg.host = raw["host"]
        cfg.port = raw["port"].flatMap { Int($0) }
        cfg.tlsPort = raw["tls-port"].flatMap { Int($0) }
        cfg.password = raw["password"]
        cfg.hostSubject = raw["host-subject"]
        cfg.caCertificate = raw["ca"].map(expandEscapedNewlines)
        cfg.proxy = raw["proxy"].flatMap { $0.isEmpty ? nil : $0 }
        cfg.title = raw["title"]
        cfg.fullscreen = raw["fullscreen"].flatMap(parseBool)
        cfg.toggleFullscreen = raw["toggle-fullscreen"]
        cfg.releaseCursor = raw["release-cursor"]
        cfg.secureAttention = raw["secure-attention"]
        cfg.deleteThisFile = raw["delete-this-file"].flatMap(parseBool)
        return cfg
    }

    /// Parse a `.vv` file from disk.
    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self = try VVConfig.parse(text)
    }

    /// Validate that this config is a usable SPICE connection. Throws a
    /// `VVConfigError` describing the first problem found.
    public func validate() throws {
        // Proxmox always sets type=spice; some emitters omit it but still mean SPICE.
        if let t = type, t.lowercased() != "spice" {
            throw VVConfigError.unsupportedType(t)
        }
        guard let host, host.isEmpty == false else { throw VVConfigError.missingHost }
        guard (tlsPort != nil) || (port != nil) else { throw VVConfigError.missingPort }
    }

    /// True when this looks like a Proxmox connection: it routes through a proxy
    /// and the `host` is an opaque `pvespiceproxy` token rather than a hostname.
    public var isProxmox: Bool {
        guard let proxy, proxy.isEmpty == false else { return false }
        let h = host ?? ""
        return h.hasPrefix("pvespiceproxy") || (proxy.contains(":3128"))
    }

    /// Convert a value whose newlines were escaped as the literal two-character
    /// sequence `\n` back into real newlines. Idempotent for already-expanded PEM.
    public static func expandEscapedNewlines(_ s: String) -> String {
        // Proxmox writes the CA as one line with literal "\n" between PEM lines.
        // Replace the two characters backslash + n with an actual newline.
        s.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Parse the boolean conventions virt-viewer/Proxmox use (`1`/`0`, `true`/`false`,
    /// `yes`/`no`, `on`/`off`).
    public static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}
