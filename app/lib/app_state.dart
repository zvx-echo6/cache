import 'dart:convert';
import 'dart:io';

import 'package:cache_llama/cache_llama.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_fs.dart';
import 'chat/model_name.dart';
import 'files.dart';
import 'models/recommendations.dart' show ModelSettings;
import 'models/search_model.dart' show isSearchModelFile;
import 'pdf/pdf_settings.dart' show pdfDarkPages;
import 'platform/bench_options.dart';
import 'platform/memory.dart';
import 'theme.dart';
import 'platform/app_log.dart';
import 'platform.dart' as plat;

/// One model file in the models folder.
class ModelEntry {
  ModelEntry({required this.path, required this.size});

  final String path;
  final int size;

  String get fileName => path.split(RegExp(r'[\\/]')).last;
  String get name => fileName.replaceFirst(RegExp(r'\.gguf$', caseSensitive: false), '');

  /// Identifies this exact file for the "not supported" memory.
  String get key => '$fileName|$size';
}

/// Why a model that is on this device did not load (Ask shows the fix for it).
enum LoadFailure {
  /// The device has too little memory for it.
  tooBig,

  /// The file did not open as a model: it may be damaged.
  damaged,

  /// Any other reason (the error says which).
  other,
}

/// The failure a load error from the native layer stands for. The native layer's own messages (cache_llama.cpp cl_load), not
/// anything a person typed.
LoadFailure loadFailureOf(String error) {
  if (error.startsWith('cannot create context')) return LoadFailure.tooBig;
  if (error.startsWith('cannot load model')) return LoadFailure.damaged;
  return LoadFailure.other;
}

/// App-wide state: theme, models folder, the active model and the native session.
/// The model's context window, in tokens. Set on every load (the default of the native layer is the same).
const int kContextTokens = 8192;

/// The folder under app support where the native layer keeps the saved prompt prefix (at most two files).
const String kPromptPrefixDir = 'prompt-prefix';

/// Android, for measurement builds only: true repacks the chat model's CPU weights (an anonymous copy) instead of keeping them
/// file-backed in the mmap, the default. On a Galaxy S22 the copy cost about a GB of memory, pushed the app into swap and gave no
/// speed, so a released build keeps this false; nothing chooses it at run time.
const bool kRepackChatWeightsForMeasurement = false;

class AppState extends ChangeNotifier {
  AppState({this.settingsDirOverride, this.modelsDirOverride, Future<MemoryReading?> Function()? memory, Future<BenchOptions> Function()? bench})
      : memory = memory ?? readMemory,
        _bench = bench ?? readBenchOptions;

  /// The bench's launch options (test APK only; off everywhere else), read at each model load.
  final Future<BenchOptions> Function() _bench;

  /// The options of the last model load: [BenchOptions.dropCaches] tells Ask's focus to drop the image and tile caches.
  BenchOptions benchOptions = BenchOptions.off;

  /// The device's free memory (a test hook; the system's reading by default).
  final Future<MemoryReading?> Function() memory;

  /// Test hooks.
  final Directory? settingsDirOverride;
  final Directory? modelsDirOverride;

  final LlamaSession session = LlamaSession();

  CacheThemeId theme = CacheThemeId.dark;

  /// The Modules screen's icons: small, three across (false, the default), or large, two across.
  bool largeModuleIcons = false;

  /// Settings > Appearance > "Dark pages": PDF pages drawn light on dark in a dark theme (off: dimmed). Off by default.
  bool darkPdfPages = false;
  Directory? modelsDir;
  /// The chat models in the models folder (a search model's file is not one: see [searchModel]).
  List<ModelEntry> models = [];

  /// The search model's file, when it is in the models folder.
  ModelEntry? searchModel;

  ModelEntry? active;
  ModelInfo? activeInfo;
  ModelEntry? loading;

  /// The chosen model, not in memory now so the phone has room: at start there was not enough free memory for it, or it was
  /// let go when Android said memory was short. It loads again when Ask opens ([wake]); it stays the chosen model.
  ModelEntry? resting;
  String? loadError;

  /// The model whose last load failed, and why; null once a model loads, is unloaded or that file is deleted.
  ModelEntry? failed;
  LoadFailure? failure;

  /// Ask is available: a chat model is on this device (loaded or not). With none, Cache is search only: Ask leaves the bar and is
  /// greyed in Modules. Before the models folder has been read the answer is not known yet and Ask stays as it was.
  bool get askAvailable => !started || models.isNotEmpty;

  /// "Not now" on Set up Cache's model row: the person chose search only. Kept until undone; a model on the device overrides it.
  bool modelDeclined = false;

  /// True once the settings and the models folder have been read (a model may still be loading after this).
  bool started = false;

  /// Set when the models folder cannot be read (for example the folder belongs to another user).
  String? modelsError;
  final Set<String> _unsupported = {};

  /// Real model names (from the model's own metadata), by [ModelEntry.key]. Known once a model has
  /// been loaded; until then the file name is shown.
  final Map<String, String> _names = {};
  String? _lastModelFile;

  /// 0..1 while a file is being copied into the models folder, else null.
  double? copyProgress;
  String? copyName;

  /// Bumped when the active model changes so the chat can start fresh.
  int modelGeneration = 0;

  AppFs? _fs;
  static const String _settingsName = 'settings.json';

  bool isUnsupported(ModelEntry e) => _unsupported.contains(e.key);

  /// The model's real name, for example "Gemma 4 E2B · Q4_K_M"; the file name if not known yet.
  String displayName(ModelEntry e) => _names[e.key] ?? e.name;

  /// The settings a model carries in the recommended list (by its file), applied when it loads; null: none known.
  ModelSettings? Function(ModelEntry e)? settingsFor;

  /// The settings of the model loaded now (none for a model the list does not name).
  ModelSettings activeSettings = ModelSettings.none;

  Future<void> init() async {
    final fs = createAppFs(supportOverride: settingsDirOverride);
    await fs.mkdir(AppRoot.support, '');
    _fs = fs;
    await _readSettings();

    if (plat.isWeb) {
      // No model files here: the browser runs no model itself. The chat models are the ones on the server (GET /api/llm/models,
      // server/docs/llm-protocol.md); a model's id is the "path" LlamaSession.load takes on the web. When the server has none
      // (or cannot be asked) the list stays empty and nothing is wrong.
      await refreshModels();
      try {
        final r = await http.get(Uri.parse('/api/llm/models?v=1'));
        if (r.statusCode == 200) {
          final list = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['result'] as Map)['models'] as List;
          final found = [
            for (final m in list.cast<Map>()) ModelEntry(path: m['id'] as String, size: (m['size'] as num?)?.toInt() ?? 0),
          ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          models = found;
        } else {
          logInfo('The server lists no chat models (HTTP ${r.statusCode})');
        }
      } catch (e) {
        logInfo('The server\'s chat models could not be read', detail: '$e');
      }
      started = true;
      notifyListeners();
      return;
    }
    if (modelsDirOverride != null) {
      modelsDir = modelsDirOverride;
    } else {
      modelsDir = Directory('${await appFilesPath()}/models');
    }
    try {
      await modelsDir!.create(recursive: true);
    } on FileSystemException {
      // Reported by refreshModels below.
    }
    await refreshModels();
    started = true;
    notifyListeners();

    final last = _lastModelFile;
    if (last != null) {
      for (final e in models) {
        if (e.fileName == last && !isUnsupported(e)) {
          // Loaded at start only when it fits the memory free now; else when Ask opens. A model loaded into a phone without
          // room for it makes Android kill Cache (or everything else) while it answers.
          final r = await memory();
          if (r != null && modelMemoryNeed(e.size) > r.room) {
            logInfo('Model not loaded at start: it needs about ${modelMemoryNeed(e.size) >> 20} MB, $r');
            resting = e;
            notifyListeners();
          } else {
            await activate(e);
          }
          break;
        }
      }
    }
  }

  Future<void> _readSettings() async {
    try {
      final text = await _fs!.readString(AppRoot.support, _settingsName);
      if (text == null) return;
      final j = jsonDecode(text) as Map<String, dynamic>;
      _lastModelFile = j['lastModel'] as String?;
      final t = j['theme'] as String?;
      theme = CacheThemeId.values.firstWhere((x) => x.name == t, orElse: () => CacheThemeId.dark);
      largeModuleIcons = j['moduleIcons'] == 'large';
      darkPdfPages = j['pdfDarkPages'] == true;
      modelDeclined = j['modelDeclined'] == true;
      pdfDarkPages.value = darkPdfPages;
      _unsupported
        ..clear()
        ..addAll(((j['unsupported'] as List?) ?? const []).cast<String>());
      _names
        ..clear()
        ..addAll(((j['names'] as Map?) ?? const {}).cast<String, String>());
    } catch (_) {
      // A damaged settings file is ignored; defaults apply.
    }
  }

  Future<void> _writeSettings() async {
    try {
      final fs = _fs;
      if (fs == null) return;
      await fs.writeStringAtomic(AppRoot.support, _settingsName, jsonEncode({
        'lastModel': _lastModelFile,
        'theme': theme.name,
        'moduleIcons': largeModuleIcons ? 'large' : 'small',
        'pdfDarkPages': darkPdfPages,
        'modelDeclined': modelDeclined,
        'unsupported': _unsupported.toList(),
        'names': _names,
      }));
    } catch (_) {}
  }

  Future<void> setTheme(CacheThemeId id) async {
    theme = id;
    notifyListeners();
    await _writeSettings();
  }

  Future<void> setDarkPdfPages(bool on) async {
    darkPdfPages = on;
    pdfDarkPages.value = on;
    notifyListeners();
    await _writeSettings();
  }

  /// "Not now" (true) or its Undo (false) on Set up Cache's model row.
  Future<void> setModelDeclined(bool declined) async {
    if (modelDeclined == declined) return;
    modelDeclined = declined;
    notifyListeners();
    await _writeSettings();
  }

  Future<void> setLargeModuleIcons(bool large) async {
    largeModuleIcons = large;
    notifyListeners();
    await _writeSettings();
  }

  Future<void> refreshModels() async {
    final found = <ModelEntry>[];
    ModelEntry? search;
    if (modelsDir == null) {
      models = found;
      searchModel = null;
      notifyListeners();
      return;
    }
    try {
      for (final f in modelsDir!.listSync().whereType<File>()) {
        if (f.path.toLowerCase().endsWith('.gguf')) {
          final e = ModelEntry(path: f.path, size: f.lengthSync());
          // The search model is not a chat model: it is never listed or loaded as one.
          if (isSearchModelFile(e.fileName)) {
            search = e;
          } else {
            found.add(e);
          }
        }
      }
      modelsError = null;
    } on FileSystemException {
      found.clear();
      search = null;
      modelsError = "Can't read the models folder";
    }
    found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    models = found;
    searchModel = search;
    if (failed != null && !found.any((m) => m.path == failed!.path)) {
      failed = null;
      failure = null;
      loadError = null;
    }
    notifyListeners();
  }

  /// Deletes a model file from the models folder. The model in use (or one being loaded) is kept: false.
  Future<bool> deleteModel(ModelEntry entry) async {
    if (loading != null || active?.path == entry.path) return false;
    try {
      final f = File(entry.path);
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      loadError = 'Could not delete the file: $e';
      notifyListeners();
      return false;
    }
    await refreshModels();
    return true;
  }

  /// Loads [entry] and makes it the active model. A model that cannot use tools is marked and not
  /// activated; the previous model (if any) stays active.
  Future<void> activate(ModelEntry entry) async {
    if (loading != null || isUnsupported(entry)) return;
    final previous = active;
    resting = null;
    loading = entry;
    loadError = null;
    notifyListeners();
    try {
      final own = settingsFor?.call(entry) ?? ModelSettings.none;
      final sw = Stopwatch()..start();
      logInfo('Model loads (${entry.size >> 20} MB); ${memoryNow()}', detail: entry.fileName);
      final info = await _loadModel(entry.path, own.nCtx ?? kContextTokens);
      logInfo('Model loaded in ${sw.elapsedMilliseconds} ms; ${memoryNow()}', detail: entry.fileName);
      if (info.weights != null) logInfo('Model weights: ${info.weights} (${info.weightsReason ?? ''})');
      final pretty = prettyModelName(info.description, fileName: entry.fileName);
      if (pretty.isNotEmpty) _names[entry.key] = pretty;
      if (!info.supportsTools) {
        _unsupported.add(entry.key);
        await _writeSettings();
        active = null;
        activeInfo = null;
        if (previous != null) {
          try {
            activeInfo = await _loadModel(previous.path, kContextTokens);
            active = previous;
          } catch (_) {}
        }
      } else {
        active = entry;
        failed = null;
        failure = null;
        activeInfo = info;
        activeSettings = own;
        _lastModelFile = entry.fileName;
        await _writeSettings();
      }
      if (active?.path != previous?.path) modelGeneration++;
    } catch (e) {
      loadError = e.toString().replaceFirst('Bad state: ', '');
      logError('Model did not load', error: e, detail: entry.fileName);
      failed = entry;
      failure = loadFailureOf(loadError!);
      active = null;
      activeInfo = null;
      modelGeneration++;
    } finally {
      loading = null;
      notifyListeners();
    }
  }

  /// Loads [path] into the session. On Android the CPU weights stay file-backed in the mmap (repacked only in a measurement build,
  /// [kRepackChatWeightsForMeasurement]); the native layer is also given the folder where the fixed prompt start is saved between
  /// runs (app support/[kPromptPrefixDir]).
  Future<ModelInfo> _loadModel(String path, int nCtx) async {
    String? prefixDir;
    if (!kIsWeb) {
      try {
        prefixDir = '${await appSupportPath()}/$kPromptPrefixDir';
      } catch (_) {
        // Without a folder the model loads without the saved prefix.
      }
    }
    // The bench's options come before the load: the pre-read rate is a load option (0 when the bench set nothing).
    benchOptions = await _bench();
    logInfo('Bench options: $benchOptions');
    return session.load(path, nCtx: nCtx, repackWeights: kRepackChatWeightsForMeasurement, prefixDir: prefixDir, prereadMbps: benchOptions.prereadMbps);
  }

  /// The chosen model's file name (the one Ask uses, loaded or not), or null when none is chosen.
  String? get chosenModelFile => _lastModelFile;

  /// Uses the model file [fileName] from now on, as a linked device's settings say (Settings > Sharing and sync > a device >
  /// Settings): it loads at once when a model is loaded now, else when Ask opens. False when that file is not on this device;
  /// nothing is downloaded for it.
  Future<bool> useModelFile(String? fileName) async {
    if (fileName == null) return true;
    if (_lastModelFile == fileName && (active?.fileName == fileName || resting?.fileName == fileName)) return true;
    final e = models.where((m) => m.fileName == fileName && !isUnsupported(m)).firstOrNull;
    if (e == null) return false;
    if (active != null && loading == null) {
      await activate(e);
      return active?.fileName == fileName;
    }
    _lastModelFile = fileName;
    resting = e;
    notifyListeners();
    await _writeSettings();
    return true;
  }

  /// Unloads the active model to free its memory. Nothing is active after it, and the next start loads no model until
  /// one is chosen again.
  Future<void> unload() async {
    if (loading != null || active == null) return;
    resting = null;
    active = null;
    activeInfo = null;
    loadError = null;
    failed = null;
    failure = null;
    _lastModelFile = null;
    modelGeneration++;
    notifyListeners();
    await session.unload();
    logInfo('Model unloaded; ${memoryNow()}');
    await _writeSettings();
  }

  /// Lets the model go from memory, keeping it the chosen one ([resting]): Android said memory is short. It loads again when Ask
  /// opens ([wake]). Not while one loads.
  Future<void> release() async {
    final a = active;
    if (loading != null || a == null) return;
    resting = a;
    active = null;
    activeInfo = null;
    modelGeneration++;
    notifyListeners();
    await session.unload();
  }

  /// Loads the [resting] model again (Ask opened, or its question was sent).
  Future<void> wake() async {
    final r = resting;
    if (r == null || active != null || loading != null) return;
    await activate(r);
  }

  /// Lets the user pick a file and copies it into the models folder, reporting progress.
  /// Returns the new entry, or null if cancelled.
  Future<ModelEntry?> pickAndCopy() async {
    final picked = await FilePicker.pickFile();
    if (picked == null || picked.path == null) return null;
    final src = File(picked.path!);
    try {
      return await copyIn(src, name: picked.name);
    } finally {
      // The picker's own copy of the file is not needed any more, whether the copy worked or not.
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
    }
  }

  Future<ModelEntry?> copyIn(File src, {String? name}) async {
    final fileName = name ?? src.path.split(RegExp(r'[\\/]')).last;
    final dest = File('${modelsDir!.path}/$fileName');
    // Copied under a hidden name and renamed into place once whole: a copy cut off half way is never loaded as the model,
    // nor sent to the other devices.
    final tmp = File('${modelsDir!.path}/.$fileName.import.part');
    copyName = fileName;
    copyProgress = 0;
    notifyListeners();
    try {
      final total = await src.length();
      final raf = await tmp.open(mode: FileMode.write);
      try {
        var done = 0;
        var lastReport = 0.0;
        await for (final chunk in src.openRead()) {
          await raf.writeFrom(chunk);
          done += chunk.length;
          final p = total == 0 ? 1.0 : done / total;
          if (p - lastReport >= 0.005) {
            lastReport = p;
            copyProgress = p;
            notifyListeners();
          }
        }
        // On the disk before the rename, so the real name never holds less than the whole file.
        await raf.flush();
      } finally {
        await raf.close();
      }
      await renameOver(tmp, dest.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      copyProgress = null;
      copyName = null;
      loadError = 'Could not copy the file: $e';
      notifyListeners();
      return null;
    }
    copyProgress = null;
    copyName = null;
    await refreshModels();
    // by name: the listing writes the folder's own separator ("\\" on Windows), not the "/" the path was built with
    return models.firstWhere((m) => m.fileName == fileName);
  }
}
