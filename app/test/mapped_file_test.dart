// Whether a let-go model's file is still mapped, read from /proc/self/smaps (mappedFileSummaryOf).

import 'package:cache/platform/memory.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = '/storage/emulated/10/Android/data/app/files/models/e2b-Q4_K_M.gguf';

String _smaps(List<(String path, int sizeKb, int rssKb)> maps) {
  final b = StringBuffer();
  var at = 0x7000000000;
  for (final (path, size, rss) in maps) {
    final end = at + size * 1024;
    b.writeln('${at.toRadixString(16)}-${end.toRadixString(16)} r--p 00000000 fd:30 123456                     $path');
    b.writeln('Size:             $size kB');
    b.writeln('KernelPageSize:        4 kB');
    b.writeln('Rss:              $rss kB');
    b.writeln('Pss:              $rss kB');
    at = end;
  }
  // an anonymous mapping (no path) after
  b.writeln('${at.toRadixString(16)}-${(at + 4096).toRadixString(16)} rw-p 00000000 00:00 0 ');
  b.writeln('Size:                 4 kB');
  b.writeln('Rss:                  4 kB');
  return b.toString();
}

void main() {
  test('the model file mapped in two pieces: sizes and resident pages added up', () {
    final s = _smaps([(_model, 1048576, 524288), ('/system/lib64/libc.so', 2048, 1024), (_model, 1048576, 1048576)]);
    expect(mappedFileSummaryOf(s, _model), 'model file mapped: 2048 MB, resident 1536 MB');
  });

  test('not mapped (let go): said so', () {
    final s = _smaps([('/system/lib64/libc.so', 2048, 1024), ('$_model.other', 4096, 4096)]);
    expect(mappedFileSummaryOf(s, _model), 'model file not mapped');
  });

  test('an anonymous mapping or a mapping of another file never counts', () {
    expect(mappedFileSummaryOf(_smaps([]), _model), 'model file not mapped');
  });
}
