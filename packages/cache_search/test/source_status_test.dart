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

  test("a ZIM's caption and EPUB indexes, and a saved video's captions index", () {
    final s = SourceStatus.fromJson({
      'id': 'u', 'kind': 'zim', 'path': '/z', 'title': 'Z', 'indexed': true, 'docs': 1,
      'captionsindex': {'state': 'ready', 'kind': 'zim-captions', 'snapshot': 'b1', 'files': 12, 'pieces': 300, 'source_id': 'u', 'entries': 12, 'needs_build': false},
      'epubindex': {'state': 'none', 'kind': 'zim-epub', 'source_id': 'u', 'entries': 85, 'needs_build': true},
    });
    expect(s.captionsIndex!.items, 12);
    expect(s.captionsIndex!.state, 'ready');
    expect(s.epubIndex!.needsBuild, isTrue);
    expect(s.epubIndex!.entries, 85);
    expect(ZimSubIndex.fromJson(s.epubIndex!.toJson()).needsBuild, isTrue);
    final v = DownloadedVideo.fromJson({
      'instance': 'p.example', 'uuid': 'v', 'title': 'V', 'size': 1, 'path': '/v.mp4',
      'captions_index': {'source_id': 'p.example/v', 'kind': 'captions', 'files': 2, 'built': false, 'needs_build': true},
    });
    expect(v.captionsIndex!.sourceId, 'p.example/v');
    expect(v.captionsIndex!.needsBuild, isTrue);
  });
}
