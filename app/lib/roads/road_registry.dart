import 'dart:convert';

import 'credential_strip.dart';
import 'road_sources.dart';

/// The WZDx Feed Registry (data.transportation.gov dataset 69qe-yiui, the USDOT's own list of work zone feeds): the addresses of the
/// feeds the data file lists. The data file has no addresses on purpose: some registry rows carry the publisher's own token inline, even
/// on rows marked "no key needed". Every address read here is stripped of credentials (credential_strip.dart) before anything stores,
/// shows or logs it. A feed that needs a key uses the person's own key (the data file's `auth`), never the publisher's embedded value.

/// The registry's documented Socrata API.
const String kRegistryUrl = 'https://data.transportation.gov/resource/69qe-yiui.json?\$limit=500';

/// What to say when an address had a credential in it.
const String kCredentialRemovedNote = 'Any key in the address was removed. Add your key in Settings > API keys.';

/// One registry row, with its address stripped.
class RegistryFeed {
  const RegistryFeed({required this.id, required this.url, required this.version, required this.active, required this.removedCredential, this.state = '', this.organization = ''});

  /// The registry's `feedname`.
  final String id;

  /// The address, without credentials; empty when the row had no usable address.
  final String url;
  final String version;
  final bool active;

  /// The row's address had a credential in it (removed; never kept anywhere).
  final bool removedCredential;
  final String state;
  final String organization;

  bool get hasAddress => url.isNotEmpty;
}

/// The rows of the registry by feed id.
class RoadRegistry {
  const RoadRegistry(this.feeds);

  final Map<String, RegistryFeed> feeds;

  static const RoadRegistry empty = RoadRegistry({});

  RegistryFeed? feed(String id) => feeds[id];

  /// Reads the registry's JSON (a list of rows; `url` is a text or, as Socrata writes a URL column, an object with `url`). A row with no
  /// feed name is skipped; a row with an address that is not https has none. Throws [FormatException] when the text is not the list.
  static RoadRegistry parse(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw const FormatException('The registry is not readable.');
    }
    if (j is! List) throw const FormatException('The registry is not readable.');
    final out = <String, RegistryFeed>{};
    for (final r in j) {
      if (r is! Map) continue;
      final id = r['feedname'];
      if (id is! String || id.trim().isEmpty) continue;
      final u = r['url'];
      final raw = u is String ? u : (u is Map && u['url'] is String ? u['url'] as String : '');
      final s = stripCredentials(raw);
      final active = '${r['active'] ?? 'yes'}'.toLowerCase();
      out.putIfAbsent(
        id.trim(),
        () => RegistryFeed(
          id: id.trim(),
          url: s.valid ? s.url : '',
          version: '${r['version'] ?? ''}'.trim(),
          active: active != 'no' && active != 'false' && active != 'n',
          removedCredential: s.valid && s.removed,
          state: '${r['state'] ?? ''}'.trim(),
          organization: '${r['issuingorganization'] ?? ''}'.trim(),
        ),
      );
    }
    return RoadRegistry(out);
  }

  /// The registry through [fetch] (the app's own fetch; a test hands a fake). The answer is read with [parse].
  static Future<RoadRegistry> load(Future<List<int>> Function(Uri url) fetch) async => parse(utf8.decode(await fetch(Uri.parse(kRegistryUrl)), allowMalformed: true));
}

/// What adding a feed came to.
enum AddFeedResult { added, already, notUsable, noAddress }

/// A pasted address, read: the stripped address and whether a credential was in it, or the problem.
class PastedFeed {
  const PastedFeed({this.url, this.removedCredential = false, this.problem});

  final String? url;
  final bool removedCredential;
  final String? problem;

  bool get ok => url != null;

  /// The note to show next to a pasted address that had a credential in it.
  String? get note => removedCredential ? kCredentialRemovedNote : null;
}

/// Reads a pasted feed address: strips credentials; refuses what is not an https address.
PastedFeed readPastedFeed(String text) {
  final s = stripCredentials(text);
  if (!s.valid) return const PastedFeed(problem: 'Enter an address that starts with https://');
  return PastedFeed(url: s.url, removedCredential: s.removed);
}

/// The feeds of the data file that the picker lists as usable, with their addresses from [registry]: the feeds Cache can add today.
List<RoadFeed> addableFeeds(RoadSourcesFile file, RoadRegistry registry) => [
  for (final f in file.feeds)
    if (f.usable && (registry.feed(f.id)?.hasAddress ?? false)) f,
];
