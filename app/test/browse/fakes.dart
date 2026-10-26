import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/opds.dart';
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

class FakeNetwork implements NetworkStatus {
  FakeNetwork(this.wifi);

  bool wifi;

  @override
  Future<bool> get unmetered async => wifi;
}

KiwixCatalog catalogWith(Future<String> Function(Uri) fetch) => KiwixCatalog(fetch: fetch);
