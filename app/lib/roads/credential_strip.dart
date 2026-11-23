// Credentials in feed addresses. Some WZDx registry addresses carry the publisher's own token or app key inline, even on rows marked "no
// key needed". Cache never draws, shows, logs, stores or syncs such a value: every address is stripped before anything else sees it, and
// a feed that needs a key uses the person's own key from Settings > API keys, attached by the feed's `auth` entry.
//
// This is a rule about a machine format (query parameter names), not about language.

// What was left of an address, and whether anything was taken out.
class Stripped {
  const Stripped(this.url, this.removed, this.valid);

  /// The address without credentials. Empty when [valid] is false.
  final String url;

  /// A credential was removed (a query parameter, or a user name and password before the host).
  final bool removed;

  /// The text was an address Cache may use (https, with a host).
  final bool valid;
}

/// Names of query parameters that are credentials, compared lower-case with `-` and `_` taken out.
const Set<String> _exact = {'auth', 'authorization', 'pwd', 'sig', 'signature', 'jwt', 'bearer'};

/// True for a query parameter name that says it is a key, token or other credential: `key`, `api_key`, `apiKey`, `api-key`, `app_key`,
/// `token`, `access_token`, `subscription-key`, `secret`, `password`, and the like.
bool isCredentialParam(String name) {
  final n = name.toLowerCase().replaceAll(RegExp(r'[-_\s.]'), '');
  if (n.isEmpty) return false;
  if (_exact.contains(n)) return true;
  return n.endsWith('key') || n.contains('token') || n.contains('secret') || n.contains('password') || n.contains('passwd');
}

/// [address] without credentials: query parameters that [isCredentialParam], a user name and password before the host, and the
/// fragment are removed. Anything that is not an https address with a host is not valid (nothing is returned for it).
Stripped stripCredentials(String address) {
  final u = Uri.tryParse(address.trim());
  if (u == null || !u.hasScheme || u.scheme.toLowerCase() != 'https' || u.host.isEmpty) return const Stripped('', false, false);
  var removed = u.userInfo.isNotEmpty || u.hasFragment;
  final kept = <String>[];
  final raw = u.hasQuery ? u.query : '';
  for (final part in raw.isEmpty ? const <String>[] : raw.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final name = Uri.decodeQueryComponent(eq < 0 ? part : part.substring(0, eq));
    if (isCredentialParam(name)) {
      removed = true;
    } else {
      kept.add(part);
    }
  }
  final clean = Uri(scheme: 'https', host: u.host, port: u.hasPort && u.port != 443 ? u.port : null, path: u.path, query: kept.isEmpty ? null : kept.join('&'));
  return Stripped(clean.toString(), removed, true);
}

/// The address as it may be written to a log: the host and path only. No query, so no value of any parameter.
String addressForLog(String address) {
  final u = Uri.tryParse(address.trim());
  if (u == null || u.host.isEmpty) return '(address)';
  return '${u.host}${u.path}';
}
