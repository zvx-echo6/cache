
import 'package:cache_search/cache_search.dart' show SearchCore;

/// "Search saved videos" by the words said in them: the search core's captions keyword index (captions interface v1,
/// 2026-11-02, cs_captions_search). The core builds the index itself (the scheduler starts the builds); the app only asks it.
/// The app runs on [CoreCaptionSearch]; [CaptionSearchMissing] is the stand-in where there is no core, and the tests and
/// renders run on [FakeCaptionSearch]. A saved video whose captions are not indexed yet simply has no matches (no error).
abstract class CaptionSearch {
  /// False while the core has no captions search.
  bool get available;

  /// cs_captions_search(h, {"query","k"?,"lang"?}): saved videos (and ZIM videos) matched by caption text, best first, up to 3
  /// hits each.
  Future<List<CaptionVideo>> search(String query, {int? k, String? lang});
}

/// One video cs_captions_search answers.
class CaptionVideo {
  const CaptionVideo({required this.sourceId, required this.link, required this.title, required this.host, required this.saved, required this.hits});

  factory CaptionVideo.fromJson(Map<String, dynamic> j) => CaptionVideo(
        sourceId: (j['source_id'] ?? '') as String,
        link: (j['link'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        host: (j['host'] ?? '') as String,
        saved: j['saved'] == true,
        hits: [for (final h in (j['hits'] as List? ?? const [])) CaptionHit.fromJson((h as Map).cast<String, dynamic>())],
      );

  /// `<host>/<video uuid>` for a PeerTube video, the ZIM's UUID for a ZIM's captions.
  final String sourceId;

  /// `https://<host>/w/<uuid>` (a PeerTube video; it resolves to the saved copy) or `zim:<uuid>/<video entry path>`.
  final String link;
  final String title;
  final String host;
  final bool saved;
  final List<CaptionHit> hits;

  bool get isZim => link.startsWith('zim:');

  /// The PeerTube video's uuid (the part of [sourceId] after the host), or null for a ZIM's captions.
  String? get uuid {
    if (isZim) return null;
    final i = sourceId.lastIndexOf('/');
    return i < 0 ? null : sourceId.substring(i + 1);
  }
}

class CaptionHit {
  const CaptionHit({required this.startS, required this.endS, required this.text, required this.lang});

  factory CaptionHit.fromJson(Map<String, dynamic> j) => CaptionHit(
        startS: ((j['start_s'] ?? 0) as num).toDouble(),
        endS: ((j['end_s'] ?? 0) as num).toDouble(),
        text: (j['text'] ?? '') as String,
        lang: (j['lang'] ?? '') as String,
      );

  final double startS;
  final double endS;
  final String text;
  final String lang;
}

/// The answer of cs_captions_search.
List<CaptionVideo> parseCaptionSearch(Map<String, dynamic> j) => [
      for (final v in (j['videos'] as List? ?? const [])) CaptionVideo.fromJson((v as Map).cast<String, dynamic>()),
    ];

/// cs_captions_search on the app's search core. A core without the call, a core not open yet, or any failure answers no
/// caption matches: the list's search still matches titles and channels, and nothing is said about it.
class CoreCaptionSearch implements CaptionSearch {
  CoreCaptionSearch(this.core);

  /// The app's search core once it is open (null before, or when it cannot open).
  final SearchCore? Function() core;

  @override
  bool get available => core() != null;

  @override
  Future<List<CaptionVideo>> search(String query, {int? k, String? lang}) async {
    final c = core();
    if (c == null || query.trim().isEmpty) return const [];
    try {
      if (!await c.hasCaptionsSearch()) return const [];
      return parseCaptionSearch(await c.captionsSearch(query, k: k, lang: lang));
    } catch (_) {
      return const [];
    }
  }
}

/// No search core: nothing is matched by caption text.
class CaptionSearchMissing implements CaptionSearch {
  const CaptionSearchMissing();

  @override
  bool get available => false;

  @override
  Future<List<CaptionVideo>> search(String query, {int? k, String? lang}) async => const [];
}

/// One video of a [FakeCaptionSearch]: its caption cues (start, end, text) in a language.
class FakeCaptionVideo {
  const FakeCaptionVideo({required this.host, required this.uuid, required this.title, required this.cues, this.lang = 'en', this.zimLink});

  final String host;
  final String uuid;
  final String title;
  final List<(double, double, String)> cues;
  final String lang;

  /// A ZIM video's `zim:` link in place of a PeerTube one.
  final String? zimLink;
}

/// A stand-in for cs_captions_search over a few videos: a cue matches when it holds every word of the query (case ignored),
/// like a keyword index; videos with more matches come first, at most 3 hits each.
class FakeCaptionSearch implements CaptionSearch {
  FakeCaptionSearch(this.videos);

  final List<FakeCaptionVideo> videos;
  final List<String> queries = [];

  @override
  bool get available => true;

  @override
  Future<List<CaptionVideo>> search(String query, {int? k, String? lang}) async {
    queries.add(query);
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    final out = <(int, CaptionVideo)>[];
    for (final v in videos) {
      if (lang != null && v.lang != lang) continue;
      final hits = [
        for (final c in v.cues)
          if (words.every(c.$3.toLowerCase().contains)) CaptionHit(startS: c.$1, endS: c.$2, text: c.$3, lang: v.lang),
      ];
      if (hits.isEmpty) continue;
      out.add((
        hits.length,
        CaptionVideo(
          sourceId: v.zimLink == null ? '${v.host}/${v.uuid}' : v.uuid,
          link: v.zimLink ?? 'https://${v.host}/w/${v.uuid}',
          title: v.title,
          host: v.host,
          saved: true,
          hits: hits.take(3).toList(),
        ),
      ));
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    final list = [for (final o in out) o.$2];
    return k == null ? list : list.take(k).toList();
  }
}
