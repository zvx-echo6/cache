import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_llama/cache_llama.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'app_fs.dart';
import 'chat/model_name.dart';
import 'files.dart';
import 'browse/web/local_files.dart' show UploadCancelled, pickLocalFile, setLeaveWarning;
import 'models/recommendations.dart' show ModelSettings, RecommendedModels;
import 'models/server_models.dart';
import 'models/search_model.dart' show isSearchModelFile;
import 'pdf/pdf_settings.dart' show pdfDarkPages;
import 'platform/bench_options.dart';
import 'platform/memory.dart';
import 'models/gguf_header.dart' show readGgufGeneralName;
import 'platform/memory_need.dart';
import 'theme.dart';
import 'video/format.dart' show formatBytes;
import 'platform/app_log.dart';
import 'platform.dart' as plat;
import 'platform/byte_units.dart';

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
  AppState({
    this.settingsDirOverride,
    this.modelsDirOverride,
    Future<MemoryReading?> Function()? memory,
    Future<BenchOptions> Function()? bench,
    LlamaSession? session,
    ServerModels? server,
  })  : memory = memory ?? readMemory,
        session = session ?? LlamaSession(),
        _bench = bench ?? readBenchOptions,
        _server = server ?? (plat.isWeb ? ServerModels() : null);

  /// The bench's launch options (test APK only; off everywhere else), read at each model load.
  final Future<BenchOptions> Function() _bench;

  /// The bench options of the last model load.
  BenchOptions benchOptions = BenchOptions.off;

  /// A browser: the model files are the server's (list, delete, upload); there is no models folder here.
  final ServerModels? _server;

  /// The device's free memory (a test hook; the system's reading by default).
  final Future<MemoryReading?> Function() memory;

  /// Test hooks.
  final Directory? settingsDirOverride;
  final Directory? modelsDirOverride;

  /// The native session (a test hook: a fake stands in for it).
  final LlamaSession session;

  /// The unload a [release] sent, until it is done: a load that follows waits for it, so a load never begins under an unload.
  Future<void>? _unloading;

  CacheThemeId theme = CacheThemeId.dark;

  /// Whether the person has picked a theme in Settings > Appearance (any pick, also the one already shown). Never shown on
  /// screen. While it is false the car screens follow the car's own day and night (Light by day, Dark by night), as Android
  /// for Cars' quality rule MR-1 asks by default; once true they always show [theme] (car_overlay.dart, carTheme). A settings
  /// file from before this flag counts as picked, whatever theme it holds; only a new install (no settings file) starts unset.
  bool themeChosen = false;

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

  /// True while the start or wake memory gate holds the chosen model back (it needs more than the memory free then); false once a
  /// model loads (or is tried), is unloaded, or another is chosen. [heldNeedMb] and [heldFreeMb] are the gate's two numbers.
  bool heldForMemory = false;
  int? heldNeedMb;
  int? heldFreeMb;

  void _clearHeld() {
    heldForMemory = false;
    heldNeedMb = null;
    heldFreeMb = null;
  }

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

  /// The same models' plain names, without the quantisation label ("Gemma 4 E2B"), set at the same load.
  final Map<String, String> _plainNames = {};
  String? _lastModelFile;

  /// 0..1 while a file is being copied into the models folder, else null.
  double? copyProgress;
  String? copyName;

  /// Bumped when the active model changes so the chat can start fresh.
  int modelGeneration = 0;

  AppFs? _fs;
  static const String _settingsName = 'settings.json';

  bool isUnsupported(ModelEntry e) => _unsupported.contains(e.key);

  /// The quantisation label ("Q4_K_M") of each model loaded before, by [ModelEntry.key], set at the same load.
  final Map<String, String> _labels = {};

  /// The name the recommended list gives this file ("Gemma 4 E2B · tuned for Cache"); null for a file the list does not name, or
  /// while the list is not known (or this is not set).
  String? Function(ModelEntry e)? recommendedName;

  RecommendedModels? _followed;

  /// Follows [list]: a model it names is a recommended one and shows the list's name; a load waits for the list to be read before it
  /// names the model; names are drawn again when the list arrives; and the built-in copy is read now (not the network), so a model
  /// that is only resting is named from the list too.
  void followRecommended(RecommendedModels list) {
    _followed?.removeListener(_listArrived);
    _followed = list;
    isRecommended = (e) => list.isRecommendedFile(e.fileName);
    recommendedName = (e) => list.nameOfFile(e.fileName);
    recommendedReady = list.ready;
    list.addListener(_listArrived);
    unawaited(list.loadBuiltIn());
  }

  void _listArrived() => notifyListeners();

  @override
  void dispose() {
    _followed?.removeListener(_listArrived);
    super.dispose();
  }

  /// The model's name on screen. A recommended model shows its name from the recommended list, so two files that llama.cpp
  /// describes alike (the stock and the uncensored E2B) are told apart; any other shows its real name, for example
  /// "SmolLM2 135M Instruct · Q4_0" (from its own metadata once loaded); the file name if not known yet.
  String displayName(ModelEntry e) => recommendedName?.call(e) ?? _names[e.key] ?? e.name;

  /// The model's plain name, without the quantisation label ("Gemma 4 E2B"; a non-recommended model's general.name): the stored one,
  /// else the stored full name, else the file name. It never carries the recommended list's name.
  String plainName(ModelEntry e) => _plainNames[e.key] ?? _names[e.key] ?? e.name;

  /// The name the Ask header, its model menu and the one-line Settings row show: the short name. Change this one line to switch them.
  String headerName(ModelEntry e) => plainName(e);

  /// The quantisation label to show with [e]'s size: only a recommended model has one, and only when its name from the list does not
  /// already end with it ("Gemma 4 E4B · Q4_K_M" needs none). It is the one read when the model was loaded, else the one in its file
  /// name; null when neither has it.
  String? shownQuant(ModelEntry e) {
    final name = recommendedName?.call(e);
    if (name == null) return null;
    final q = _labels[e.key] ?? quantFromFileName(e.fileName);
    return q == null || name.endsWith(q) ? null : q;
  }

  /// The line under a model's name: its size ("3.2 GB"), and for a recommended model the quantisation after it ("3.2 GB · Q4_K_M").
  String sizeLine(ModelEntry e) {
    final q = shownQuant(e);
    return q == null ? formatBytes(e.size) : '${formatBytes(e.size)} · $q';
  }

  /// The settings a model carries in the recommended list (by its file), applied when it loads; null: none known.
  ModelSettings? Function(ModelEntry e)? settingsFor;

  /// Whether the recommended list names this file (by file name): true or false once the list is known, null while it is not. A
  /// recommended model is shown by its name from the list ([recommendedName]; the description's name is only what is kept stored); any
  /// other is named by its file's own `general.name`; while it is unknown (or this is not set) the description's name is kept, so a
  /// wrong name is never stored.
  bool? Function(ModelEntry e)? isRecommended;

  /// Completes when the recommended list has been read; a load waits for it before it names the model.
  Future<void> Function()? recommendedReady;

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
          // The chat model is never loaded at start (owner, 2026-11-13): it is the most memory Cache holds by far, and most starts
          // (the car's, a map, the library) never ask it anything. It rests, still the chosen model, and loads when Ask opens
          // ([wake], under the memory gate), or by Ask's own Load button.
          logInfo('Model not loaded at start: it loads when Ask opens');
          resting = e;
          notifyListeners();
          break;
        }
      }
    }
  }

  /// Reads settings.json again (a change from a linked device was applied to the file on the server) and tells listeners. Nothing is
  /// written, and the model is not loaded or changed: the chosen model's name is read as the file has it.
  Future<void> reload() async {
    if (_fs == null) return;
    await _readSettings();
    notifyListeners();
  }

  Future<void> _readSettings() async {
    try {
      final text = await _fs!.readString(AppRoot.support, _settingsName);
      if (text == null) return;
      final j = jsonDecode(text) as Map<String, dynamic>;
      _lastModelFile = j['lastModel'] as String?;
      final t = j['theme'] as String?;
      theme = CacheThemeId.values.firstWhere((x) => x.name == t, orElse: () => CacheThemeId.dark);
      // A settings file from before the flag counts as picked, whatever theme it holds: only a new install (no file) starts
      // with the car's day and night.
      themeChosen = j.containsKey('themeChosen') ? j['themeChosen'] == true : true;
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
      _plainNames
        ..clear()
        ..addAll(((j['plainNames'] as Map?) ?? const {}).cast<String, String>());
      _labels
        ..clear()
        ..addAll(((j['labels'] as Map?) ?? const {}).cast<String, String>());
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
        'themeChosen': themeChosen,
        'moduleIcons': largeModuleIcons ? 'large' : 'small',
        'pdfDarkPages': darkPdfPages,
        'modelDeclined': modelDeclined,
        'unsupported': _unsupported.toList(),
        'names': _names,
        'plainNames': _plainNames,
        'labels': _labels,
      }));
    } catch (_) {}
  }

  /// The person picked [id] in Settings > Appearance: it is the theme, and it is marked as picked ([themeChosen]).
  Future<void> chooseTheme(CacheThemeId id) async {
    themeChosen = true;
    await setTheme(id);
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
    if (_server != null) return _refreshServerModels();
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

  /// A browser: the chat models on the server.
  Future<void> _refreshServerModels() async {
    try {
      final found = [
        for (final m in await _server!.chatModels()) ModelEntry(path: m.id, size: m.size),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      models = found;
      if (failed != null && !found.any((m) => m.path == failed!.path)) {
        failed = null;
        failure = null;
        loadError = null;
      }
    } on ServerModelsException catch (e) {
      logInfo('The server\'s chat models could not be read', detail: e.message);
    }
    notifyListeners();
  }

  /// Deletes a model file from the models folder. The model in use (or one being loaded) is kept: false.
  Future<bool> deleteModel(ModelEntry entry) async {
    if (loading != null || active?.path == entry.path) return false;
    if (_server != null) {
      try {
        await _server.deleteFile(entry.fileName);
      } on ServerModelsException catch (e) {
        // the server also keeps the model it has loaded, which another tab may have chosen
        loadError = 'Could not delete the file: ${e.message}';
        notifyListeners();
        return false;
      }
      await refreshModels();
      return true;
    }
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
    _clearHeld();
    loading = entry;
    loadError = null;
    notifyListeners();
    try {
      await _unloading;
      final own = settingsFor?.call(entry) ?? ModelSettings.none;
      final sw = Stopwatch()..start();
      logInfo('Model loads (${mbOf(entry.size)} MB); ${memoryNow()}', detail: entry.fileName);
      final info = await _loadModel(entry.path, own.nCtx ?? kContextTokens);
      logInfo('Model loaded in ${sw.elapsedMilliseconds} ms; ${await memorySnapshot()}; ${mappedFileSummary(entry.path) ?? ''}', detail: entry.fileName);
      if (info.weights != null) logInfo('Model weights: ${info.weights} (${info.weightsReason ?? ''})');
      try {
        await recommendedReady?.call();
      } catch (_) {}
      // Only a model the list is known not to name takes its own name; unknown counts as recommended (the name as before).
      final recommended = isRecommended?.call(entry) ?? true;
      // A browser's model is the server's: it sends the file's name in the load answer. On a device the file is read here (only the
      // header's pairs up to the name), and only for a model that will use it.
      final ownName = recommended ? null : (info.generalName ?? (kIsWeb ? null : readGgufGeneralName(entry.path)));
      final parts = modelNameParts(info.description, fileName: entry.fileName, generalName: ownName, recommended: recommended);
      if (parts != null) {
        _names[entry.key] = parts.label == null ? parts.name : '${parts.name} · ${parts.label}';
        _plainNames[entry.key] = parts.name;
        if (parts.label != null) _labels[entry.key] = parts.label!;
      }
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
    benchDateOffsetDays = benchOptions.dateOffsetDays;
    benchEmbedThreads = benchOptions.embedThreads;
    if (benchOptions.embedThreads != 0) logInfo('Bench options: embed_threads=${benchOptions.embedThreads}');
    if (benchOptions.dateOffsetDays != 0) logInfo('Bench options: date_offset_days=${benchOptions.dateOffsetDays}');
    if (benchOptions.ubatch != 0) logInfo('Bench options: cache_ubatch=${benchOptions.ubatch}');
    return session.load(path, nCtx: nCtx, repackWeights: kRepackChatWeightsForMeasurement, prefixDir: prefixDir, prereadMbps: benchOptions.prereadMbps, nUbatch: benchOptions.ubatch);
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
    _clearHeld();
    notifyListeners();
    await _writeSettings();
    return true;
  }

  /// Unloads the active model to free its memory. Nothing is active after it, and the next start loads no model until
  /// one is chosen again.
  Future<void> unload() async {
    final was = active, wasInfo = activeInfo;
    if (loading != null || was == null) return;
    resting = null;
    _clearHeld();
    active = null;
    activeInfo = null;
    loadError = null;
    failed = null;
    failure = null;
    _lastModelFile = null;
    modelGeneration++;
    notifyListeners();
    final u = session.unload();
    _unloading = u; // a load that follows waits for it, as after release()
    try {
      await u;
    } on StateError catch (e) {
      // A browser: the server could not free its model, so it is still loaded there. The page says so rather than the opposite.
      active = was;
      activeInfo = wasInfo;
      loadError = 'Could not unload the model: ${e.message}';
      modelGeneration++;
      notifyListeners();
      return;
    } finally {
      if (identical(_unloading, u)) _unloading = null;
    }
    logInfo('Model unloaded; ${await memorySnapshot()}');
    await _writeSettings();
  }

  /// Lets the model go from memory, keeping it the chosen one ([resting]): Android said memory is short. It loads again when Ask
  /// opens ([wake]). Not while one loads.
  Future<void> release() async {
    final a = active;
    if (loading != null || a == null) return;
    resting = a;
    _clearHeld();
    active = null;
    activeInfo = null;
    modelGeneration++;
    notifyListeners();
    final u = session.unload();
    _unloading = u;
    try {
      await u;
    } finally {
      if (identical(_unloading, u)) _unloading = null;
    }
    // Whether the model's file is still mapped, and the memory once the allocator has had time to give pages back (measurement:
    // the reading right after the unload can lag).
    final mapped = mappedFileSummary(a.path);
    final freed = freedMemoryNote(session.lastFreeReport);
    if (mapped != null || freed != null) logInfo('Model released: ${[?mapped, ?freed].join('; ')}');
    if (mapped != null && !Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(Future<void>.delayed(const Duration(seconds: 15), () async {
        logInfo('Model released 15 s ago: ${mappedFileSummary(a.path) ?? ''}; ${await memorySnapshot()}');
      }));
    }
  }

  /// What [e] needs in memory while it answers ([memoryNeedForFile]: the header's tensors with the lazy per-layer table left out,
  /// the f16 KV cache at the model's context size, and the compute reserve).
  ///
  /// Read once per run for a file: the result is kept by (path, length, modified time, nCtx), so the start and every wake after it do
  /// not read the header (about 16 MB and a 262,144-entry skip, on this isolate) again; a file that changed is read again.
  Future<MemoryNeed?> needOf(ModelEntry e) async {
    final nCtx = settingsFor?.call(e)?.nCtx ?? kContextTokens;
    String? key;
    try {
      final st = File(e.path).statSync();
      if (st.type != FileSystemEntityType.notFound) key = '${e.path}|${st.size}|${st.modified.microsecondsSinceEpoch}|$nCtx';
    } catch (_) {}
    if (key != null && _needCache.containsKey(key)) return _needCache[key];
    try {
      final sw = Stopwatch()..start();
      final need = await memoryNeedReader(e.path, nCtx: nCtx, fallbackBytes: e.size);
      logInfo('Model memory need: header read in ${sw.elapsedMilliseconds} ms (cached after)');
      if (key != null) _needCache[key] = need;
      return need;
    } catch (_) {
      return null;
    }
  }

  final Map<String, MemoryNeed?> _needCache = {};

  /// Reads a model's memory need from its file (a test hook: a counter stands in for the file read).
  @visibleForTesting
  Future<MemoryNeed?> Function(String path, {int nCtx, int? fallbackBytes}) memoryNeedReader = memoryNeedForFile;

  /// Loads the [resting] model again (Ask opened, or its question was sent). Gated as the load at start is: when the model needs
  /// more than the memory free now ([memory]), it stays resting (Ask shows "No model is loaded" with its Load button), and the log
  /// says why. [force] is the person's own tap on that button: it loads whatever the room.
  Future<void> wake({bool force = false}) async {
    final r = resting;
    if (r == null || active != null || loading != null) return;
    // A release in progress finishes first (and the memory it frees is there to be read below).
    await _unloading;
    if (resting != r || active != null || loading != null) return;
    if (!force) {
      final room = await memory();
      final need = room == null ? null : await needOf(r);
      if (room != null && need != null && need.total > room.room) {
        logInfo('Model not loaded on wake: it needs about ${mbOf(need.total)} MB, $room');
        heldForMemory = true;
        heldNeedMb = mbOf(need.total);
        heldFreeMb = mbOf(room.room);
        notifyListeners();
        return;
      }
      // the answer to the read above may have come after another load began
      if (resting != r || active != null || loading != null) return;
    }
    await activate(r);
  }

  /// Lets the user pick a file and copies it into the models folder, reporting progress.
  /// Returns the new entry, or null if cancelled.
  Future<ModelEntry?> pickAndCopy() async {
    // Straight from the tap: a browser opens its file chooser only then.
    if (_server != null) return _pickAndUpload(_server);
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

  /// A browser: the chosen file goes to the server's models folder as it is read from the disk, with the same progress line.
  Future<ModelEntry?> _pickAndUpload(ServerModels server) async {
    final picked = await pickLocalFile(accept: const ['.gguf']);
    if (picked == null) return null;
    copyName = picked.name;
    copyProgress = 0;
    loadError = null;
    notifyListeners();
    setLeaveWarning(true);
    try {
      await server.upload(picked, picked.name, (sent, total) {
        copyProgress = total == 0 ? 1.0 : sent / total;
        notifyListeners();
      });
    } on ServerModelsException catch (e) {
      loadError = 'Could not copy the file: ${e.message}';
    } on UploadCancelled {
      loadError = null;
    } finally {
      setLeaveWarning(false);
      copyProgress = null;
      copyName = null;
    }
    await refreshModels();
    notifyListeners();
    for (final m in models) {
      if (m.fileName == picked.name) return m;
    }
    return null;
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
