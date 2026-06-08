import Foundation
import VVConfig

// A realistic Proxmox VE spiceproxy file. `\\n` here is the literal two-character
// sequence backslash-n that Proxmox writes into the `ca` value.
let proxmoxSample = """
[virt-viewer]
secure-attention=ctrl+alt+ins
delete-this-file=1
proxy=http://node1.example.com:3128
type=spice
host=pvespiceproxy:1700000000:101:node1::abcdef0123456789==
title=VM 101 - Proxmox
host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=node1.example.com
toggle-fullscreen=shift+f11
release-cursor=shift+f12
password=S3cr3tT1ck3t
tls-port=61000
ca=-----BEGIN CERTIFICATE-----\\nMIIDsampleBase64Line1\\nMIIDsampleBase64Line2\\n-----END CERTIFICATE-----\\n
"""

let t = TestRunner()
print("VVConfig checks")

t.test("parses all Proxmox fields") {
    let cfg = try VVConfig.parse(proxmoxSample)
    t.expectEqual(cfg.type, "spice")
    t.expectEqual(cfg.host, "pvespiceproxy:1700000000:101:node1::abcdef0123456789==")
    t.expectNil(cfg.port)
    t.expectEqual(cfg.tlsPort, 61000)
    t.expectEqual(cfg.password, "S3cr3tT1ck3t")
    t.expectEqual(cfg.proxy, "http://node1.example.com:3128")
    t.expectEqual(cfg.title, "VM 101 - Proxmox")
    t.expectEqual(cfg.toggleFullscreen, "shift+f11")
    t.expectEqual(cfg.releaseCursor, "shift+f12")
    t.expectEqual(cfg.secureAttention, "ctrl+alt+ins")
    t.expectEqual(cfg.deleteThisFile, true)
}

t.test("host-subject keeps its '=' signs (split on first '=' only)") {
    let cfg = try VVConfig.parse(proxmoxSample)
    t.expectEqual(cfg.hostSubject,
        "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=node1.example.com")
}

t.test("CA escaped newlines are expanded to real newlines") {
    let cfg = try VVConfig.parse(proxmoxSample)
    let ca = try t.unwrap(cfg.caCertificate)
    t.expect(ca.hasPrefix("-----BEGIN CERTIFICATE-----"), "CA should start with PEM header")
    t.expect(ca.contains("\n"), "CA should contain real newlines")
    t.expect(!ca.contains("\\n"), "CA must not contain literal backslash-n")
    t.expect(ca.contains("-----END CERTIFICATE-----"), "CA should contain PEM footer")
    let lines = ca.split(separator: "\n").filter { !$0.isEmpty }
    t.expect(lines.count >= 4, "expected >= 4 PEM lines, got \(lines.count)")
}

t.test("isProxmox is true and validate passes") {
    let cfg = try VVConfig.parse(proxmoxSample)
    t.expect(cfg.isProxmox, "should be detected as Proxmox")
    try cfg.validate()
}

t.test("derived connection parameters for Proxmox") {
    let cfg = try VVConfig.parse(proxmoxSample)
    let p = try SpiceConnectionParameters(from: cfg)
    t.expectEqual(p.host, cfg.host ?? "")
    t.expectEqual(p.tlsPort, 61000)
    t.expectEqual(p.password, "S3cr3tT1ck3t")
    t.expectEqual(p.proxy, "http://node1.example.com:3128")
    t.expectEqual(p.certSubject, "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=node1.example.com")
    t.expect(p.verifySubject, "should verify by subject")
    t.expect(p.requiresProxyExtension, "should require the forked proxy extension")
    t.expect(p.isTLS, "should be TLS")
    t.expect(p.caPEM != nil, "should carry the CA PEM")
}

t.test("CRLF line endings handled, no stray CR in values") {
    let crlf = "[virt-viewer]\r\ntype=spice\r\nhost=example.com\r\nport=5900\r\n"
    let cfg = try VVConfig.parse(crlf)
    t.expectEqual(cfg.host, "example.com")
    t.expectEqual(cfg.port, 5900)
    t.expect(!(cfg.host?.contains("\r") ?? false), "host should not contain CR")
}

t.test("comments and blank lines ignored") {
    let text = """
    # a comment
    ; another comment

    [virt-viewer]
      type=spice
    host=example.com
      tls-port=61000

    # trailing comment
    """
    let cfg = try VVConfig.parse(text)
    t.expectEqual(cfg.type, "spice")
    t.expectEqual(cfg.host, "example.com")
    t.expectEqual(cfg.tlsPort, 61000)
}

t.test("keys outside the [virt-viewer] group are ignored") {
    let text = """
    [other]
    host=should-be-ignored.example.com
    [virt-viewer]
    type=spice
    host=real.example.com
    port=5900
    """
    let cfg = try VVConfig.parse(text)
    t.expectEqual(cfg.host, "real.example.com")
}

t.test("plain SPICE file is not Proxmox") {
    let text = "[virt-viewer]\ntype=spice\nhost=10.0.0.5\nport=5900\n"
    let cfg = try VVConfig.parse(text)
    t.expect(!cfg.isProxmox, "plain SPICE should not be Proxmox")
    let p = try SpiceConnectionParameters(from: cfg)
    t.expectEqual(p.host, "10.0.0.5")
    t.expectEqual(p.port, 5900)
    t.expect(!p.verifySubject, "plain should not verify subject")
    t.expect(!p.requiresProxyExtension, "plain should not need proxy extension")
    t.expect(!p.isTLS, "plain should not be TLS")
}

t.test("boolean parsing variants") {
    t.expectEqual(VVConfig.parseBool("1"), true)
    t.expectEqual(VVConfig.parseBool("0"), false)
    t.expectEqual(VVConfig.parseBool("true"), true)
    t.expectEqual(VVConfig.parseBool("FALSE"), false)
    t.expectEqual(VVConfig.parseBool("yes"), true)
    t.expectEqual(VVConfig.parseBool("no"), false)
    t.expectEqual(VVConfig.parseBool("on"), true)
    t.expectEqual(VVConfig.parseBool("off"), false)
    t.expectNil(VVConfig.parseBool("maybe"))
}

// MARK: - Error cases

t.test("missing [virt-viewer] group throws .missingGroup") {
    t.expectThrows(VVConfigError.missingGroup) {
        _ = try VVConfig.parse("type=spice\nhost=x\n")
    }
}

t.test("unsupported type throws .unsupportedType") {
    let cfg = try VVConfig.parse("[virt-viewer]\ntype=vnc\nhost=x\nport=5900\n")
    t.expectThrows(VVConfigError.unsupportedType("vnc")) { try cfg.validate() }
}

t.test("missing port throws .missingPort") {
    let cfg = try VVConfig.parse("[virt-viewer]\ntype=spice\nhost=x\n")
    t.expectThrows(VVConfigError.missingPort) { try cfg.validate() }
}

t.test("missing host throws .missingHost") {
    let cfg = try VVConfig.parse("[virt-viewer]\ntype=spice\ntls-port=61000\n")
    t.expectThrows(VVConfigError.missingHost) { try cfg.validate() }
}

t.test("raw preserves unknown/future keys") {
    let cfg = try VVConfig.parse("[virt-viewer]\ntype=spice\nhost=x\nport=5900\nsome-future-key=42\n")
    t.expectEqual(cfg.raw["some-future-key"], "42")
}

t.finishAndExit()
