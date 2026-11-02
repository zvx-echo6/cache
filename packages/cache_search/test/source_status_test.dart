import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a source's id in the indexes folder and where its index is", () {
    final s = SourceStatus.fromJson({
      'id': '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      'kind': 'zim',
      'path': '/z/wikimed.zim',
      'title': 'WikiMed',
      'indexed': true,
      'docs': 10,
      'source_id': '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      'index': {'location': 'snapshot', 'snapshot': 'b-20261102', 'format': 3, 'kind': 'zim'},
    });
    expect(s.sourceId, '6ba7b810-9dad-11d1-80b4-00c04fd430c8');
    expect(s.index!.location, 'snapshot');
    expect(s.index!.snapshot, 'b-20261102');
    expect(s.index!.format, 3);
    expect(s.index!.kind, 'zim');
  });

  test('a core that does not report them leaves them null', () {
    final s = SourceStatus.fromJson({'id': 'x', 'kind': 'library', 'path': '/l', 'title': 'L', 'indexed': false, 'docs': 0});
    expect(s.sourceId, isNull);
    expect(s.index, isNull);
  });
}
