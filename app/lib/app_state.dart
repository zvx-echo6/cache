import 'dart:convert';
import 'dart:io';

import 'package:cache_llama/cache_llama.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'chat/model_name.dart';
import 'files.dart';
import 'models/search_model.dart' show isSearchModelFile;
import 'theme.dart';

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

/// App-wide state: theme, models folder, the active model and the native session.
/// The model's context window, in tokens. Set on every load (the default of the native layer is the same).
const int kContextTokens = 8192;

class AppState extends ChangeNotifier {
  AppState({this.settingsDirOverride, this.modelsDirOverride});

  /// Test hooks.
  final Directory? settingsDirOverride;
  final Directory? modelsDirOverride;

  final LlamaSession session = LlamaSession();

  CacheThemeId theme = CacheThemeId.dark;

  /// The Modules screen's icons: small, three across (false, the default), or large, two across.
  bool largeModuleIcons = false;
  Directory? modelsDir;
  /// The chat models in the models folder (a search model's file is not one: see [searchModel]).
  List<ModelEntry> models = [];

  /// The search model's file, when it is in the models folder.
  ModelEntry? searchModel;

  /// The one-time question about the search model was asked (kept in the settings file).
  bool searchModelOffered = false;
  ModelEntry? active;
  ModelInfo? activeInfo;
  ModelEntry? loading;
  String? loadError;

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

  File? _settingsFile;

  bool isUnsupported(ModelEntry e) => _unsupported.contains(e.key);

  /// The model's real name, for example "Gemma 4 E2B · Q4_K_M"; the file name if not known yet.
  String displayName(ModelEntry e) => _names[e.key] ?? e.name;

  Future<void> init() async {
    final settingsDir = settingsDirOverride ?? await getApplicationSupportDirectory();
    await settingsDir.create(recursive: true);
    _settingsFile = File('${settingsDir.path}/settings.json');
    _readSettings();

    if (modelsDirOverride != null) {
      modelsDir = modelsDirOverride;
    } else {
      final base = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
          await getApplicationDocumentsDirectory();
      modelsDir = Directory('${base.path}/models');
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
          await activate(e);
          break;
        }
      }
    }
  }

  void _readSettings() {
    try {
      final f = _settingsFile!;
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _lastModelFile = j['lastModel'] as String?;
      final t = j['theme'] as String?;
      theme = CacheThemeId.values.firstWhere((x) => x.name == t, orElse: () => CacheThemeId.dark);
      largeModuleIcons = j['moduleIcons'] == 'large';
      searchModelOffered = j['searchModelOffered'] == true;
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
      final f = _settingsFile;
      if (f == null) return;
      await writeStringAtomic(f, jsonEncode({
        'lastModel': _lastModelFile,
        'theme': theme.name,
        'moduleIcons': largeModuleIcons ? 'large' : 'small',
        'unsupported': _unsupported.toList(),
        'names': _names,
        'searchModelOffered': searchModelOffered,
      }));
    } catch (_) {}
  }

  Future<void> setTheme(CacheThemeId id) async {
    theme = id;
    notifyListeners();
    await _writeSettings();
  }

  Future<void> setLargeModuleIcons(bool large) async {
    largeModuleIcons = large;
    notifyListeners();
    await _writeSettings();
  }

  Future<void> setSearchModelOffered() async {
    searchModelOffered = true;
    notifyListeners();
    await _writeSettings();
  }

  Future<void> refreshModels() async {
    final found = <ModelEntry>[];
    ModelEntry? search;
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
    loading = entry;
    loadError = null;
    notifyListeners();
    try {
      final info = await session.load(entry.path, nCtx: kContextTokens);
      final pretty = prettyModelName(info.description, fileName: entry.fileName);
      if (pretty.isNotEmpty) _names[entry.key] = pretty;
      if (!info.supportsTools) {
        _unsupported.add(entry.key);
        await _writeSettings();
        active = null;
        activeInfo = null;
        if (previous != null) {
          try {
            activeInfo = await session.load(previous.path, nCtx: kContextTokens);
            active = previous;
          } catch (_) {}
        }
      } else {
        active = entry;
        activeInfo = info;
        _lastModelFile = entry.fileName;
        await _writeSettings();
      }
      if (active?.path != previous?.path) modelGeneration++;
    } catch (e) {
      loadError = e.toString().replaceFirst('Bad state: ', '');
      active = null;
      activeInfo = null;
      modelGeneration++;
    } finally {
      loading = null;
      notifyListeners();
    }
  }

  /// Unloads the active model to free its memory. Nothing is active after it, and the next start loads no model until
  /// one is chosen again.
  Future<void> unload() async {
    if (loading != null || active == null) return;
    active = null;
    activeInfo = null;
    loadError = null;
    _lastModelFile = null;
    modelGeneration++;
    notifyListeners();
    await session.unload();
    await _writeSettings();
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
