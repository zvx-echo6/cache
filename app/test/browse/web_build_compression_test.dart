import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_compression.dart';
import 'package:flutter_test/flutter_test.dart';

BuildBook book(Map<String, dynamic>? compression, {int size = 0}) => BuildBook(id: 'test', title: 'Book', size: size, compression: compression);

void main() {
  test('legacy sizes do not imply a compression choice', () {
    expect(compressionOutcomeWords(book(null)), isNull);
    expect(storedBookBytes(book(null)), isNull);
    expect(compressionOutcomeWords(book(null, size: 1024)), 'Stored 1 KB');
  });
  test('stored size and saving come from recorded facts, not upload size', () {
    final b = book({'original_size': 2048, 'stored_size': 1024, 'level': 'lossless'}, size: 2048);
    expect(storedBookBytes(b), 1024);
    expect(compressionOutcomeWords(b), 'Stored 1 KB (was 2 KB) · Smaller file, pages unchanged');
  });
  test('requested smaller scans can actually store a lossless fallback', () {
    final b = book({
      'original_size': 2048,
      'stored_size': 1024,
      'level': 'smaller_scans',
      'preset': 'smallest',
      'kept_original': false,
      'kept_reason': 'quality check; pictures kept as they were',
    });
    expect(compressionOutcomeWords(b), 'Stored 1 KB (was 2 KB) · Smaller file, pages unchanged');
  });
  test('successful lossy result names its preset', () {
    expect(
      compressionOutcomeWords(book({'stored_size': 1024, 'level': 'smaller_scans', 'preset': 'high'})),
      'Stored 1 KB · Smaller scans: High quality',
    );
  });
  test('timeout is an original-kept outcome, not a failed book', () {
    expect(
      compressionOutcomeWords(book({'stored_size': 2048, 'level': 'lossless', 'kept_original': true, 'kept_reason': 'timed out'})),
      'Kept as it came · Making it smaller timed out.',
    );
  });
  test('off remains distinct from an unsuccessful compression attempt', () {
    expect(compressionOutcomeWords(book({'stored_size': 1024, 'level': 'off', 'kept_original': true})), 'Stored 1 KB · Not made smaller');
    expect(
      compressionOutcomeWords(book({'stored_size': 1024, 'level': 'lossless', 'kept_original': true, 'kept_reason': '/internal/path: failure'})),
      'Kept as it came · Cache kept the original because a smaller copy did not pass its checks.',
    );
  });
}
