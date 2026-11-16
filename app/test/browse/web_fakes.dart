import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/app_fs.dart';
import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/local_files.dart';

/// The device, as the browser's code sees it: what the test sets is what it answers, and what it is asked is kept.
class FakeDeviceApi implements DeviceApi {
  List<DeviceItem> itemList = [];
  List<DeviceJob> jobList = [];
  DeviceSpaceInfo spaceInfo = const DeviceSpaceInfo(free: 100 << 30, total: 500 << 30);
  final List<Map<String, dynamic>> downloads = [];
  final List<String> cancelled = [];
  final List<String> paused = [];
  final List<String> resumed = [];
  final List<String> removed = [];
  int rescans = 0;
  int jobsReads = 0;
  DeviceException? failWith;

  /// What Pause and Resume answer instead of doing it.
  DeviceException? pauseError;
  DeviceException? resumeError;
  Uint8List fetchBody = Uint8List(0);
  Object? fetchError;
  Uri? fetched;
  String? fetchedScope;
  bool fetchedPlain = false;

  /// What a removal does besides being recorded (a test that keeps real files removes them here).
  void Function(String id)? onRemove;

  @override
  Future<List<DeviceItem>> items() async {
    if (failWith != null) throw failWith!;
    return List.of(itemList);
  }

  @override
  Future<List<DeviceJob>> jobs() async {
    jobsReads++;
    if (failWith != null) throw failWith!;
    return List.of(jobList);
  }

  @override
  Future<DeviceSpaceInfo> space() async {
    if (failWith != null) throw failWith!;
    return spaceInfo;
  }

  @override
  Future<DeviceJob> download({required String url, required String kind, String? name, String? sha256, Map<String, dynamic>? origin, String? iconUrl}) async {
    downloads.add({'url': url, 'kind': kind, 'name': name, 'sha256': sha256, 'origin': origin, 'icon_url': iconUrl});
    final j = DeviceJob(id: 'job${downloads.length}', url: url, kind: kind, name: name ?? url.split('/').last, bytes: 0, total: 0, state: 'queued');
    jobList = [...jobList, j];
    return j;
  }

  @override
  Future<void> cancelJob(String id) async {
    cancelled.add(id);
    final i = jobList.indexWhere((j) => j.id == id);
    if (i < 0) return;
    final j = jobList[i];
    jobList = [
      for (final x in jobList)
        if (x.id != id || j.active) x.id == id ? DeviceJob(id: id, url: j.url, kind: j.kind, name: j.name, bytes: j.bytes, total: j.total, state: 'cancelled') : x,
    ];
  }

  void _setState(String id, String state) {
    jobList = [
      for (final j in jobList)
        if (j.id == id) DeviceJob(id: id, url: j.url, kind: j.kind, name: j.name, bytes: j.bytes, total: j.total, state: state) else j,
    ];
  }

  @override
  Future<void> pauseJob(String id) async {
    paused.add(id);
    if (pauseError != null) throw pauseError!;
    _setState(id, 'paused');
  }

  @override
  Future<void> resumeJob(String id) async {
    resumed.add(id);
    if (resumeError != null) throw resumeError!;
    _setState(id, 'queued');
  }

  @override
  Future<void> removeItem(String id) async {
    removed.add(id);
    onRemove?.call(id);
    itemList = [for (final i in itemList) if (i.id != id) i];
  }

  @override
  Future<void> rescan() async => rescans++;

  @override
  Future<List<int>> fetch(Uri url, {String? scope, bool plain = false}) async {
    fetched = url;
    fetchedScope = scope;
    fetchedPlain = plain;
    if (fetchError != null) throw fetchError!;
    return fetchBody;
  }
}

DeviceJob job(String id, String state, {String kind = 'zim', String? name, int bytes = 0, int total = 0, String? error, String? url, DateTime? createdAt, DateTime? finishedAt}) =>
    DeviceJob(id: id, url: url ?? 'https://dl.example/$id.zim', kind: kind, name: name ?? '$id.zim', bytes: bytes, total: total, state: state, error: error, createdAt: createdAt, finishedAt: finishedAt);

DeviceItem item(String name, {String kind = 'zim', int bytes = 1000}) =>
    DeviceItem(id: '$kind-$name', kind: kind, name: name, title: name, bytes: bytes, path: 'app/docs/${kind == 'zim' ? 'zims' : 'libraries'}/$name');

/// A file on "this computer".
class FakeLocalFile implements LocalFile {
  FakeLocalFile(this.name, this.size, [this.content]);

  @override
  final String name;
  @override
  final int size;
  final List<int>? content;

  @override
  Future<Uint8List> readAll() async => Uint8List.fromList(content ?? const []);
}

/// An upload the test drives by hand.
class FakeUploader implements Uploader {
  final List<FakeUpload> started = [];

  @override
  UploadTask start(LocalFile file, {required String kind, required String name, required UploadProgress onProgress}) {
    final u = FakeUpload(file, kind, name, onProgress);
    started.add(u);
    return u;
  }
}

class FakeUpload implements UploadTask {
  FakeUpload(this.file, this.kind, this.name, this.onProgress);

  final LocalFile file;
  final String kind;
  final String name;
  final UploadProgress onProgress;
  final Completer<Map<String, dynamic>> _done = Completer<Map<String, dynamic>>();
  bool cancelled = false;
  bool get finished => _done.isCompleted;

  void progress(int sent) => onProgress(sent, file.size);
  void finish([Map<String, dynamic> result = const {}]) => _done.complete(result);
  void fail(Object e) => _done.completeError(e);

  @override
  Future<Map<String, dynamic>> get done => _done.future;

  @override
  void cancel() {
    cancelled = true;
    if (!_done.isCompleted) _done.completeError(const UploadCancelled());
  }
}

/// The app's files in memory, so a test that runs on a fake clock does not wait for the disk.
class MemoryAppFs implements AppFs {
  final Map<String, String> files = {};

  String _k(AppRoot r, String p) => '${r.name}:$p';

  @override
  Future<String?> readString(AppRoot root, String path) async => files[_k(root, path)];

  @override
  Future<void> writeStringAtomic(AppRoot root, String path, String text) async => files[_k(root, path)] = text;

  @override
  Future<String> rootPath(AppRoot root) async => '/device/${root.name}';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Real files in a test folder: the support and docs roots of the "device".
AppFs diskFs(Directory support, Directory docs) => createAppFs(supportOverride: support, docsOverride: docs);

File touch(String path, [String content = '']) => File(path)
  ..parent.createSync(recursive: true)
  ..writeAsStringSync(content);

/// A [DeviceApi] that answers like [inner] except where a test overrides a call.
class FakeDeviceApiView implements DeviceApi {
  FakeDeviceApiView(this.inner);

  final FakeDeviceApi inner;

  @override
  Future<List<DeviceItem>> items() => inner.items();
  @override
  Future<List<DeviceJob>> jobs() => inner.jobs();
  @override
  Future<DeviceSpaceInfo> space() => inner.space();
  @override
  Future<DeviceJob> download({required String url, required String kind, String? name, String? sha256, Map<String, dynamic>? origin, String? iconUrl}) =>
      inner.download(url: url, kind: kind, name: name, sha256: sha256, origin: origin, iconUrl: iconUrl);
  @override
  Future<void> cancelJob(String id) => inner.cancelJob(id);
  @override
  Future<void> pauseJob(String id) => inner.pauseJob(id);
  @override
  Future<void> resumeJob(String id) => inner.resumeJob(id);
  @override
  Future<void> removeItem(String id) => inner.removeItem(id);
  @override
  Future<void> rescan() => inner.rescan();
  @override
  Future<List<int>> fetch(Uri url, {String? scope, bool plain = false}) => inner.fetch(url, scope: scope, plain: plain);
}
