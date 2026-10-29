import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../files.dart';
import '../settings/data_policy.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import 'opds.dart';
import 'zim_download.dart';

enum TransferPhase {
  /// Not started: the phone is on mobile data and downloads on mobile data are off. "Download anyway" starts it.
  blockedByMobileData,
  starting,
  downloading,
  verifying,
  adding,
  failed,
}

/// One ZIM being downloaded (or waiting to).
class ZimTransfer {
  ZimTransfer(this.entry, {this.replaces});

  final CatalogEntry entry;

  /// The installed ZIM this one will replace once it is downloaded and indexed (an update).
  final ZimFile? replaces;
  TransferPhase phase = TransferPhase.starting;
  int done = 0;
  int total = 0;
  String? error;
  CancelToken? token;

  /// Ends once the download loop is over and has closed the partial file; null while it has not started.
  Future<void>? loop;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

/// The Browse tab's state: the Kiwix catalogue being browsed, the downloads, the updates found, and the
/// one small setting the Browse tab has (language).
class BrowseState extends ChangeNotifier {
  BrowseState({
    required this.sources,
    KiwixCatalog? catalog,
    ZimDownloader? downloader,
    this.policy,
    this.libraries,
    this.settingsDirOverride,
    Future<Uint8List?> Function(Uri url)? iconFetch,
    String? phoneLanguage,
  }) : catalog = catalog ?? KiwixCatalog(),
       downloader = downloader ?? ZimDownloader(),
       _iconFetch = iconFetch ?? _fetchIcon,
       // ignore: prefer_initializing_formals
       _phoneLanguage = phoneLanguage {
    sources.addListener(_onSources);
  }

  final SourcesState sources;
  final KiwixCatalog catalog;
  final ZimDownloader downloader;
  /// The mobile data rule (Settings > Storage and data); null: no rule.
  final DataPolicy? policy;

  /// The libraries on the device (the Library screen's Libraries row); null leaves the row out.
  final LibrariesState? libraries;
  final Directory? settingsDirOverride;
  final Future<Uint8List?> Function(Uri url) _iconFetch;
  final String? _phoneLanguage;

  File? _file;

  /// A `zim:` address a citation asked to open; the Browse tab takes it and clears it.
  String? requestedAddress;

  /// Asks the Browse tab to open the article at [address].
  void openAddress(String address) {
    requestedAddress = address;
    notifyListeners();
  }

  // ---- settings

  /// The catalogue language filter (ISO 639-3); empty means all languages.
  String language = 'eng';

  /// Files that replace older ones: the new file's name -> the old file's path. Kept across restarts so an
  /// update finishes (the old file goes) even if the app is closed while the new one is indexed.
  final Map<String, String> _replacements = {};

  Future<void> init() async {
    final dir = settingsDirOverride ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File('${dir.path}/browse.json');
    var hadLanguage = false;
    try {
      if (_file!.existsSync()) {
        final j = (jsonDecode(_file!.readAsStringSync()) as Map)
            .cast<String, dynamic>();
        if (j['language'] is String) {
          language = j['language'] as String;
          hadLanguage = true;
        }
        for (final e in ((j['replacements'] as Map?) ?? const {}).entries) {
          _replacements[e.key as String] = e.value as String;
        }
      }
    } catch (_) {
      // A damaged file is ignored; defaults apply.
    }
    if (!hadLanguage) {
      language = catalogLanguageFor(
        _phoneLanguage ?? ui.PlatformDispatcher.instance.locale.languageCode,
      );
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final f = _file;
      if (f == null) return;
      await writeStringAtomic(
        f,
        jsonEncode({
          'language': language,
          'replacements': _replacements,
        }),
      );
    } catch (_) {}
  }

  // ---- the catalogue

  List<CatalogCategory> categories = const [];
  List<CatalogLanguage> languages = const [];
  String query = '';
  String? category;
  String? tag;
  final List<CatalogEntry> entries = [];
  int total = 0;
  bool loading = false;
  String? catalogError;
  int _generation = 0;
  bool _facetsLoaded = false;

  /// Reads the categories and languages once.
  Future<void> loadFacets() async {
    if (_facetsLoaded) return;
    try {
      final r = await Future.wait([catalog.categories(), catalog.languages()]);
      categories = r[0] as List<CatalogCategory>;
      languages = r[1] as List<CatalogLanguage>;
      _facetsLoaded = true;
      notifyListeners();
    } on CatalogException catch (e) {
      catalogError = e.message;
      notifyListeners();
    }
  }

  /// Changes what is shown and reads the first page again. Pass [clearCategory] to remove the category.
  Future<void> setFilter({
    String? query,
    String? category,
    bool clearCategory = false,
    String? tag,
    bool clearTag = false,
    String? language,
  }) async {
    if (query != null) this.query = query;
    if (category != null) this.category = category;
    if (clearCategory) this.category = null;
    if (tag != null) this.tag = tag;
    if (clearTag) this.tag = null;
    if (language != null) {
      this.language = language;
      await _save();
    }
    await loadFirstPage();
  }

  Future<void> loadFirstPage() async {
    final gen = ++_generation;
    entries.clear();
    total = 0;
    loading = true;
    catalogError = null;
    notifyListeners();
    try {
      final p = await catalog.entries(
        query: query,
        language: language,
        category: category,
        tag: tag,
      );
      if (gen != _generation) return;
      entries.addAll(p.entries);
      total = p.total;
    } on CatalogException catch (e) {
      if (gen != _generation) return;
      catalogError = e.message;
    } finally {
      if (gen == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  bool get hasMore => entries.isNotEmpty && entries.length < total;

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    final gen = _generation;
    loading = true;
    notifyListeners();
    try {
      final p = await catalog.entries(
        query: query,
        language: language,
        category: category,
        tag: tag,
        start: entries.length,
      );
      if (gen != _generation) return;
      entries.addAll(p.entries);
      total = p.total;
    } on CatalogException catch (e) {
      if (gen == _generation) catalogError = e.message;
    } finally {
      if (gen == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  // ---- what is installed

  /// The installed ZIM that is this entry (same name and variant, any release), or null.
  ZimFile? installedFor(CatalogEntry e) {
    for (final z in sources.zims) {
      final o = sources.originOf(z);
      if (o != null && o.name == e.name && o.flavour == e.flavour) return z;
    }
    return null;
  }

  // ---- updates

  /// Newer releases of installed ZIMs, by the installed file's path.
  final Map<String, CatalogEntry> updates = {};
  bool checkingUpdates = false;
  String? updateError;

  /// The last update check did not run because the phone is on mobile data and updates on mobile data are off.
  bool updatesBlocked = false;
  DateTime? lastUpdateCheck;

  /// Asks the catalogue whether a newer dated release exists for each installed ZIM (same name and variant).
  Future<void> checkUpdates({bool anyway = false}) async {
    if (checkingUpdates) return;
    updatesBlocked = false;
    if (!anyway && policy != null && await policy!.blocksUpdate()) {
      updatesBlocked = true;
      updateError = const MobileDataBlocked(updates: true).message;
      notifyListeners();
      return;
    }
    checkingUpdates = true;
    updateError = null;
    notifyListeners();
    try {
      final found = <String, CatalogEntry>{};
      final seen = <String, List<CatalogEntry>>{};
      for (final z in sources.zims) {
        final o = sources.originOf(z);
        if (o == null) continue;
        final list = seen[o.name] ??= (await catalog.entries(
          name: o.name,
          count: 20,
        )).entries;
        CatalogEntry? best;
        for (final e in list) {
          if (o.isOlderThan(e) &&
              (best == null || e.release.compareTo(best.release) > 0)) {
            best = e;
          }
        }
        if (best != null) found[z.path] = best;
      }
      updates
        ..clear()
        ..addAll(found);
      lastUpdateCheck = DateTime.now();
    } on CatalogException catch (e) {
      updateError = e.message;
    } finally {
      checkingUpdates = false;
      notifyListeners();
    }
  }

  /// Downloads the newer release; the old file stays until the new one is indexed.
  Future<void> update(ZimFile z) async {
    final e = updates[z.path];
    if (e == null) return;
    await download(e, replaces: z);
  }

  // ---- downloads

  final Map<String, ZimTransfer> transfers = {};

  /// How many downloads of each entry have been started, so a cancel can tell that a new one has taken over the file.
  final Map<String, int> _starts = {};

  /// The download loop of each entry that last ran.
  final Map<String, Future<void>> _loops = {};

  /// Downloads [entry]. With [replaces] it is an update: the old ZIM goes only after the new one is ready.
  Future<void> download(
    CatalogEntry entry, {
    ZimFile? replaces,
    bool allowMobile = false,
  }) async {
    final existing = transfers[entry.id];
    if (existing != null &&
        existing.phase != TransferPhase.failed &&
        existing.phase != TransferPhase.blockedByMobileData) {
      return;
    }
    final t = ZimTransfer(entry, replaces: replaces)..total = entry.size;
    transfers[entry.id] = t;
    _starts[entry.id] = (_starts[entry.id] ?? 0) + 1;
    notifyListeners();
    if (!allowMobile && policy != null && await policy!.blocksDownload()) {
      t.phase = TransferPhase.blockedByMobileData;
      notifyListeners();
      return;
    }
    final token = t.token = CancelToken();
    final part = File('${sources.partialDir.path}/${entry.fileName}.part');
    final previous = _loops[entry.id];
    final loop = Completer<void>();
    _loops[entry.id] = t.loop = loop.future;
    try {
      // A cancelled download of this entry may still be closing the file; this one continues the file after that.
      if (previous != null) await previous;
      await part.parent.create(recursive: true);
      t.phase = TransferPhase.downloading;
      notifyListeners();
      final r = await downloader.download(
        url: entry.downloadUrl,
        part: part,
        sha256Url: entry.sha256Url,
        md5Url: entry.md5Url,
        cancel: token,
        onProgress: (d, tot) {
          t.done = d;
          t.total = tot;
          notifyListeners();
        },
        onVerifying: () {
          t.phase = TransferPhase.verifying;
          notifyListeners();
        },
      );
      t.phase = TransferPhase.adding;
      notifyListeners();
      Uint8List? icon;
      if (entry.iconUrl != null) icon = await _iconFetch(entry.iconUrl!);
      if (replaces != null) {
        _replacements[entry.fileName] = replaces.path;
        await _save();
      }
      await sources.installDownloaded(
        r.file,
        entry: entry,
        icon: icon,
        fileName: entry.fileName,
      );
      if (transfers[entry.id] == t) transfers.remove(entry.id);
      updates.remove(replaces?.path);
      notifyListeners();
      _onSources();
    } on DownloadException catch (e) {
      if (e.code == 'cancelled') {
        // Only this transfer: a new download of the entry may already be in its place.
        if (transfers[entry.id] == t) transfers.remove(entry.id);
      } else {
        t.phase = TransferPhase.failed;
        t.error = e.message;
      }
      notifyListeners();
    } catch (e) {
      t.phase = TransferPhase.failed;
      t.error = 'Could not finish the download: $e';
      notifyListeners();
    } finally {
      loop.complete();
      if (_loops[entry.id] == loop.future) _loops.remove(entry.id);
    }
  }

  /// Stops a download and throws away the partly downloaded file.
  Future<void> cancel(CatalogEntry entry) async {
    final t = transfers[entry.id];
    if (t == null) return;
    t.token?.cancel();
    transfers.remove(entry.id);
    notifyListeners();
    final started = _starts[entry.id];
    // The download loop notices the cancel and closes the file. The file goes once it has, and only if no new download of
    // this entry was started meanwhile (that one continues the file).
    await t.loop;
    if (_starts[entry.id] != started) return;
    try {
      final part = File('${sources.partialDir.path}/${entry.fileName}.part');
      if (part.existsSync()) part.deleteSync();
    } catch (_) {}
  }

  void dismissFailure(CatalogEntry entry) {
    final t = transfers[entry.id];
    if (t != null && t.phase == TransferPhase.failed) {
      transfers.remove(entry.id);
      notifyListeners();
    }
  }

  // ---- finishing an update

  bool _removing = false;

  /// An update is finished when the new ZIM's index is ready: then the old file and its index are removed.
  void _onSources() {
    if (_replacements.isEmpty || _removing) return;
    final done = <String>[];
    final toRemove = <ZimFile>[];
    for (final e in _replacements.entries.toList()) {
      final fresh = sources.zims.where((z) => z.fileName == e.key).firstOrNull;
      if (fresh == null) {
        // The new file is gone (removed by hand): nothing to replace any more.
        done.add(e.key);
        continue;
      }
      if (sources.isReadyPath(fresh.path)) {
        final old = sources.zims.where((z) => z.path == e.value).firstOrNull;
        if (old != null && old.path != fresh.path) toRemove.add(old);
        done.add(e.key);
      }
    }
    if (done.isEmpty) return;
    _removing = true;
    () async {
      try {
        for (final z in toRemove) {
          await sources.remove(z);
        }
        for (final k in done) {
          _replacements.remove(k);
        }
        await _save();
      } finally {
        _removing = false;
      }
    }();
  }

  /// Whether this ZIM is the old half of an update that is waiting for the new one to be indexed.
  bool isBeingReplaced(ZimFile z) => _replacements.containsValue(z.path);

  @override
  void dispose() {
    sources.removeListener(_onSources);
    for (final t in transfers.values) {
      t.token?.cancel();
    }
    super.dispose();
  }
}

Future<Uint8List?> _fetchIcon(Uri url) async {
  final client = HttpClient()
    ..userAgent = cacheUserAgent
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final b = BytesBuilder(copy: false);
    await for (final c in res) {
      b.add(c);
      if (b.length > 512 * 1024) return null;
    }
    return b.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
