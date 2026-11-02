import 'dart:convert';
import 'dart:io' show FileSystemException;
import 'dart:typed_data';

import 'package:cache/notebook/sync/folder_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart' show SafNewFile;
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart' show SafDocumentFile;

/// A SAF tree in memory: a URI per file and folder ("t" is the tree; a child is its parent, "/" and its name).
class _Tree {
  final Map<String, Uint8List?> nodes = {'t': null}; // null = a folder
  int clock = 1;

  /// Which document each file is (a new one when made, the same one when written in place, carried by a rename).
  final Map<String, int> docs = {};
  int _next = 1;
  int newDoc() => _next++;

  /// The next in-place write fails: 'throw' (after truncating, as a half-done "wt" would), or 'garble' (writes other bytes).
  String? failInPlace;
  SafDocumentFile doc(String uri) => SafDocumentFile(uri: uri, name: uri.split('/').last, isDir: nodes[uri] == null, length: nodes[uri]?.length ?? 0, lastModified: clock);
}

class _Util extends SafUtil {
  _Util(this.t);
  final _Tree t;

  @override
  Future<bool> exists(String uri, bool isDir) async => t.nodes.containsKey(uri);
  @override
  Future<SafDocumentFile?> documentFileFromUri(String uri, bool? isDir) async => t.nodes.containsKey(uri) ? t.doc(uri) : null;
  @override
  Future<SafDocumentFile?> child(String uri, List<String> names) async {
    final u = [uri, ...names].join('/');
    return t.nodes.containsKey(u) ? t.doc(u) : null;
  }

  @override
  Future<List<SafDocumentFile>> list(String uri) async => [
        for (final k in t.nodes.keys)
          if (k.startsWith('$uri/') && !k.substring(uri.length + 1).contains('/')) t.doc(k),
      ];
  @override
  Future<SafDocumentFile> mkdirp(String uri, List<String> names) async {
    var u = uri;
    for (final n in names) {
      u = '$u/$n';
      t.nodes.putIfAbsent(u, () => null);
    }
    return t.doc(u);
  }

  @override
  Future<void> delete(String uri, bool isDir) async {
    final u = Uri.decodeFull(uri);
    t.nodes.removeWhere((k, _) => k == u || k.startsWith('$u/'));
    t.docs.remove(u);
  }
  @override
  Future<SafDocumentFile> rename(String encoded, bool isDir, String newName) async {
    final uri = Uri.decodeFull(encoded);
    final parent = uri.substring(0, uri.lastIndexOf('/'));
    final to = '$parent/$newName';
    t.nodes[to] = t.nodes.remove(uri);
    final d = t.docs.remove(uri);
    if (d != null) t.docs[to] = d;
    return t.doc(to);
  }
}

class _Stream extends SafStream {
  _Stream(this.t);
  final _Tree t;

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async => t.nodes[uri]!;
  @override
  Future<SafNewFile> writeFileBytes(String treeUri, String fileName, String mime, Uint8List data, {bool? overwrite, bool? append}) async {
    final u = '$treeUri/$fileName';
    t.nodes[u] = data;
    t.docs[u] = t.newDoc();
    return SafNewFile(Uri.parse(Uri.encodeFull(u)), fileName);
  }

  @override
  Future<SafNewFile> writeFileUriBytes(String fileUri, Uint8List data, {bool? append}) async {
    final how = t.failInPlace;
    t.failInPlace = null;
    if (how == 'throw') {
      t.nodes[fileUri] = Uint8List(0);
      throw Exception('disk went away');
    }
    t.nodes[fileUri] = how == 'garble' ? Uint8List.fromList([...data.take(3)]) : data;
    return SafNewFile(Uri.parse(Uri.encodeFull(fileUri)), fileUri.split('/').last);
  }
}

void main() {
  test('a SAF folder: write (through a temporary file that replaces the target), read, list all levels, delete', () async {
    final tree = _Tree();
    final f = SafFolder('t', util: _Util(tree), stream: _Stream(tree));
    expect(await f.reachable(), isTrue);
    await f.writeText('Journal/2026-10-27 Note.md', 'one');
    await f.writeText('Journal/2026-10-27 Note.md', 'two');
    await f.writeBytes('attachments/cache-p1.jpg', Uint8List.fromList([1, 2, 3]));
    expect(await f.readText('Journal/2026-10-27 Note.md'), 'two');
    expect(tree.nodes.keys.where((k) => k.contains('cache-tmp')), isEmpty);
    tree.nodes['t/.obsidian'] = null;
    tree.nodes['t/.obsidian/app.json'] = Uint8List.fromList(utf8.encode('{}'));
    expect([for (final x in await f.list('')) x.path], ['Journal/2026-10-27 Note.md', 'attachments/cache-p1.jpg'], reason: "the apps' own dot folders are left alone");
    expect([for (final x in await f.list('Journal')) x.path], ['Journal/2026-10-27 Note.md']);
    expect(await f.exists('attachments/cache-p1.jpg'), isTrue);
    await f.delete('attachments/cache-p1.jpg');
    expect(await f.exists('attachments/cache-p1.jpg'), isFalse);
    expect(await f.readText('missing.md'), isNull);
  });

  test('a file that is there is written in place (the same document), only after its new bytes are kept beside it', () async {
    final tree = _Tree();
    final f = SafFolder('t', util: _Util(tree), stream: _Stream(tree));
    await f.writeText('Trips/Camping list.md', 'one');
    final doc = tree.docs['t/Trips/Camping list.md'];
    expect(doc, isNotNull, reason: 'a new file is made (through a temporary file that is renamed)');
    await f.writeText('Trips/Camping list.md', '---\ncache_id: abc\n---\none');
    expect(await f.readText('Trips/Camping list.md'), '---\ncache_id: abc\n---\none');
    expect(tree.docs['t/Trips/Camping list.md'], doc, reason: 'the same document: Obsidian on Android sees the change');
    expect(tree.nodes.keys.where((k) => k.contains('cache-tmp')), isEmpty);
    expect(f.lastWriteIssue, isNull);
  });

  test('an in-place write that fails or reads back wrong: the temporary copy replaces the file, whole, and the error is thrown', () async {
    for (final how in ['throw', 'garble']) {
      final tree = _Tree();
      final f = SafFolder('t', util: _Util(tree), stream: _Stream(tree));
      await f.writeText('Note.md', 'the old text');
      tree.failInPlace = how;
      await expectLater(f.writeText('Note.md', 'the new text, whole'), throwsA(isA<FileSystemException>()), reason: how);
      expect(await f.readText('Note.md'), 'the new text, whole', reason: how);
      expect(tree.nodes.keys.where((k) => k.contains('cache-tmp')), isEmpty, reason: how);
      expect(f.lastWriteIssue, contains('Note.md'));
      // the next write is in place again
      final doc = tree.docs['t/Note.md'];
      await f.writeText('Note.md', 'later');
      expect((await f.readText('Note.md'), tree.docs['t/Note.md']), ('later', doc));
    }
  });
}
