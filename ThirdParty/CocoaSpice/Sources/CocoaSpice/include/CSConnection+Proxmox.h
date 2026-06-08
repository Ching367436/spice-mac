//
// CSConnection+Proxmox.h
//
// spice-mac fork addition (Apache-2.0, same as CocoaSpice).
//
// Proxmox VE serves SPICE consoles over TLS through the node's `spiceproxy`
// (port 3128). The `.vv` file it emits carries an opaque `host` token (not a
// hostname), an HTTP `proxy`, a one-time ticket `password`, the cluster `ca`
// (PEM), and a `host-subject` the server certificate must match. Stock
// CocoaSpice only pins TLS by public key and never exposes the underlying
// SpiceSession, so none of `proxy` / `ca` / `cert-subject` / subject-verify can
// be configured from outside the library. This category adds the one method the
// host app needs; the implementation lives in CSConnection.m where the private
// SpiceSession is reachable.
//

#import "CSConnection.h"

NS_ASSUME_NONNULL_BEGIN

@interface CSConnection (Proxmox)

/// Configure the session for a Proxmox-style TLS-via-proxy connection.
///
/// This routes the TLS connection through @c proxy, trusts the supplied CA, and
/// switches certificate verification to **subject** matching (replacing
/// CocoaSpice's default public-key pinning) — which is how Proxmox's spiceproxy
/// presents its node cluster certificate. Call after one of the TLS designated
/// initializers and before `-connect`.
///
/// Each argument is applied only when non-nil, so callers may set a subset.
///
/// @param proxy       Proxy URI, e.g. @c http://node.example.com:3128. Pass an
///                    empty string to clear a previously set proxy; pass nil to
///                    leave it unchanged.
/// @param caPEM       CA certificate(s) in PEM (newlines already expanded), or
///                    nil to leave unchanged.
/// @param certSubject X.509 subject to verify, e.g.
///                    @c "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=node.example.com".
///                    When non-nil, verification mode is set to subject-only.
- (void)setProxy:(nullable NSString *)proxy
              ca:(nullable NSString *)caPEM
     certSubject:(nullable NSString *)certSubject;

@end

NS_ASSUME_NONNULL_END
