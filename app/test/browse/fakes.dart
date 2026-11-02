import 'dart:async';
import 'dart:io';

import 'package:cache/browse/opds.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sources/sources_state.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Sources with no search core: files are scanned, and what the core would say (ready, title, id) is set by hand.
class FakeSources extends SourcesState {
  FakeSources(Directory dir) : super(zimsDirOverride: dir, indexesDirOverride: Directory('${dir.path}/idx')) {
    zimsDir = dir;
  }

  final Set<String> ready = {};
  final Map<String, String> titles = {};
  final Map<String, String> ids = {};
  final List<String> removed = [];

  void poke() => notifyListeners();

  @override
  bool isReadyPath(String path) => ready.contains(path);

  @override
  String titleOf(ZimFile z) => titles[z.path] ?? super.titleOf(z);

  @override
  String? idOf(ZimFile z) => ids[z.path];

  @override
  ZimPhase phaseOf(ZimFile z) => ready.contains(z.path) ? ZimPhase.ready : ZimPhase.waiting;

  @override
  Future<void> remove(ZimFile z) async {
    removed.add(z.path);
    final f = File(z.path);
    if (f.existsSync()) f.deleteSync();
    await refresh();
  }
}

/// A connection that is what the test says.
class FakeProbe implements ConnectionProbe {
  FakeProbe(this.kind);

  ConnectionKind kind;
  final StreamController<ConnectionKind> _changes = StreamController<ConnectionKind>.broadcast();

  @override
  Future<ConnectionKind> current() async => kind;

  @override
  Stream<ConnectionKind> get changes => _changes.stream;

  void change(ConnectionKind k) {
    kind = k;
    _changes.add(k);
  }
}

/// The mobile data rule on a Wi-Fi connection (or, with [wifi] false, on mobile data), with downloads on mobile data off as they are by default.
DataPolicy testPolicy({bool wifi = true, AppSettings? settings}) =>
    DataPolicy(settings: settings ?? AppSettings(), probe: FakeProbe(wifi ? ConnectionKind.wifi : ConnectionKind.mobile));

KiwixCatalog catalogWith(Future<String> Function(Uri) fetch) => KiwixCatalog(fetch: fetch);
