import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../app_fs.dart';
import '../../settings/space.dart' show Space, reserveFor;
import '../opds.dart';
import 'device_api.dart';
import 'local_files.dart';

/// Where the app remembers what it last saw of the transfers, so a reopened tab can say what happened meanwhile.
const String kDeviceSeenFile = 'device-library.json';

/// The last line of the delete confirm for a file the person uploaded.
const String kUploadedAgain = 'You uploaded this file. To get it back, upload it again.';

/// What the person may add from their computer, by file ending. A ZIM is installed by the device; anything else here is a library
/// package that the app installs itself (LibrariesState.addDeviceFile).
const List<String> kZimEndings = ['.zim'];
const List<String> kLibraryEndings = ['.cache-library', '.snapshot', '.tar', '.tar.gz', '.tgz'];

/// The kind (`zim` or `library`) of a file by its ending, or null when it is neither.
String? kindOfFileName(String name) {
  final n = name.toLowerCase();
  if (kZimEndings.any(n.endsWith)) return 'zim';
  if (kLibraryEndings.any(n.endsWith)) return 'library';
  return null;
}

/// The words for a file that is not a ZIM or a library.
String wrongFileType(String name) => '$name is not a library file. Choose a .zim file, a .cache-library file or a library snapshot. Nothing was uploaded.';

/// The words for a transfer that stopped, without the device's own text (which names the machine).
String deviceJobWords(DeviceJob j) {
  final e = (j.error ?? '').toLowerCase();
  if (e.contains('free space') || e.contains('out of space')) return 'Not enough space on this device.';
  if (e.contains('checksum')) return 'The file did not match its published checksum, so it was thrown away. Try again.';
  if (e.contains('connection')) return 'The connection failed. Try again.';
  return 'The download stopped. Try again.';
}

/// An upload under way or just ended, as the Library shows it.
class DeviceUpload {
  DeviceUpload(this.name, this.total, this.kind) : started = DateTime.now();

  final String name;
  final int total;
  final String kind;
  final DateTime started;
  int sent = 0;
  DateTime lastAt = DateTime.now();

  /// Set when it stopped for a reason; the words for people.
  String? error;

  /// True once every byte is on the device and it is being put in place.
  bool finishing = false;
  UploadTask? task;

  bool get running => error == null;
  double get fraction => total <= 0 ? 0 : (sent / total).clamp(0.0, 1.0);

  /// Bytes per second since the start; null before anything has gone.
  double? get speed {
    final secs = lastAt.difference(started).inMilliseconds / 1000;
    return sent <= 0 || secs <= 0 ? null : sent / secs;
  }

  /// Seconds left at the speed so far; null when not known.
  int? get secondsLeft {
    final s = speed;
    return s == null || s <= 0 ? null : ((total - sent) / s).ceil();
  }
}

/// The Library as a browser sees it: what is installed on the device, the transfers the device runs for download links (they go on with
/// the tab closed), the uploads from this computer, and the device's free space. The device's answers are read again every 2 seconds
/// while a transfer is active, every 30 seconds otherwise, and when the window comes back into focus.
class DeviceLibrary extends ChangeNotifier {
  DeviceLibrary({
    required this.api,
    required this.fs,
    this.uploader,
    this.fast = const Duration(seconds: 2),
    this.slow = const Duration(seconds: 30),
    void Function(bool)? leaveWarning,
    this.onItemsChanged,
  }) : _leaveWarning = leaveWarning ?? setLeaveWarning;

  final DeviceApi api;
  final AppFs fs;
  final Uploader? uploader;
  final Duration fast;
  final Duration slow;
  final void Function(bool) _leaveWarning;

  /// Called after the device's items changed (a download or an upload ended, an item was removed), so the app reads the sources again.
  Future<void> Function()? onItemsChanged;

  List<DeviceItem> items = const [];
  List<DeviceJob> jobs = const [];
  DeviceSpaceInfo space = const DeviceSpaceInfo();

  /// The problem to show about the device itself (it could not be reached), or null.
  String? problem;

  /// The upload under way, or the last one that failed (until dismissed).
  DeviceUpload? upload;

  /// A file that was refused before anything was sent (wrong type), until the next try.
  String? refusal;

  /// Jobs that changed while no tab was open: the card "While this tab was closed". Empty when there is nothing to say.
  List<DeviceJob> whileClosed = const [];

  /// True once the first answer is in.
  bool loaded = false;

  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  bool _ready = false;
  Map<String, String>? _seen;
  Future<void>? _running;
  bool _again = false;

  /// What was asked for each link this session, so a failed transfer can be tried again with the same checksum, origin and icon.
  final Map<String, Map<String, dynamic>> _requests = {};

  bool get anyActive => jobs.any((j) => j.active);

  /// Bytes still to come in all active transfers.
  int get stillToDownload => jobs.where((j) => j.active).fold<int>(0, (s, j) => s + (j.total > j.bytes ? j.total - j.bytes : 0));

  /// The device's free space as the app's download pop-up reads it (the reserve it keeps is the app's own rule).
  Space get spaceForDialog => Space(free: space.free, reserve: reserveFor(space.total));

  /// The line over the Library list while something is going on, or null.
  String? get activityHint {
    if (upload?.running == true) return 'Keep this tab open until the upload ends. Downloads and indexing carry on without it.';
    if (anyActive) return 'Downloads keep going if you close this tab.';
    return null;
  }

  /// A name for people for a transfer: the catalogue's title when this session asked for it, else the file name.
  String titleOfJob(DeviceJob j) {
    final o = _requests[j.url]?['origin'];
    final t = o is Map ? o['title'] : null;
    return t is String && t.isNotEmpty ? t : j.name;
  }

  /// The transfer for [url] that is waiting, running or failed, or null.
  DeviceJob? jobForUrl(String url) {
    for (final j in jobs) {
      if (j.url == url && (j.active || j.failed)) return j;
    }
    return null;
  }

  /// Library packages that were downloaded and wait to be added.
  List<DeviceJob> get readyPackages => [for (final j in jobs) if (j.done && j.kind == 'library' && !_added.contains(j.id)) j];
  final Set<String> _added = {};

  // ---- reading

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _readSeen();
    await refresh();
    final seen = _seen;
    if (seen != null) {
      // A transfer that changed since the last visit, or still runs, is told on first sight.
      whileClosed = [for (final j in jobs) if (seen[j.id] != j.state || j.active) j];
    }
    _ready = true;
    await _writeSeen();
    notifyListeners();
  }

  /// The window came back into focus.
  void onFocus() {
    if (_started) unawaited(refresh());
  }

  /// Reads the device's answers again. A call while one is running makes it read once more when it ends.
  Future<void> refresh() {
    final r = _running;
    if (r != null) {
      _again = true;
      return r;
    }
    return _running = () async {
      do {
        _again = false;
        await _readOnce();
      } while (_again && !_disposed);
    }()
        .whenComplete(() {
      _running = null;
      _schedule();
    });
  }

  Future<void> _readOnce() async {
    if (_disposed) return;
    final before = {for (final i in items) i.id};
    try {
      final r = await Future.wait<Object>([api.jobs(), api.items(), api.space()]);
      jobs = r[0] as List<DeviceJob>;
      items = r[1] as List<DeviceItem>;
      space = r[2] as DeviceSpaceInfo;
      problem = null;
      final first = !loaded;
      loaded = true;
      // Something arrived or went while this tab was looking elsewhere (a download ended): the app reads its sources again.
      if (!first && !(before.length == items.length && before.containsAll(items.map((i) => i.id)))) await onItemsChanged?.call();
    } on DeviceException catch (e) {
      problem = e.code == 'unauthorized' ? 'Sign in again to see the Library.' : 'This device could not be reached.';
    }
    await _writeSeen();
    if (!_disposed) notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !_started) return;
    _timer = Timer(anyActive ? fast : slow, () => unawaited(refresh()));
  }

  Future<void> _readSeen() async {
    try {
      final text = await fs.readString(AppRoot.support, kDeviceSeenFile);
      if (text == null) return;
      final j = (jsonDecode(text) as Map).cast<String, dynamic>();
      _seen = ((j['seen'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as String));
      _uploaded.addAll(((j['uploaded'] as List?) ?? const []).cast<String>());
    } catch (_) {
      // A damaged marker counts as a first visit.
    }
  }

  /// Keeps the marker of what this tab has seen. What the card "While this tab was closed" still lists is left as it was, so a
  /// reload before Dismiss says it again.
  Future<void> _writeSeen() async {
    if (!_ready || !loaded) return;
    final hold = {for (final j in whileClosed) j.id};
    final now = <String, String>{};
    for (final j in jobs) {
      if (!hold.contains(j.id)) {
        now[j.id] = j.state;
      } else if (_seen?[j.id] case final old?) {
        now[j.id] = old;
      }
    }
    if (_seen != null && mapEquals(_seen, now)) return;
    _seen = now;
    await _saveMarker();
  }

  Future<void> _saveMarker() async {
    try {
      await fs.writeStringAtomic(AppRoot.support, kDeviceSeenFile, jsonEncode({'seen': _seen ?? const {}, 'uploaded': _uploaded.toList()..sort()}));
    } catch (_) {}
  }

  /// File names the person uploaded from this computer (they cannot be downloaded again, so deleting them says so).
  final Set<String> _uploaded = {};
  bool wasUploaded(String name) => _uploaded.contains(name);

  /// Dismiss on the card "While this tab was closed".
  Future<void> dismissWhileClosed() async {
    whileClosed = const [];
    await _writeSeen();
    notifyListeners();
  }

  // ---- downloads

  /// Asks the device to download a catalogue entry: the link, the origin record and the icon address that the phone would save beside
  /// it. The device reads the checksum Kiwix publishes next to the file, as the phone does.
  Future<DeviceJob> downloadZim(CatalogEntry e) => _download({
        'url': e.downloadUrl.toString(),
        'kind': 'zim',
        'name': e.fileName,
        'origin': ZimOrigin.fromEntry(e).toJson(),
        'icon_url': e.iconUrl?.toString(),
      });

  /// Asks the device to download a library package from a link; it waits in the docs root to be added.
  Future<DeviceJob> downloadLibrary(String link) => _download({'url': link, 'kind': 'library'});

  Future<DeviceJob> _download(Map<String, dynamic> req) async {
    final job = await api.download(
      url: req['url'] as String,
      kind: req['kind'] as String,
      name: req['name'] as String?,
      origin: req['origin'] as Map<String, dynamic>?,
      iconUrl: req['icon_url'] as String?,
    );
    _requests[job.url] = req;
    await refresh();
    return job;
  }

  /// Try again on a failed transfer: the same request as before (this session), else the link alone.
  Future<void> retry(DeviceJob j) async {
    final req = _requests[j.url] ?? {'url': j.url, 'kind': j.kind, 'name': j.name};
    try {
      await api.cancelJob(j.id); // takes the failed one off the list
    } on DeviceException catch (_) {}
    await _download(req);
  }

  /// Stops a waiting or running transfer, or takes a failed one off the list.
  Future<void> cancelJob(DeviceJob j) async {
    try {
      await api.cancelJob(j.id);
      if (j.active) await api.cancelJob(j.id); // the cancelled one is then taken off the list as well
    } on DeviceException catch (_) {}
    await refresh();
  }

  /// A downloaded library package has been added (or given up on): it no longer waits.
  Future<void> packageHandled(DeviceJob j) async {
    _added.add(j.id);
    try {
      await api.cancelJob(j.id);
    } on DeviceException catch (_) {}
    await refresh();
  }

  // ---- removing

  /// Removes an installed item (its files, its index) from the device.
  Future<void> remove(String kind, String name) async {
    final it = items.where((i) => i.kind == kind && i.name == name).firstOrNull;
    if (it == null) return;
    await api.removeItem(it.id);
    await refresh();
    await onItemsChanged?.call();
  }

  /// Asks the search core to read the library folders again.
  Future<void> rescan() => api.rescan();

  // ---- uploads

  /// What stands in the way of uploading [file], in words for people, or null when nothing does (type and room).
  String? whyNot(LocalFile file) {
    if (kindOfFileName(file.name) == null) return wrongFileType(file.name);
    return null;
  }

  /// Bytes the file needs beyond what the device will use, or 0 when it fits (or the free space is not known).
  int shortBy(LocalFile file) => spaceForDialog.shortBy(file.size);

  /// Sends [file] to the device. The caller has checked [whyNot] and the room. Completes when the upload has ended, well or not:
  /// the result is the device's answer on success (a ZIM: installed; a library: `path` of the package in the docs root, relative to
  /// the docs root), null when it failed or was cancelled ([upload] then says why, or is gone).
  Future<Map<String, dynamic>?> send(LocalFile file) async {
    final up = uploader;
    if (up == null || upload?.running == true) return null;
    final kind = kindOfFileName(file.name) ?? 'library';
    final u = upload = DeviceUpload(file.name, file.size, kind);
    refusal = null;
    _leaveWarning(true);
    notifyListeners();
    try {
      final task = u.task = up.start(file, kind: kind, name: file.name, onProgress: (sent, total) {
        u.sent = sent;
        u.lastAt = DateTime.now();
        if (sent >= u.total) u.finishing = true;
        if (!_disposed) notifyListeners();
      });
      final result = await task.done;
      u.sent = u.total;
      upload = null;
      _leaveWarning(false);
      if (kind == 'zim') {
        _uploaded.add((result['name'] as String?) ?? file.name);
        await _saveMarker();
        await refresh();
        await onItemsChanged?.call();
      }
      notifyListeners();
      return result;
    } on UploadCancelled {
      upload = null;
    } on DeviceException catch (e) {
      u.error = _uploadWords(e);
    } catch (_) {
      u.error = 'The upload stopped. The partly uploaded file was removed.';
    }
    _leaveWarning(false);
    notifyListeners();
    return null;
  }

  static String _uploadWords(DeviceException e) {
    if (e.status == 507 || e.code == 'no_space') return 'Not enough space on this device. The partly uploaded file was removed.';
    if (e.code == 'unauthorized') return 'Sign in again, then upload it again.';
    if (e.code == 'interrupted' || e.code == 'upload_interrupted') return 'The connection was lost. The partly uploaded file was removed; upload it again.';
    if (e.code == 'invalid_name') return 'That file name is not allowed. Rename the file and try again.';
    return 'The upload failed. The partly uploaded file was removed.';
  }

  void cancelUpload() => upload?.task?.cancel();

  void dismissUpload() {
    if (upload != null && !upload!.running) {
      upload = null;
      notifyListeners();
    }
  }

  void clearRefusal() {
    if (refusal == null) return;
    refusal = null;
    notifyListeners();
  }

  void refuse(String why) {
    refusal = why;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (upload?.running == true) _leaveWarning(false);
    super.dispose();
  }
}
