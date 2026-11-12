import 'dart:convert';

/// The link a device's link-code QR carries, and how an incoming link is read back. The form lives only here.
///
/// The link is `cachelink://link/<payload>`. The payload is in the path, never the host: hosts are case-insensitive, and a
/// camera or a browser may lowercase one, which would damage a payload. The scheme and the host ("link") are matched without
/// regard to case; the payload keeps its case.
///
/// Phase 1 payload: the link code the app shows today, `CACHE1-<Base32>`, unchanged. Its characters are A to Z, 2 to 7 and the
/// hyphen, all unreserved in an address, so it needs no escaping and the link carries exactly the code the person could type.
/// The code is Base32 (case-insensitive), so even a payload whose case was changed still decodes in the core.
/// `cachelink:<payload>` (no slashes, no host) is accepted too.

/// The scheme registered with the phone (AndroidManifest.xml, Info.plist).
const kLinkScheme = 'cachelink';

/// What comes before the payload in the link a device shows.
const kLinkPrefix = '$kLinkScheme://link/';

/// The longest payload read. A code is at most about 1,100 characters (a computer with many addresses); anything longer is
/// refused before it is decoded.
const kLinkMaxPayload = 2048;

/// The two messages the sync engine already gives for a code it cannot read (cache_sync, `decode_code`).
const kNotACode = 'this is not a Cache link code';
const kDamagedCode = 'the link code is damaged';

/// Thrown for a link or code that cannot be read; [message] is the person-facing text.
class BadLinkCode implements Exception {
  const BadLinkCode(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The link to show in a QR and to share, for [code] (a `CACHE1-…` link code).
String buildLinkUrl(String code) => '$kLinkPrefix${code.replaceAll(RegExp(r'\s'), '')}';

final _payload = RegExp(r'^[A-Za-z0-9-]+$');

/// Whether [text] is a `cachelink:` link of either form.
bool isLinkUrl(String text) => text.trim().toLowerCase().startsWith('$kLinkScheme:');

/// The link code inside [text]: from a `cachelink://link/<payload>` or `cachelink:<payload>` link, or [text] itself (whitespace
/// removed) when it is not a link. Throws [BadLinkCode] for a link with no usable payload and for anything oversized.
String linkCodeFrom(String text) {
  var t = text.replaceAll(RegExp(r'\s'), '');
  if (t.length > kLinkMaxPayload + kLinkPrefix.length) throw const BadLinkCode(kNotACode);
  if (!isLinkUrl(t)) {
    if (t.length > kLinkMaxPayload) throw const BadLinkCode(kNotACode);
    return t;
  }
  t = t.substring(kLinkScheme.length + 1);
  if (t.startsWith('//')) {
    final rest = t.substring(2);
    final slash = rest.indexOf('/');
    // The host is "link", in any case; anything else is not our link.
    if (slash < 0 || rest.substring(0, slash).toLowerCase() != 'link') throw const BadLinkCode(kNotACode);
    t = rest.substring(slash + 1);
  }
  final cut = t.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) t = t.substring(0, cut);
  if (t.contains('%')) {
    try {
      t = Uri.decodeComponent(t);
    } on Object {
      throw const BadLinkCode(kNotACode);
    }
  }
  if (t.endsWith('/')) t = t.substring(0, t.length - 1);
  if (t.isEmpty || t.length > kLinkMaxPayload || !_payload.hasMatch(t)) throw const BadLinkCode(kNotACode);
  return t;
}

/// What a link code says about its device, read without any connection (no network, no engine).
class LinkCodeInfo {
  const LinkCodeInfo({required this.id, required this.name});

  /// The device's key, as the engine writes it (the same text as a linked device's `id`).
  final String id;
  final String name;
}

const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

List<int>? _base32(String s) {
  final out = <int>[];
  var bits = 0, acc = 0;
  for (final c in s.toUpperCase().split('')) {
    final v = _b32.indexOf(c);
    if (v < 0) return null;
    acc = ((acc << 5) | v) & 0xFFFFFF;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xFF);
    }
  }
  return out;
}

/// The device a `CACHE1-` link code belongs to. Throws [BadLinkCode] with the engine's own messages when it is not one.
LinkCodeInfo decodeLinkCode(String code) {
  final s = code.replaceAll(RegExp(r'\s'), '').toUpperCase();
  if (!s.startsWith('CACHE1-')) throw const BadLinkCode(kNotACode);
  final bytes = _base32(s.substring(7));
  if (bytes == null) throw const BadLinkCode(kDamagedCode);
  try {
    final j = jsonDecode(utf8.decode(bytes)) as Map;
    final a = j['a'];
    final id = a is Map ? a['id'] : null;
    if (id is! String || id.isEmpty || j['t'] is! String) throw const BadLinkCode(kDamagedCode);
    return LinkCodeInfo(id: id, name: j['n'] is String ? j['n'] as String : '');
  } on FormatException {
    throw const BadLinkCode(kDamagedCode);
  } on TypeError {
    throw const BadLinkCode(kDamagedCode);
  }
}
