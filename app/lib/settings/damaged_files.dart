import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// A downloaded file and what its published manifest says it must be: its size and, when published, its SHA-256. Only files
/// that have one are checked; a file without a manifest is never called damaged.
class FileManifest {
  const FileManifest(this.path, {required this.bytes, this.sha256});

  final String path;
  final int bytes;

  /// Lowercase hex, or null when only the size is published.
  final String? sha256;
}

/// Finds downloaded files that do not match their manifest (Storage's Clean up removes them). The size is checked every time; the
/// SHA-256 is worked out once per file as it is on disk (its size and time), off the screen's thread, and remembered.
class DamagedFiles {
  DamagedFiles({Future<String> Function(String path)? hash}) : _hash = hash ?? _sha256OfFile;

  final Future<String> Function(String path) _hash;

  /// What the hash of each file was, for the file as it was then (size and modified time).
  final Map<String, (int, DateTime, String)> _hashed = {};

  /// The files of [manifests] that are there and do not match. With [hash] false only the size is compared (and hashes worked out
  /// before); with it true every file whose hash is not known yet is hashed now.
  Future<List<FileManifest>> find(List<FileManifest> manifests, {bool hash = true}) async {
    final out = <FileManifest>[];
    for (final m in manifests) {
      final f = File(m.path);
      final FileStat st;
      try {
        st = await f.stat();
      } catch (_) {
        continue;
      }
      if (st.type != FileSystemEntityType.file) continue;
      if (st.size != m.bytes) {
        out.add(m);
        continue;
      }
      final want = m.sha256?.toLowerCase();
      if (want == null) continue;
      final known = _hashed[m.path];
      String? got = known != null && known.$1 == st.size && known.$2 == st.modified ? known.$3 : null;
      if (got == null && hash) {
        try {
          got = await _hash(m.path);
          _hashed[m.path] = (st.size, st.modified, got);
        } catch (_) {
          continue; // could not be read now: not called damaged
        }
      }
      if (got != null && got != want) out.add(m);
    }
    return out;
  }
}

Future<String> _sha256OfFile(String path) => Isolate.run(() async {
      final out = await sha256.bind(File(path).openRead()).first;
      return out.toString();
    });
