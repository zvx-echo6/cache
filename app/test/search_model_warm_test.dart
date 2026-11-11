import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/search_model.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

/// An embedder that counts what the app asks of it; the model itself is not loaded.
class _Fake extends CacheEmbedder {
  _Fake(String path) : super(modelPath: path);
  int warms = 0;
  int frees = 0;
  int embeds = 0;
  bool loaded = false;

  @override
  Future<void> warm() async {
    warms++;
    loaded = true;
  }

  @override
  Future<List<double>> embed(String text) async {
    embeds++;
    loaded = true;
    return [0.25, 0.5, 0.75];
  }

  @override
  void free() {
    frees++;
    loaded = false;
  }
}

MemoryReading _free(int mb) => MemoryReading(avail: mb << 20, total: 8192 << 20);

void main() {
  late Directory dir;
  late AppState app;
  late List<_Fake> made;
  late SearchModel sm;
  late MemoryReading? memory;

  Future<void> start({bool withModel = true}) async {
    if (withModel) File('${dir.path}/models/bge-m3-Q8_0.gguf').writeAsBytesSync(List.filled(1000, 1));
    await app.init();
    sm = SearchModel(
      app: app,
      modelsDir: () async => app.modelsDir!,
      make: (p) {
        final f = _Fake(p);
        made.add(f);
        return f;
      },
      remote: false,
      readMemoryNow: () async => memory,
      readCounters: () => const {'VmRSS_kb': 2048, 'RssAnon_kb': 1024, 'RssFile_kb': 1024},
    );
    addTearDown(sm.dispose);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('search-warm');
    Directory('${dir.path}/models').createSync();
    app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
    made = [];
    memory = _free(4096);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('in front with room for the file and 512 MiB: the model loads ahead of use and is held without an idle release', () async {
    await start();
    await sm.warmLoad();
    expect(made, hasLength(1));
    expect(made.single.warms, 1);
    expect(made.single.keepLoaded, isTrue, reason: 'keepLoaded is what switches the embedder\'s idle release off');
    expect(sm.isWarm, isTrue);
    await sm.embedder.embed('water');
    expect(made.single.keepLoaded, isTrue, reason: 'a search does not bring the idle release back');
    expect(made.single.frees, 0);
  });

  test('not enough memory (the file plus 512 MiB): nothing loads, and a search loads it as before', () async {
    await start();
    memory = _free(500);
    await sm.warmLoad();
    expect(made, isEmpty);
    expect(sm.isWarm, isFalse);
    await sm.embedder.embed('water');
    expect(made.single.warms, 0);
    expect(made.single.embeds, 1);
    expect(made.single.keepLoaded, isFalse, reason: 'a lazy load idles out as today');
  });

  test('memory the system does not report: nothing loads ahead', () async {
    await start();
    memory = null;
    await sm.warmLoad();
    expect(made, isEmpty);
  });

  test('no search model installed: nothing loads', () async {
    await start(withModel: false);
    await sm.warmLoad();
    expect(made, isEmpty);
  });

  for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached]) {
    test('going to the back ($state) lets the model go; inactive does not', () async {
      await start();
      await sm.warmLoad();
      sm.onLifecycle(AppLifecycleState.inactive);
      expect(made.single.frees, 0, reason: 'inactive (a dialog) keeps it');
      sm.onLifecycle(state);
      expect(made.single.frees, 1);
      expect(made.single.keepLoaded, isFalse);
      expect(sm.isWarm, isFalse);
    });
  }

  test('back in front: it loads again, with the same memory check', () async {
    await start();
    await sm.warmLoad();
    sm.onLifecycle(AppLifecycleState.paused);
    memory = _free(300);
    sm.onLifecycle(AppLifecycleState.resumed);
    await sm.warmLoad();
    expect(made.single.warms, 1, reason: 'short of memory on resume: not loaded');
    memory = _free(4096);
    sm.onLifecycle(AppLifecycleState.paused);
    sm.onLifecycle(AppLifecycleState.resumed);
    await sm.warmLoad();
    expect(made.single.warms, 2);
    expect(made.single.keepLoaded, isTrue);
    expect(sm.isWarm, isTrue);
  });

  test('a memory trim lets it go; the next search loads it lazily and it idles out as today', () async {
    await start();
    await sm.warmLoad();
    sm.onTrim(kTrimRunningLow);
    expect(made.single.frees, 1);
    expect(made.single.keepLoaded, isFalse);
    expect(sm.isWarm, isFalse);
    await sm.embedder.embed('water');
    expect(made.single.embeds, 1);
    expect(made.single.warms, 1, reason: 'no reload on its own after a trim');
    expect(made.single.keepLoaded, isFalse);
  });

  test('an iOS memory warning lets it go', () async {
    await start();
    await sm.warmLoad();
    sm.onMemoryWarning();
    expect(made.single.frees, 1);
    expect(sm.isWarm, isFalse);
  });

  test('the trim levels that release are the ones the chat model is let go at', () {
    expect(releaseModelOn(kTrimRunningLow, null), isTrue);
    expect(releaseModelOn(kTrimUiHidden, _free(100)), isTrue);
    expect(releaseModelOn(5, null), isFalse);
  });

  test('not loaded ahead while the app is at the back', () async {
    await start();
    sm.onLifecycle(AppLifecycleState.paused);
    await sm.warmLoad();
    expect(made, isEmpty);
  });

  test('in a browser (the server holds the model) nothing is loaded ahead', () async {
    await start();
    final web = SearchModel(app: app, modelsDir: () async => app.modelsDir!, make: (p) => _Fake(p), remote: true, readMemoryNow: () async => memory);
    addTearDown(web.dispose);
    await web.warmLoad();
    expect(web.isWarm, isFalse);
  });
}
