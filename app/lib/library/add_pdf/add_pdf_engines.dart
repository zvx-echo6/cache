import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show ByteData;

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

import '../../models/search_model.dart' show kSearchModel;
import '../../platform/app_log.dart';
import 'add_pdf_calls.dart';

/// The PDFium build pdfrx 2.4.8 ships (pdfium_flutter 0.2.3: the pdfium-binaries release chromium/7811), recorded in each pack.
const String kPdfiumVersion = 'chromium/7811';

/// The shelf sorter that ships in the app (the Linux builder's division classifier, trained on bge-m3 Q8_0).
const String kClassifierAsset = 'assets/models/cache-classifier-2.bin';

/// The classifier as a file the core can read: copied out of the app's assets into [support] the first time (and again when
/// the app ships a different one). Null when it cannot be copied.
Future<String?> classifierFile(Directory support, {Future<ByteData> Function(String key)? load}) async {
  final name = kClassifierAsset.split('/').last;
  final out = File('${support.path}${Platform.pathSeparator}models${Platform.pathSeparator}$name');
  try {
    final data = await (load ?? rootBundle.load)(kClassifierAsset);
    if (out.existsSync() && out.lengthSync() == data.lengthInBytes) return out.path;
    await out.parent.create(recursive: true);
    final tmp = File('${out.path}.tmp');
    await tmp.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    await tmp.rename(out.path);
    return out.path;
  } catch (e) {
    logError('Add PDF: the shelf sorter could not be copied out', error: e);
    return null;
  }
}

/// `engines` for the core's ingest job on this phone:
/// - `pdfium_lib`: the PDFium pdfrx loads (its module path; on Android the bundled `libpdfium.so`; on iOS it is linked into the
///   app, so none is named and the core finds it in the process);
/// - `embed_lib` and `embed_model`: the app's own `libcache_llama` (on iOS linked into the app: the app's executable) and the
///   search model, bge-m3, in the models folder, with its SHA-256;
/// - `classifier`: the shelf sorter.
Future<Map<String, dynamic>> addPdfEngines({required Directory support, required Directory modelsDir}) async {
  final pdfium = Pdfrx.pdfiumModulePath ?? (Platform.isAndroid ? 'libpdfium.so' : (Platform.isLinux ? 'libpdfium.so' : null));
  final classifier = await classifierFile(support);
  final llama = Platform.isIOS || Platform.isMacOS ? Platform.resolvedExecutable : (Platform.isWindows ? 'cache_llama.dll' : 'libcache_llama.so');
  return {
    'pdfium_lib': ?pdfium,
    'pdfium_version': kPdfiumVersion,
    'embed_lib': llama,
    'embed_model': '${modelsDir.path}${Platform.pathSeparator}${kSearchModel.fileName}',
    'embed_sha256': kSearchModel.sha256,
    'classifier': ?classifier,
  };
}

/// The startup self-check: the core's probe of the engines, logged at Standard in one line, so the first run on a phone says
/// whether PDFium loaded (and which), whether the model file is there, the model's SHA-256, and whether the shelf sorter
/// loads (and its version). The embedder is not loaded here (it loads when Add PDF runs). The model's SHA-256 is worked out once per model file (about 600 MB, seconds on a phone) and
/// remembered in [memo]; at later starts the probe skips hashing. A probe with no answer within [timeout] is logged as failed,
/// so the log never stays silent about it.
Future<Map<String, dynamic>?> addPdfSelfCheck(IngestCalls calls, Map<String, dynamic> engines,
    {File? memo, Duration timeout = const Duration(minutes: 2)}) async {
  try {
    final model = File((engines['embed_model'] ?? '') as String);
    final stat = model.existsSync() ? model.statSync() : null;
    final stamp = stat == null ? null : '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    Map<String, dynamic>? kept;
    try {
      if (memo != null && memo.existsSync()) kept = (jsonDecode(memo.readAsStringSync()) as Map).cast<String, dynamic>();
    } catch (_) {}
    final hash = stamp != null && kept?['stamp'] != stamp;
    logDetail('Add PDF self-check: probing the engines${hash ? ' (hashing the model)' : ''}');
    final r = await calls('probe', {'engines': engines, 'hash_model': hash, 'load_embedder': false}).timeout(timeout);
    final m = (r['model'] as Map?)?.cast<String, dynamic>() ?? const {};
    var sha = m['sha256'] as String?;
    bool? matches = m['matches'] as bool?;
    if (hash && sha != null && memo != null) {
      try {
        await memo.parent.create(recursive: true);
        await memo.writeAsString(jsonEncode({'stamp': stamp, 'sha256': sha, 'matches': matches}));
      } catch (_) {}
    } else if (!hash && kept != null) {
      sha ??= kept['sha256'] as String?;
      matches ??= kept['matches'] as bool?;
    }
    final p = (r['pdfium'] as Map?)?.cast<String, dynamic>() ?? const {};
    final e = (r['embedder'] as Map?)?.cast<String, dynamic>() ?? const {};
    final c = (r['classifier'] as Map?)?.cast<String, dynamic>() ?? const {};
    String err(Map<String, dynamic> x) => x['error'] == null ? '' : ' (${x['error']})';
    logInfo('Add PDF self-check: '
        'PDFium ${p['ok'] == true ? 'loaded' : 'not loaded'} from ${p['from'] ?? '-'}, version ${p['version'] ?? '-'}${err(p)}; '
        '${e['skipped'] == true ? 'embedder not loaded at start (it loads when Add PDF runs)' : 'embedder ${e['ok'] == true ? 'loads' : 'does not load'}${err(e)}'}; '
        'model file ${m['ok'] == true ? 'there' : 'missing'}, sha256 ${sha ?? 'not checked'}${matches == null ? '' : (matches ? ' (matches)' : ' (DOES NOT MATCH)')}${err(m)}; '
        'classifier ${c['ok'] == true ? 'ok, version ${c['version']}' : 'not usable'}${err(c)}');
    return r;
  } catch (e) {
    logError('Add PDF self-check: the probe failed', error: e);
    return null;
  }
}
