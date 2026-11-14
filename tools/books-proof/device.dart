// My books two-writer proof: one device = one OS process running this file (flutter test --timeout none test/booksproof/device.dart).
// Real parts only: the app's SharingState over the real cache_sync SyncCore (iroh on localhost; relay, dht, mdns and lookup off),
// the Library kind's `libraries` share with main.dart's not-shared patterns, the Bookshelves link share (Match), My books made
// the way the app makes it (makeBlankLibrary + ownLibrarySettings), and Add PDF through the app's AddPdfState on the real core
// ingest (PDFium, bge-m3, the shipped sorter). Only stand-ins: a fixed wifi probe, and a fake OCR engine (the PDFs have text).
// Uses only API that build-1.1.0-51 and rel-1.1 share.
//
// Commands: <PROOF_DIR>/cmd/NNNN.json {"op","args"} -> <PROOF_DIR>/res/NNNN.json {"ok","result"|"error"}.
// Env: PROOF_DIR, PROOF_PORT, PROOF_NAME, CACHE_EMBED_LIB, CACHE_EMBED_MODEL, PROOF_CLASSIFIER.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_calls.dart';
import 'package:cache/library/add_pdf/add_pdf_engines.dart' show kPdfiumVersion;
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sources/libraries_state.dart' show makeBlankLibrary, ownLibrarySettings;
import 'package:cache_llama/cache_llama.dart';
import 'package:cache_ocr/cache_ocr.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_for_tests.dart';

// main.dart's values (declared in different files on 51 and rel-1.1; the same values)
const _libraryNotShared = ['*/index', '*/index-snapshots'];
const _zimNotShared = ['*.illustration.png'];

/// The connection: wifi, or none while the devices are "apart" (the network policy then stops the sync engine's use of the
/// network, as on a phone with no network).
class _Probe implements ConnectionProbe {
  ConnectionKind kind = ConnectionKind.wifi;
  final _c = StreamController<ConnectionKind>.broadcast();
  void set(ConnectionKind k) {
    kind = k;
    _c.add(k);
  }

  @override
  Future<ConnectionKind> current() async => kind;
  @override
  Stream<ConnectionKind> get changes => _c.stream;
}

class _Real implements SyncCoreLike {
  _Real(this.c);
  final SyncCore c;
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) => c.call(method, args);
  @override
  Future<void> close() => c.close();
}

/// A small PDF with a text layer: each page's lines in Helvetica (as add_pdf_core_test makes them).
List<int> textPdf(String title, List<List<String>> pages) {
  String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
  final objs = <List<int>>[];
  final kids = <String>[];
  objs.add(utf8.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  objs.add(const []);
  objs.add(utf8.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'));
  objs.add(utf8.encode('<< /Title (${esc(title)}) /Producer (cache proof) >>'));
  for (final lines in pages) {
    final id = objs.length + 1;
    kids.add('$id 0 R');
    final c = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      c.write('BT /F1 10 Tf 40 ${740 - i * 14} Td (${esc(lines[i])}) Tj ET\n');
    }
    objs.add(utf8.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${id + 1} 0 R >>'));
    final body = utf8.encode(c.toString());
    objs.add([...utf8.encode('<< /Length ${body.length} >>\nstream\n'), ...body, ...utf8.encode('endstream')]);
  }
  objs[1] = utf8.encode('<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>');
  final out = <int>[...utf8.encode('%PDF-1.4\n%âã\n')];
  final at = <int>[];
  for (var i = 0; i < objs.length; i++) {
    at.add(out.length);
    out
      ..addAll(utf8.encode('${i + 1} 0 obj\n'))
      ..addAll(objs[i])
      ..addAll(utf8.encode('\nendobj\n'));
  }
  final xref = out.length;
  final x = StringBuffer('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final a in at) {
    x.write('${a.toString().padLeft(10, '0')} 00000 n \n');
  }
  x.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Info 4 0 R >>\nstartxref\n$xref\n%%EOF\n');
  out.addAll(utf8.encode(x.toString()));
  return out;
}

void main() {
  final env = Platform.environment;
  test('device', timeout: Timeout.none, skip: env['PROOF_DIR'] == null ? 'PROOF_DIR not set' : false, () async {
    final root = Directory(env['PROOF_DIR']!)..createSync(recursive: true);
    final support = Directory('${root.path}/data')..createSync(recursive: true);
    final port = int.parse(env['PROOF_PORT']!);
    final name = env['PROOF_NAME'] ?? 'Device';
    final dev = 'proof-${name.toLowerCase()}';
    final libsDir = Directory('${support.path}/libraries')..createSync(recursive: true);
    final zimsDir = Directory('${support.path}/zims')..createSync(recursive: true);
    final shelvesDir = Directory('${support.path}/bookshelves');
    final settingsDir = Directory('${support.path}/settings-sync');
    void log(String s) => File('${root.path}/log.txt').writeAsStringSync('${DateTime.now().toIso8601String()} $s\n', mode: FileMode.append, flush: true);

    await pdfiumForTests();
    final core = await SearchCore.open(const []);
    final libraryKind = DataKind(
      id: 'library',
      label: 'Library',
      icon: Icons.menu_book_outlined,
      shared: () => {'library': zimsDir, 'libraries': libsDir},
      notShared: const {'library': _zimNotShared, 'libraries': _libraryNotShared},
    );
    final probe = _Probe();
    final sharing = SharingState(
      policy: DataPolicy(settings: AppSettings(), probe: probe),
      supportDir: () async => support,
      deviceName: name,
      kinds: [libraryKind],
      linkShares: [
        LinkShare(id: 'settings', name: 'Settings', dir: () => settingsDir, modes: const ['match', 'send']),
        LinkShare(id: 'bookshelves', name: 'Bookshelves', dir: () => shelvesDir, modes: const ['match']),
      ],
      opener: (cfg) async => _Real(await SyncCore.open({...cfg, 'relay': false, 'dht': false, 'mdns': false, 'lookup': false, 'interval_secs': 5, 'port': port})),
    );
    await sharing.init();

    final classifier = env['PROOF_CLASSIFIER']!;
    final engines = {
      'pdfium_lib': Pdfrx.pdfiumModulePath,
      'pdfium_version': kPdfiumVersion,
      'embed_lib': env['CACHE_EMBED_LIB'],
      'embed_model': env['CACHE_EMBED_MODEL'],
      'embed_sha256': 'c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb',
      'classifier': classifier,
    };
    final calls = CoreIngestCalls(init: () async {});

    /// My books here: the library folder whose settings say own_default (made here or arrived by sync).
    Directory? myBooks() {
      for (final d in libsDir.listSync().whereType<Directory>()) {
        final s = File('${d.path}/cache-library.json');
        if (!s.existsSync()) continue;
        try {
          if ((jsonDecode(s.readAsStringSync()) as Map)['own_default'] == true) return d;
        } catch (_) {}
      }
      return null;
    }

    Map<String, dynamic>? settingsOf(Directory lib) {
      try {
        return (jsonDecode(File('${lib.path}/cache-library.json').readAsStringSync()) as Map).cast<String, dynamic>();
      } catch (_) {
        return null;
      }
    }

    AddPdfState newState() => AddPdfState(
      calls: calls,
      dir: () async => Directory('${support.path}/ingest'),
      engines: () async => engines,
      ocrEngine: () async => FakeOcrEngine(engine: 'fake-ocr', version: '1', pages: const {}),
      bookshelves: () async {
        final lib = myBooks();
        return {
          'dir': shelvesDir.path,
          'dev': dev,
          'libraries': [
            if (lib != null) {'library_id': settingsOf(lib)?['library_id'] ?? '', 'dir': lib.path},
          ],
        };
      },
      permit: (_) async {},
    );
    final pendingAdds = <String, Future<Map<String, dynamic>>>{};

    Future<Map<String, dynamic>> add(String title, List<String> lines) async {
      final lib = myBooks() ?? (throw StateError('no My books on this device'));
      final bytes = textPdf(title, [lines, lines.reversed.toList()]);
      final f = File('${support.path}/picked/$title.pdf')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      final state = newState();
      final job = await state.add(pdfPath: f.path, fileName: '$title.pdf', bytes: bytes.length, title: title, target: AddPdfTarget(title: 'My books', path: lib.path, isDefault: true));
      final run = await (await state.pending()).firstWhere((t) => t.key == job.key).start();
      final ok = await run.finished.timeout(const Duration(minutes: 20));
      log('add $title: ok=$ok ${job.status.name} ${job.errorCode ?? ''} ${job.errorMessage ?? ''}');
      return {'ok': ok, 'status': job.status.name, 'error': job.errorCode, 'message': job.errorMessage, 'copy': job.result?['copy'], 'pieces': job.result?['pieces'], 'doc_id': job.result?['doc_id']};
    }

    Future<Map<String, dynamic>> syncOnce({int waitSecs = 60}) async {
      String? err;
      if (sharing.running) {
        final before = ((sharing.status['rounds'] as num?) ?? 0).toInt();
        try {
          await sharing.syncNow();
        } catch (e) {
          err = '$e';
        }
        final end = DateTime.now().add(Duration(seconds: waitSecs));
        var calm = 0;
        while (DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          await sharing.refresh();
          final s = sharing.status;
          final rounds = ((s['rounds'] as num?) ?? 0).toInt();
          final busy = s['transfer'] != null || sharing.shares.any((x) => ((x['pending_files'] as num?) ?? 0) > 0);
          if (rounds > before && !busy) {
            if (++calm >= 2) break;
          } else {
            calm = 0;
          }
        }
      }
      return {'sync_error': err, 'rounds': sharing.status['rounds']};
    }

    Future<Map<String, dynamic>> dump(List<String> phrases) async {
      final lib = myBooks();
      final out = <String, dynamic>{'name': name, 'my_books': lib?.path.substring(libsDir.path.length + 1)};
      // every file of the libraries folder, with its size; conflict copies and beside copies stand out
      final files = <String>[];
      await for (final f in libsDir.list(recursive: true, followLinks: false)) {
        if (f is File) files.add('${f.path.substring(libsDir.path.length + 1)} (${f.lengthSync()})');
      }
      files.sort();
      out['files'] = files;
      out['conflict_files'] = [for (final f in files) if (f.contains('(conflict') || f.contains('(from ')) f];
      if (lib == null) return out;
      final copies = File('${lib.path}/copies.jsonl');
      out['copies_jsonl'] = copies.existsSync()
          ? [
              for (final l in copies.readAsLinesSync())
                if (l.trim().isNotEmpty)
                  (() {
                    try {
                      final j = jsonDecode(l) as Map;
                      return {'doc_id': j['doc_id'], 'title': j['title'] ?? (j['book'] is Map ? (j['book'] as Map)['title'] : null), 'copy': j['copy'] ?? j['original_blake3']};
                    } catch (_) {
                      return {'unreadable': l.length};
                    }
                  })(),
            ]
          : null;
      final docs = File('${lib.path}/documents.tsv');
      out['documents_tsv'] = docs.existsSync() ? docs.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList() : null;
      final packs = Directory('${lib.path}/packs');
      out['packs'] = packs.existsSync() ? ([for (final f in packs.listSync()) f.uri.pathSegments.last]..sort()) : [];
      final pdfs = Directory('${lib.path}/bookshelf');
      out['bookshelf_pdfs'] = pdfs.existsSync() ? ([for (final f in pdfs.listSync()) f.uri.pathSegments.last]..sort()) : [];
      // the Bookshelves view, as this device resolves it
      try {
        final view = await core.shelvesResolve({
          'dir': shelvesDir.path,
          'libraries': [
            {'library_id': settingsOf(lib)?['library_id'] ?? '', 'dir': lib.path},
          ],
        });
        final raw = view['books'];
        final books = raw is Map ? raw.values.toList() : (raw is List ? raw : const []);
        out['bookshelves'] = [for (final b in books) if (b is Map) {'title': b['title'], 'call': b['call'], 'shelf': b['shelf'], 'removed': b['removed'], 'copies': (b['copies'] as List?)?.length}];
      } catch (e) {
        out['bookshelves_error'] = '$e';
      }
      // searchable: the library opened as the Library opens it, by meaning and by keyword
      SearchCore? searcher;
      CacheEmbedder? embedder;
      try {
        searcher = await SearchCore.open([SourceConfig.library(path: '${lib.path}/shard', indexDir: '${lib.path}/index', settings: settingsOf(lib))]);
        SourceStatus? st;
        for (var i = 0; i < 75; i++) {
          final libs = [for (final s in await searcher.status()) if (s.kind == 'library') s];
          if (libs.isNotEmpty && (libs.first.error != null || (!libs.first.opening && !libs.first.updating))) {
            st = libs.first;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        out['shard_points'] = st?.docs;
        out['library_error'] = st?.error == null ? null : '${st!.error!.code} ${st.error!.message}';
        out['keyword_indexed'] = st?.indexed;
        embedder = CacheEmbedder(modelPath: env['CACHE_EMBED_MODEL']!);
        final searches = <String, dynamic>{};
        for (final p in phrases) {
          Future<List<String>> run({QueryVector? v}) async {
            for (var i = 0; i < 50; i++) {
              try {
                final r = await searcher!.search(p, k: 10, queryVector: v);
                return [for (final h in r.results) h.title];
              } on CacheSearchException catch (e) {
                if (e.code != 'busy') rethrow;
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
            }
            return ['busy'];
          }

          final v = await embedder.embed(p);
          searches[p] = {'vector': await run(v: QueryVector(embedder.modelId, v)), 'keyword': await run()};
        }
        out['searches'] = searches;
      } catch (e) {
        out['search_error'] = '$e';
      } finally {
        await embedder?.dispose();
        await searcher?.close();
      }
      return out;
    }

    Future<dynamic> run(String op, Map<String, dynamic> a) async {
      switch (op) {
        case 'ping':
          return {'pid': pid};
        case 'sharing_setup':
          await sharing.setUp();
          return {'running': sharing.running, 'error': sharing.error, 'id': sharing.myId};
        case 'link_code':
          return {'code': await sharing.linkCode()};
        case 'link':
          final r = await sharing.link('${a['code']}');
          return {'peer': r.peer, 'name': r.name};
        case 'match_all':
          // the person's own devices: the link set to Match (as the link page's answer does), so the Bookshelves log goes too
          await sharing.refresh();
          for (final p in sharing.peers) {
            await sharing.setLink('${p['id']}', {'mode': 'match', 'from': sharing.myId});
          }
          await sharing.refresh();
          return {'peers': [for (final p in sharing.peers) {'id': p['id'], 'name': p['name'], 'link': p['link']}]};
        case 'share_library':
          await sharing.setShared(libraryKind, true);
          return {'shares': sharing.shares.map((s) => s['id']).toList()};
        case 'pause':
          // "apart": this device's sync engine stopped (as when the phones are not on the same network)
          probe.set(ConnectionKind.none);
          await Future<void>.delayed(const Duration(seconds: 2));
          await sharing.refresh();
          return {'paused': sharing.status['paused']};
        case 'resume':
          probe.set(ConnectionKind.wifi);
          await Future<void>.delayed(const Duration(seconds: 2));
          await sharing.refresh();
          return {'paused': sharing.status['paused']};
        case 'make_own':
          final lib = '${libsDir.path}/my-books';
          final settings = ownLibrarySettings(title: 'My books', id: 'my-books-proof', isDefault: true);
          final tmp = Directory('${support.path}/tmp')..createSync(recursive: true);
          await makeBlankLibrary(core, lib, settings, tmp);
          return {'lib': lib};
        case 'add':
          return add('${a['title']}', [for (final l in a['lines'] as List) '$l']);
        case 'add_start':
          final t = '${a['title']}';
          pendingAdds[t] = add(t, [for (final l in a['lines'] as List) '$l']);
          return {'started': t};
        case 'add_wait':
          return await pendingAdds.remove('${a['title']}')!;
        case 'sync':
          Map<String, dynamic> last = {};
          for (var i = 0; i < ((a['rounds'] as num?) ?? 1); i++) {
            last = await syncOnce();
          }
          return last;
        case 'sync_start':
          // a round asked for and not waited on (an add runs meanwhile)
          unawaited(sharing.syncNow().catchError((_) {}));
          return {};
        case 'status':
          await sharing.refresh();
          return {
            'running': sharing.running,
            'rounds': sharing.status['rounds'],
            'transfer': sharing.status['transfer'],
            'peers': [for (final p in sharing.peers) {'name': p['name'], 'live': p['live'], 'error': p['error'], 'link': p['link']}],
            'shares': [for (final s in sharing.shares) {'id': s['id'], 'files': s['files'], 'pending_files': s['pending_files']}],
            'log': ((sharing.status['log'] as List?) ?? const []).take(20).toList(),
          };
        case 'dump':
          return dump([for (final p in (a['phrases'] as List? ?? const [])) '$p']);
        case 'quit':
          sharing.dispose();
          await core.close();
          return {};
      }
      throw StateError('unknown op $op');
    }

    final cmd = Directory('${root.path}/cmd')..createSync(recursive: true);
    final res = Directory('${root.path}/res')..createSync(recursive: true);
    File('${root.path}/ready.json').writeAsStringSync(jsonEncode({'pid': pid}));
    log('ready pid=$pid');
    final running = <String>{};
    while (true) {
      final files = cmd.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()..sort((a, b) => a.path.compareTo(b.path));
      var quit = false;
      for (final f in files) {
        final n = f.uri.pathSegments.last;
        if (running.contains(n) || File('${res.path}/$n').existsSync()) continue;
        String text;
        try {
          text = f.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        final j = jsonDecode(text) as Map<String, dynamic>;
        running.add(n);
        log('cmd $n ${j['op']}');
        Map<String, dynamic> r;
        try {
          r = {'ok': true, 'result': await run('${j['op']}', ((j['args'] as Map?) ?? const {}).cast<String, dynamic>())};
        } catch (e, st) {
          log('error $e\n$st');
          r = {'ok': false, 'error': '$e'};
        }
        File('${res.path}/$n.tmp').writeAsStringSync(jsonEncode(r));
        File('${res.path}/$n.tmp').renameSync('${res.path}/$n');
        if (j['op'] == 'quit') quit = true;
      }
      if (quit) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });
}
