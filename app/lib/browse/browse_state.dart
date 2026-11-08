import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../app_fs.dart';
import '../downloads/download_row.dart' show DlMeter;
import '../settings/data_policy.dart';
import '../settings/space.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import 'opds.dart';
import 'web/device_library.dart';
import 'zim_download.dart';
import '../net/fetch.dart';
import '../platform/app_log.dart';

enum TransferPhase {
  /// Waiting for Wi-Fi: the phone is on mobile data and mobile data downloads are off. It starts by itself on Wi-Fi.
  blockedByMobileData,

  /// Paused by the person; the partly downloaded file stays and Resume continues it.
  paused,
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
    this.device,
  }) : catalog = catalog ?? KiwixCatalog(),
       downloader = downloader ?? ZimDownloader(freeSpace: usableBytesOnDisk),
       _iconFetch = iconFetch ?? _fetchIcon,
       // ignore: prefer_initializing_formals
       _phoneLanguage = phoneLanguage {
    sources.addListener(_onSources);
    // Downloads waiting for Wi-Fi start by themselves once the connection (or the switch) allows them.
    _net = policy?.probe.changes.listen((_) => _startWaiting());
    policy?.settings.addListener(_startWaiting);
    device?.addListener(notifyListeners);
  }

  /// In a browser: the Library on the device, which downloads for this tab (it goes on with the tab closed). Null on a phone.
  final DeviceLibrary? device;

  /// The transfer the device runs for [e] (waiting, running or failed), shaped as a phone's transfer, or null.
  ZimTransfer? deviceTransfer(CatalogEntry e) {
    final j = device?.jobForUrl(e.downloadUrl.toString());
    if (j == null) return null;
    return ZimTransfer(e)
      ..done = j.bytes
      ..total = j.total > 0 ? j.total : e.size
      ..phase = j.failed ? TransferPhase.failed : (j.state == 'queued' ? TransferPhase.starting : TransferPhase.downloading)
      ..error = j.failed ? deviceJobWords(j) : null;
  }

  StreamSubscription<ConnectionKind>? _net;

  Future<void> _startWaiting() async {
    final waiting = [for (final t in transfers.values) if (t.phase == TransferPhase.blockedByMobileData) t];
    if (waiting.isEmpty || policy == null || await policy!.blocksDownload()) return;
    for (final t in waiting) {
      unawaited(download(t.entry, replaces: t.replaces));
    }
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

  AppFs? _fs;

  /// A `zim:` address a citation asked to open; the Browse tab takes it and clears it.
  String? requestedAddress;

  /// The cited passage that goes with [requestedAddress] (a PDF page's quote), when the citation has one.
  String? requestedQuote;

  /// Asks the Browse tab to open the article at [address]; for a PDF entry, at its `#page=N` with [quote] highlighted.
  void openAddress(String address, {String? quote}) {
    requestedAddress = address;
    requestedQuote = quote;
    notifyListeners();
  }

  // ---- settings

  /// The catalogue language filter (ISO 639-3); empty means all languages.
  String language = 'eng';

  /// Files that replace older ones: the new file's name -> the old file's path. Kept across restarts so an
  /// update finishes (the old file goes) even if the app is closed while the new one is indexed.
  final Map<String, String> _replacements = {};

  static const String _name = 'browse.json';

  Future<void> init() async {
    final fs = createAppFs(supportOverride: settingsDirOverride);
    await fs.mkdir(AppRoot.support, '');
    _fs = fs;
    var hadLanguage = false;
    try {
      final text = await fs.readString(AppRoot.support, _name);
      if (text != null) {
        final j = (jsonDecode(text) as Map)
            .cast<String, dynamic>();
        if (j['language'] is String) {
          language = j['language'] as String;
          hadLanguage = true;
        }
        for (final e in ((j['replacements'] as Map?) ?? const {}).entries) {
          _replacements[e.key as String] = e.value as String;
        }
        for (final e in ((j['downloads'] as Map?) ?? const {}).entries) {
          if (e.value is Map) _pending[e.key as String] = (e.value as Map).cast<String, dynamic>();
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
    _restorePending();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final fs = _fs;
      if (fs == null) return;
      await fs.writeStringAtomic(
        AppRoot.support,
        _name,
        jsonEncode({
          'language': language,
          'replacements': _replacements,
          'downloads': _pending,
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

  /// How many catalogue entries were read so far (the list can hold fewer: see [inLanguage]).
  int _fetched = 0;

  /// An entry for the chosen language. Kiwix's `lang` filter also returns collections tagged with several languages that include
  /// it. A pair ("eng,jpn" for the Japanese Stack Overflow, whose pages are Japanese) is mostly the other language, so it is left
  /// out; a truly multi-language collection (three or more languages, or "mul": the TED collections, "eng,ara,spa,fra,...") has
  /// the chosen language among many and is listed. Everything stays under All languages.
  bool inLanguage(CatalogEntry e) {
    if (language.isEmpty || e.language.isEmpty) return true;
    final codes = [for (final c in e.language.split(',')) if (c.trim().isNotEmpty) c.trim()];
    if (codes.contains('mul')) return true;
    if (!codes.contains(language)) return false;
    return codes.length == 1 || codes.length >= 3;
  }

  Future<void> loadFirstPage() async {
    final gen = ++_generation;
    entries.clear();
    _fetched = 0;
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
      _fetched += p.entries.length;
      entries.addAll(p.entries.where(inLanguage));
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

  bool get hasMore => _fetched > 0 && _fetched < total;

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
        start: _fetched,
      );
      if (gen != _generation) return;
      _fetched += p.entries.length;
      entries.addAll(p.entries.where(inLanguage));
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

  DateTime? lastUpdateCheck;

  /// Asks the catalogue whether a newer dated release exists for each installed ZIM (same name and variant). An update check is small
  /// and uses any connection.
  Future<void> checkUpdates() async {
    if (checkingUpdates) return;
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

  /// The downloads not finished, kept in browse.json (entry, and the ZIM an update replaces), so one stopped by a crash, a
  /// force stop or the system comes back on the next start as a paused download with its partial file: Resume carries on.
  final Map<String, Map<String, dynamic>> _pending = {};
  bool _restored = false;

  /// The partial files of the downloads that can be carried on: Storage never offers them as leftovers to clean up. With them
  /// the partial files with no record that may still be (see [_adoptOrphans]).
  Set<String> get resumableParts => sources.zimsDir == null
      ? const {}
      : {for (final t in transfers.values) '${sources.partialDir.path}/${t.entry.fileName}.part', ..._orphans};

  /// Partial files with no record, not matched to the catalogue yet (it could not be reached): kept, tried again next start.
  final Set<String> _orphans = {};

  /// Brings back the downloads a stopped app left (once the ZIMs folder is known): each whose partial file is still there is a
  /// paused download at its size so far; one whose file is gone is forgotten.
  void _restorePending() {
    if (_restored || sources.zimsDir == null) return;
    _restored = true;
    var changed = false;
    for (final e in _pending.entries.toList()) {
      try {
        final entry = CatalogEntry.fromJson((e.value['entry'] as Map).cast<String, dynamic>());
        final part = File('${sources.partialDir.path}/${entry.fileName}.part');
        if (!part.existsSync()) {
          _pending.remove(e.key);
          changed = true;
          continue;
        }
        if (transfers.containsKey(entry.id)) continue;
        final replacesPath = e.value['replaces'] as String?;
        final replaces = replacesPath == null ? null : sources.zims.where((z) => z.path == replacesPath).firstOrNull;
        transfers[entry.id] = ZimTransfer(entry, replaces: replaces)
          ..phase = TransferPhase.paused
          ..done = part.lengthSync()
          ..total = entry.size;
      } catch (_) {
        _pending.remove(e.key);
        changed = true;
      }
    }
    if (changed) unawaited(_save());
    notifyListeners();
    unawaited(_adoptOrphans());
  }

  /// Partial ZIM files with no download record (stopped by a crash in a build that did not keep one) are adopted: a file named
  /// as Kiwix names its files ({name}_{flavour}_{YYYY-MM}.zim) is looked up in the catalogue by that name, and the entry of
  /// exactly that file comes back as a paused download at the file's size; Resume carries on from there. A file the catalogue
  /// no longer has (or not a Kiwix name) is a leftover for Storage's clean-up; while the catalogue cannot be reached it is kept.
  Future<void> _adoptOrphans() async {
    final Directory dir;
    final List<File> parts;
    try {
      dir = sources.partialDir;
      if (!dir.existsSync()) return;
      final known = {for (final t in transfers.values) '${t.entry.fileName}.part'};
      parts = [
        for (final f in dir.listSync(followLinks: false).whereType<File>())
          if (f.path.toLowerCase().endsWith('.zim.part') && !known.contains(f.uri.pathSegments.last)) f,
      ];
    } catch (_) {
      return;
    }
    if (parts.isEmpty) return;
    _orphans.addAll([for (final f in parts) f.path]);
    final byName = <String, List<CatalogEntry>>{};
    for (final f in parts) {
      final fileName = f.uri.pathSegments.last.substring(0, f.uri.pathSegments.last.length - '.part'.length);
      final o = ZimOrigin.fromFileName(fileName);
      if (o == null) {
        _orphans.remove(f.path);
        continue;
      }
      try {
        final list = byName[o.name] ??= (await catalog.entries(name: o.name, count: 30)).entries;
        final e = list.where((e) => e.fileName == fileName).firstOrNull;
        _orphans.remove(f.path);
        if (e == null || transfers.containsKey(e.id) || !f.existsSync()) continue;
        final installed = installedFor(e);
        final o2 = installed == null ? null : sources.originOf(installed);
        // the same release is already on the device: a leftover
        if (installed != null && (o2 == null || o2.release.compareTo(e.release) >= 0)) continue;
        transfers[e.id] = ZimTransfer(e, replaces: installed)
          ..phase = TransferPhase.paused
          ..done = f.lengthSync()
          ..total = e.size;
        _remember(e, installed);
        logInfo('Adopted the partial download ${e.title}: ${f.lengthSync() >> 20} of ${e.size >> 20} MB');
      } on CatalogException catch (e) {
        logInfo('A partial download is not matched yet (catalog: ${e.message}); kept', detail: fileName);
      } catch (e) {
        logError('A partial download is not matched yet; kept', error: e, detail: fileName);
      }
    }
    notifyListeners();
  }

  void _remember(CatalogEntry entry, ZimFile? replaces) {
    _pending[entry.id] = {'entry': entry.toJson(), 'replaces': ?replaces?.path};
    unawaited(_save());
  }

  /// While a download runs, its rows are drawn again every second even when no bytes come (a slow or stalled server sends
  /// nothing for seconds): the speed and time left keep up instead of the row freezing at "1.7 of 73 MB".
  Timer? _rowTicker;

  void _tickRows() {
    _rowTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final running = [for (final t in transfers.values) if (t.phase == TransferPhase.downloading) t];
      if (running.isEmpty) {
        _rowTicker?.cancel();
        _rowTicker = null;
        return;
      }
      for (final t in running) {
        DlMeter.speed('zim:${t.entry.id}', t.done);
      }
      notifyListeners();
    });
  }

  void _forget(String id) {
    if (_pending.remove(id) != null) unawaited(_save());
  }

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
    final onDevice = device;
    if (onDevice != null) {
      // The device downloads it and puts it in place, with the tab open or not. An update is finished by [_onSources] once the new
      // file is ready, as on a phone.
      if (replaces != null) {
        _replacements[entry.fileName] = replaces.path;
        await _save();
      }
      await onDevice.downloadZim(entry);
      updates.remove(replaces?.path);
      notifyListeners();
      return;
    }
    final existing = transfers[entry.id];
    if (existing != null &&
        existing.phase != TransferPhase.failed &&
        existing.phase != TransferPhase.paused &&
        existing.phase != TransferPhase.blockedByMobileData) {
      return;
    }
    final t = ZimTransfer(entry, replaces: replaces)..total = entry.size;
    transfers[entry.id] = t;
    _starts[entry.id] = (_starts[entry.id] ?? 0) + 1;
    _remember(entry, replaces);
    notifyListeners();
    if (!allowMobile && policy != null && await policy!.blocksDownload()) {
      t.phase = TransferPhase.blockedByMobileData;
      notifyListeners();
      return;
    }
    final token = t.token = CancelToken();
    final part = File('${sources.partialDir.path}/${entry.fileName}.part');
    final from = part.existsSync() ? part.lengthSync() : 0;
    final started = DateTime.now();
    logInfo('Download ${from > 0 ? 'resumes' : 'starts'}: ${entry.title} (${from >> 20} of ${entry.size >> 20} MB)', detail: entry.downloadUrl.toString(), job: 'download/${entry.id}');
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
          // The speed is measured from the download's own reports (every quarter second), not only when a row happens to be on
          // screen, so a row opened later shows its speed and time left at once.
          DlMeter.speed('zim:${entry.id}', d);
          _tickRows();
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
      final secs = DateTime.now().difference(started).inSeconds;
      logInfo('Download done: ${entry.title} (${entry.size >> 20} MB in $secs s${secs > 0 ? ', ${((entry.size - from) / secs / (1 << 20)).toStringAsFixed(1)} MB/s' : ''})', job: 'download/${entry.id}');
      _forget(entry.id);
      updates.remove(replaces?.path);
      notifyListeners();
      _onSources();
    } on DownloadException catch (e) {
      if (e.code == 'cancelled') {
        // Only this transfer: a new download of the entry may already be in its place. A paused one stays, to resume.
        if (transfers[entry.id] == t && t.phase != TransferPhase.paused) transfers.remove(entry.id);
      } else {
        t.phase = TransferPhase.failed;
        t.error = e.message;
        logError('Download failed: ${entry.title} (${e.code}, at ${t.done >> 20} MB)', error: e.message, job: 'download/${entry.id}');
      }
      notifyListeners();
    } catch (e) {
      t.phase = TransferPhase.failed;
      t.error = 'Could not finish the download: $e';
      logError('Download failed: ${entry.title}', error: e, job: 'download/${entry.id}');
      notifyListeners();
    } finally {
      loop.complete();
      if (_loops[entry.id] == loop.future) _loops.remove(entry.id);
    }
  }

  /// Pauses a download: it stops and keeps the partly downloaded file; [resume] continues it.
  void pause(CatalogEntry entry) {
    final t = transfers[entry.id];
    if (t == null || (t.phase != TransferPhase.downloading && t.phase != TransferPhase.starting)) return;
    t.phase = TransferPhase.paused;
    logInfo('Download paused: ${entry.title} at ${t.done >> 20} of ${t.total >> 20} MB', job: 'download/${entry.id}');
    // resumed later, the speed is measured afresh (not across the pause)
    DlMeter.reset('zim:${entry.id}');
    t.token?.cancel();
    notifyListeners();
  }

  /// Continues a paused download from where it stopped.
  Future<void> resume(CatalogEntry entry) async {
    final t = transfers[entry.id];
    if (t == null || t.phase != TransferPhase.paused) return;
    // The paused loop closes the file first; the new one waits for it and continues the file (on mobile data with mobile data
    // downloads off, it waits for Wi-Fi).
    await download(entry, replaces: t.replaces);
  }

  /// Stops a download and throws away the partly downloaded file.
  Future<void> cancel(CatalogEntry entry) async {
    final t = transfers[entry.id];
    if (t == null) return;
    t.token?.cancel();
    transfers.remove(entry.id);
    logInfo('Download canceled: ${entry.title}', job: 'download/${entry.id}');
    _forget(entry.id);
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
    _restorePending();
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
    _rowTicker?.cancel();
    device?.removeListener(notifyListeners);
    _net?.cancel();
    policy?.settings.removeListener(_startWaiting);
    sources.removeListener(_onSources);
    for (final t in transfers.values) {
      t.token?.cancel();
    }
    super.dispose();
  }
}

Future<Uint8List?> _fetchIcon(Uri url) async {
  try {
    return Uint8List.fromList(await fetchBytes(url, maxBytes: 512 * 1024, httpsOnly: false, timeout: const Duration(seconds: 15)));
  } catch (_) {
    return null;
  }
}
