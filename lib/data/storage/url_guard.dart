// Which web addresses misc. may fetch by itself (link previews).
//
// A link that arrives from outside (the Share menu, the clipboard, a page)
// is untrusted. Fetching it must never reach into the user's own networks:
// the router, a NAS, another PC, this PC's services, or a Tailscale device.
// So only http(s) is allowed, the host is looked up first, and every address
// it resolves to must be public. The same check is made for every redirect.
//
// Limit (stated, not hidden): the check resolves the name and the HTTP
// client resolves it again when it connects, so a server that answers the two
// lookups differently (DNS rebinding) is not stopped by this alone.
import 'dart:io';

/// Whether [a] is an address that is not on the public internet: this
/// machine, a private or link-local network, carrier-grade NAT (which
/// includes Tailscale), multicast or unspecified.
bool isNonPublicAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) return _nonPublicV4(b);
  // IPv6.
  if (b.every((x) => x == 0)) return true; // ::
  // IPv4-mapped (::ffff:a.b.c.d): judge the embedded IPv4 address.
  final mapped =
      b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return _nonPublicV4(b.sublist(12));
  if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local (Tailscale)
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true; // fe80::/10
  return false;
}

bool _nonPublicV4(List<int> b) {
  if (b[0] == 0 || b[0] == 10 || b[0] == 127) return true;
  if (b[0] == 169 && b[1] == 254) return true; // link-local
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  if (b[0] == 192 && b[1] == 168) return true;
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true; // CGNAT/Tailscale
  if (b[0] == 192 && b[1] == 0 && b[2] == 0) return true; // IETF protocol
  if (b[0] >= 224) return true; // multicast and reserved
  return false;
}

/// Looks a host name up; replaceable in tests.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> systemResolve(String host) =>
    InternetAddress.lookup(host);

/// Whether [uri] is a web address that may be fetched: http or https, no
/// credentials in it, and a host that resolves only to public addresses.
/// Any failure to look the name up counts as "no".
Future<bool> isFetchableUrl(
  Uri uri, {
  HostResolver resolve = systemResolve,
}) async {
  if (!(uri.isScheme('http') || uri.isScheme('https'))) return false;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  final literal = InternetAddress.tryParse(uri.host);
  try {
    final addresses = literal != null ? [literal] : await resolve(uri.host);
    if (addresses.isEmpty) return false;
    return addresses.every((a) => !isNonPublicAddress(a));
  } on Exception {
    return false;
  }
}
