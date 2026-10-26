import 'dart:convert';

import 'package:cache_search/cache_search.dart';

/// The reader shows a ZIM like a web site. Every page address is `https://zim.invalid/<zim id>/<path>`: the host
/// never resolves, and the reader answers every request to it itself from the ZIM (cs_zim_get), so links,
/// style sheets and images work with no network.
const String zimHost = 'zim.invalid';

final RegExp _zimAddress = RegExp(r'^zim:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/(.+)$');

/// True for a `zim:<uuid>/<path>` address.
bool isZimAddress(String s) => _zimAddress.hasMatch(s);

/// The id (UUID, lowercase) in a zim address, or null.
String? zimIdOfAddress(String address) => _zimAddress.firstMatch(address)?.group(1)?.toLowerCase();

const String _keep = "-._~!\$&'()*+,;=:@/%?";

String _encodePath(String p) {
  final out = StringBuffer();
  for (final r in p.runes) {
    final isAlnum = (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5a) || (r >= 0x61 && r <= 0x7a);
    if (isAlnum || (r < 0x80 && _keep.contains(String.fromCharCode(r)))) {
      out.writeCharCode(r);
    } else {
      for (final b in utf8.encode(String.fromCharCode(r))) {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
  }
  return out.toString();
}

/// The page address for a `zim:<uuid>/<path>` address, or null if [address] is not one. The address's own
/// escapes (%25 for a % and %23 for a # in the entry path) are kept as they are.
Uri? readerUrl(String address) {
  final m = _zimAddress.firstMatch(address);
  if (m == null) return null;
  final path = m.group(2)!.split('#').first;
  return Uri.parse('https://$zimHost/${m.group(1)!.toLowerCase()}/${_encodePath(path)}');
}

/// The `zim:` address of a page address, or null if it is not a ZIM page.
String? addressOfUrl(Uri url) {
  if (url.host != zimHost) return null;
  final raw = url.path; // still percent-encoded: the core decodes it
  final i = raw.indexOf('/', 1);
  if (raw.length < 2 || i < 0) return null;
  final id = raw.substring(1, i);
  final rest = raw.substring(i + 1);
  if (rest.isEmpty) return null;
  return 'zim:$id/$rest${url.hasQuery ? '?${url.query}' : ''}';
}

class ServedEntry {
  const ServedEntry(this.status, this.mime, this.bytes);

  final int status;
  final String mime;
  final List<int> bytes;
}

/// Answers a request to the reader's fake host from the ZIM. Anything else gets a 404 with no network use.
class ZimPageServer {
  ZimPageServer(this.get);

  final Future<ZimBytes> Function(String address) get;

  Future<ServedEntry> serve(Uri url) async {
    final address = addressOfUrl(url);
    if (address == null) return const ServedEntry(404, 'text/plain', []);
    try {
      final z = await get(address);
      return ServedEntry(200, z.mime, z.bytes);
    } on CacheSearchException catch (e) {
      if (e.code == 'not_found') return const ServedEntry(404, 'text/plain', []);
      return ServedEntry(500, 'text/plain', utf8.encode(e.message));
    } catch (e) {
      return ServedEntry(500, 'text/plain', utf8.encode('$e'));
    }
  }
}
