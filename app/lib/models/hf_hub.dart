import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../net/fetch.dart' show kUserAgent;


/// A model repository on Hugging Face.
class HfModel {
  const HfModel({required this.id, this.downloads = 0, this.likes = 0, this.gated = false});

  /// "owner/name".
  final String id;
  final int downloads;
  final int likes;

  /// The repository asks people to sign in and accept terms before downloading.
  final bool gated;

  String get owner => id.contains('/') ? id.substring(0, id.indexOf('/')) : '';
  String get name => id.contains('/') ? id.substring(id.indexOf('/') + 1) : id;
}

/// One downloadable model file (a single .gguf) in a repository.
class HfFile {
  const HfFile({required this.repo, required this.path, required this.size, this.sha256, this.revision = 'main'});

  final String repo;

  /// The branch or commit the file is downloaded from: "main" for a file picked from a listing, a commit for a pinned file.
  final String revision;

  /// The path inside the repository, for example "gemma-4-E2B-it-Q4_K_M.gguf".
  final String path;
  final int size;

  /// The file's SHA-256 as Hugging Face stores it, when it gives one.
  final String? sha256;

  /// The name the file gets in the models folder.
  String get fileName => path.split('/').last;
}

/// Hugging Face's public model API (search and file listing) and its download addresses. No account is used.
class HfHub {
  HfHub({Uri? base, HttpClient Function()? client})
    : base = base ?? Uri.parse('https://huggingface.co'),
      _client = client ?? _defaultClient;

  final Uri base;
  final HttpClient Function() _client;

  static HttpClient _defaultClient() => HttpClient()
    ..userAgent = kUserAgent
    ..connectionTimeout = const Duration(seconds: 20);

  Future<Object?> _getJson(Uri u) async {
    final c = _client();
    try {
      final req = await c.getUrl(u);
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('Hugging Face answered ${res.statusCode}', uri: u);
      return jsonDecode(body);
    } finally {
      c.close(force: true);
    }
  }

  /// Model repositories with GGUF files matching [query], most downloaded first.
  Future<List<HfModel>> search(String query, {int limit = 30}) async {
    final u = base.replace(path: '/api/models', queryParameters: {
      'search': query.trim(),
      'filter': 'gguf',
      'sort': 'downloads',
      'direction': '-1',
      'limit': '$limit',
    });
    final j = await _getJson(u);
    if (j is! List) return const [];
    return [
      for (final m in j)
        if (m is Map && m['id'] is String && m['private'] != true)
          HfModel(
            id: m['id'] as String,
            downloads: (m['downloads'] as num?)?.toInt() ?? 0,
            likes: (m['likes'] as num?)?.toInt() ?? 0,
            gated: m['gated'] != null && m['gated'] != false,
          ),
    ];
  }

  /// The single-file .gguf models in [repo], smallest first. Split files (…-00001-of-00003.gguf), vision projectors
  /// (mmproj…) and draft heads (mtp…) are left out: the app loads one complete model file.
  Future<List<HfFile>> ggufFiles(String repo) async {
    final u = base.replace(path: '/api/models/$repo/tree/main', queryParameters: {'recursive': 'true'});
    final j = await _getJson(u);
    if (j is! List) return const [];
    final split = RegExp(r'-\d{5}-of-\d{5}\.gguf$', caseSensitive: false);
    final out = <HfFile>[];
    for (final f in j) {
      if (f is! Map || f['type'] != 'file') continue;
      final path = '${f['path']}';
      final lower = path.toLowerCase();
      // Not models on their own: vision projectors (mmproj…) and multi-token-prediction draft heads (mtp…, often in an MTP/ folder).
      final segments = lower.split('/');
      if (!lower.endsWith('.gguf') ||
          split.hasMatch(lower) ||
          segments.last.startsWith('mmproj') ||
          segments.any((seg) => seg == 'mtp' || seg.startsWith('mtp-'))) {
        continue;
      }
      final lfs = f['lfs'];
      final size = ((lfs is Map ? lfs['size'] : null) ?? f['size']) as num?;
      if (size == null) continue;
      out.add(HfFile(
        repo: repo,
        path: path,
        size: size.toInt(),
        sha256: lfs is Map && lfs['oid'] is String && (lfs['oid'] as String).length == 64 ? lfs['oid'] as String : null,
      ));
    }
    out.sort((a, b) => a.size.compareTo(b.size));
    return out;
  }

  /// Where [f] downloads from (Hugging Face redirects to its file store).
  Uri downloadUrl(HfFile f) =>
      base.replace(path: '/${f.repo}/resolve/${f.revision}/${f.path.split('/').map(Uri.encodeComponent).join('/')}');

  /// The repository's page, for "Open on Hugging Face".
  Uri pageUrl(String repo) => base.replace(path: '/$repo');
}
