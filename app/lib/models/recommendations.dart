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

/// The format of the recommendations file this app reads. A file of another format is not used.
const int kRecommendationsFormat = 1;

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

/// One recommended model file on Hugging Face.
class ModelRecommendation {
  const ModelRecommendation({
    required this.name,
    required this.repo,
    required this.file,
    required this.size,
    required this.kind,
    this.sha256,
    this.note = '',
  });

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

  HfFile get hfFile => HfFile(repo: repo, path: file, size: size, sha256: sha256);

  /// Null when an entry lacks what a download needs or has a kind this app does not know.
  static ModelRecommendation? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], repo = j['repo'], file = j['file'], size = j['size'], sha = j['sha256'], note = j['note'];
    final kind = RecommendationKind.byId(j['kind']);
    if (name is! String || repo is! String || !repo.contains('/') || file is! String || !file.toLowerCase().endsWith('.gguf')) {
      return null;
    }
    if (size is! int || size <= 0 || kind == null) return null;
    return ModelRecommendation(
      name: name,
      repo: repo,
      file: file,
      size: size,
      kind: kind,
      sha256: sha is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : null,
      note: note is String ? note : '',
    );
  }
}

/// The recommendations file:
///
/// ```json
/// {"format": 1, "models": [{"name": "...", "repo": "owner/name", "file": "x.gguf", "size": 123,
///   "sha256": "... or null", "kind": "tuned_for_cache" | "works_not_tuned", "note": "one line"}]}
/// ```
///
/// Null when the text is not a file of [kRecommendationsFormat]. Entries this app cannot use are left out.
List<ModelRecommendation>? parseRecommendations(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['format'] != kRecommendationsFormat || j['models'] is! List) return null;
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
