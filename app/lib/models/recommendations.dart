import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../net/fetch.dart';
import 'hf_hub.dart';

/// Where the list of recommended models is published, so it can change without an app release.
const String kRecommendedModelsUrl = 'https://data.cached.info/models/recommended.json';

/// The copy built into the app (docs/models-recommended.json in the repository), used on first run, offline and when the
/// published list cannot be read.
const String kRecommendedModelsAsset = 'assets/models/recommended.json';

/// The format of the recommendations file this app writes and reads. Format 2 added direct-address entries (`url`), the `revision`
/// of a Hugging Face entry, the section (`recommended` or `experimental`) and a licence line; format 1 files are still read (every
/// entry recommended). A file of another format is not used.
const int kRecommendationsFormat = 2;

/// Where a recommended model is listed on the Models screen.
enum RecommendationSection { recommended, experimental }

/// How a recommended model stands with Cache.
enum RecommendationKind {
  /// Cache's own fine-tuned model.
  tunedForCache('tuned_for_cache', 'Tuned for Cache'),

  /// A tested base model that can use tools.
  worksNotTuned('works_not_tuned', 'Works with Cache, not tuned');

  const RecommendationKind(this.id, this.label);

  /// The value in the file.
  final String id;

  /// The words on the screen.
  final String label;

  static RecommendationKind? byId(Object? id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// Settings a recommended model may carry, applied when that model is loaded. Every field is optional: a missing one keeps what the
/// app does for any model (the sampling the GGUF recommends with llama.cpp's defaults for the rest, 8192 tokens of context, no
/// output cap, the template's own stop). Today the engine takes [temp] and [nCtx]; the others are carried for when it takes them.
/// [fetchFirst] is reserved (false; not used in 1.0.29).
class ModelSettings {
  const ModelSettings({this.temp, this.topK, this.topP, this.minP, this.repeatPenalty, this.nCtx, this.maxTokens, this.stop = const [], this.fetchFirst = false});

  final double? temp;
  final int? topK;
  final double? topP;
  final double? minP;
  final double? repeatPenalty;
  final int? nCtx;
  final int? maxTokens;
  final List<String> stop;
  final bool fetchFirst;

  static const none = ModelSettings();

  bool get isEmpty => temp == null && topK == null && topP == null && minP == null && repeatPenalty == null && nCtx == null && maxTokens == null && stop.isEmpty;

  static ModelSettings fromJson(Object? j) {
    if (j is! Map) return none;
    double? d(String k) => j[k] is num ? (j[k] as num).toDouble() : null;
    int? n(String k) => j[k] is int && (j[k] as int) > 0 ? j[k] as int : null;
    return ModelSettings(
      temp: d('temp'),
      topK: n('top_k'),
      topP: d('top_p'),
      minP: d('min_p'),
      repeatPenalty: d('repeat_penalty'),
      nCtx: n('n_ctx'),
      maxTokens: n('max_tokens'),
      stop: [for (final s in (j['stop'] is List ? j['stop'] as List : const [])) if (s is String && s.isNotEmpty) s],
      fetchFirst: j['fetch_first'] == true,
    );
  }

  /// What a generation request carries for these settings (only what the engine takes: temperature).
  Map<String, dynamic> get requestExtras => {if (temp != null) 'temperature': temp};
}

/// One recommended model file: on Hugging Face ([repo], [revision]), or at a direct address ([url]).
class ModelRecommendation {
  const ModelRecommendation({
    required this.name,
    required this.repo,
    required this.file,
    required this.size,
    required this.kind,
    this.sha256,
    this.note = '',
    this.url,
    this.revision = 'main',
    this.section = RecommendationSection.recommended,
    this.licence,
    this.settings = ModelSettings.none,
    this.uncensored = false,
  });

  /// An uncensored model: its row carries the "Uncensored" tag (an Experimental entry is not uncensored by being there).
  final bool uncensored;

  /// The model's own settings (none: the app's usual ones).
  final ModelSettings settings;

  /// The file's direct address (https), for a file not on Hugging Face; [repo] is then empty.
  final Uri? url;

  /// The commit (or branch) of a Hugging Face entry.
  final String revision;
  final RecommendationSection section;

  /// One line about the licence, for a model Cache tuned ("Apache-2.0 (Gemma 4 E2B), fine-tuned by Cache").
  final String? licence;

  /// What the row is called, for example "Gemma 4 E2B · Q4_K_M".
  final String name;

  /// "owner/name" on Hugging Face.
  final String repo;

  /// The file's path in the repository.
  final String file;
  final int size;
  final String? sha256;
  final RecommendationKind kind;

  /// One plain line about the model.
  final String note;

  HfFile get hfFile => HfFile(repo: repo, path: file, size: size, sha256: sha256, revision: revision, url: url);

  /// Null when an entry lacks what a download needs or has a kind this app does not know.
  static ModelRecommendation? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], repo = j['repo'], file = j['file'], size = j['size'], sha = j['sha256'], note = j['note'];
    final kind = RecommendationKind.byId(j['kind']);
    final url = j['url'] is String ? Uri.tryParse(j['url'] as String) : null;
    final direct = url != null && url.scheme == 'https' && url.host.isNotEmpty;
    if (name is! String || file is! String || !file.toLowerCase().endsWith('.gguf')) return null;
    if (!direct && (repo is! String || !repo.contains('/'))) return null;
    if (j['url'] != null && !direct) return null;
    if (size is! int || size <= 0 || kind == null) return null;
    final shaOk = sha is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha);
    // A file at a direct address is only taken with its checksum: nothing else vouches for it.
    if (direct && !shaOk) return null;
    final section = j['section'] == 'experimental' ? RecommendationSection.experimental : RecommendationSection.recommended;
    return ModelRecommendation(
      name: name,
      repo: direct ? '' : repo as String,
      file: file,
      size: size,
      kind: kind,
      sha256: shaOk ? sha : null,
      note: note is String ? note : '',
      url: direct ? url : null,
      revision: j['revision'] is String && (j['revision'] as String).isNotEmpty ? j['revision'] as String : 'main',
      section: section,
      licence: j['licence'] is String ? j['licence'] as String : null,
      settings: ModelSettings.fromJson(j['settings']),
      uncensored: j['uncensored'] == true,
    );
  }
}

/// The recommendations file:
///
/// ```json
/// {"format": 2, "models": [{"name": "...", "repo": "owner/name", "revision": "commit", "file": "x.gguf", "size": 123,
///   "sha256": "... or null", "kind": "tuned_for_cache" | "works_not_tuned", "section": "recommended" | "experimental",
///   "licence": "optional line", "note": "one line", "uncensored": true (optional), "settings": {"temp": 1.0, "top_k": 64, "top_p": 0.95, "min_p": 0.05,
///   "repeat_penalty": 1.0, "n_ctx": 8192, "max_tokens": 2048, "stop": [], "fetch_first": false} (every setting optional)},
///   {"name": "...", "url": "https://...", "file": "x.gguf", "size": 123, "sha256": "required", ...}]}
/// ```
///
/// Null when the text is not a file of [kRecommendationsFormat]. Entries this app cannot use are left out.
List<ModelRecommendation>? parseRecommendations(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || (j['format'] != kRecommendationsFormat && j['format'] != 1) || j['models'] is! List) return null;
    return [
      for (final m in j['models'] as List)
        ?ModelRecommendation.fromJson(m),
    ];
  } catch (_) {
    return null;
  }
}

/// The recommended models: the built-in copy at first, then the published list once it has been read (once per run).
class RecommendedModels extends ChangeNotifier {
  RecommendedModels({Future<String> Function()? builtIn, Future<String> Function()? fetch})
    : _builtIn = builtIn ?? (() => rootBundle.loadString(kRecommendedModelsAsset)),
      _fetch = fetch ?? _fetchPublished;

  /// The app's list, made when first asked for; tests put their own here.
  static RecommendedModels get shared => _shared ??= RecommendedModels();
  static set shared(RecommendedModels value) => _shared = value;
  static RecommendedModels? _shared;

  final Future<String> Function() _builtIn;
  final Future<String> Function() _fetch;

  List<ModelRecommendation> models = const [];

  /// True once the published list has replaced the built-in one.
  bool fromNetwork = false;

  Future<void>? _loading;

  /// Reads the built-in copy, then the published list. Later calls wait for the first one.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final b = parseRecommendations(await _builtIn());
      if (b != null) {
        models = b;
        notifyListeners();
      }
    } catch (_) {}
    try {
      final r = parseRecommendations(await _fetch());
      if (r != null) {
        models = r;
        fromNetwork = true;
        notifyListeners();
      }
    } catch (_) {
      // Offline or not published: the built-in copy stays.
    }
  }

  /// No model tuned for Cache is in the list yet.
  bool get noneTuned => !models.any((m) => m.kind == RecommendationKind.tunedForCache);

  static Future<String> _fetchPublished() => fetchText(Uri.parse(kRecommendedModelsUrl));

}
