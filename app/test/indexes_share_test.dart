import 'package:cache/search/indexes_share.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

SourceStatus _source(String kind, String? sourceId) => SourceStatus.fromJson({
      'id': sourceId,
      'kind': kind,
      'path': '/x/$sourceId',
      'title': '$sourceId',
      'indexed': true,
      'docs': 1,
      'source_id': sourceId,
    });

void main() {
  test('a source id becomes one folder name as the core writes it', () {
    // The core's own cases (cache_search snapshot.rs).
    expect(encodeSourceId('my-lib@3'), 'my-lib@3');
    expect(encodeSourceId('a/b'), 'a%2Fb');
    expect(encodeSourceId('..'), '%2E.');
    expect(encodeSourceId('6ba7b810-9dad-11d1-80b4-00c04fd430c8'), '6ba7b810-9dad-11d1-80b4-00c04fd430c8');
    expect(encodeSourceId('peertube.example/abc'), 'peertube.example%2Fabc');
    expect(encodeSourceId('é *'), '%C3%A9%20%2A', reason: 'UTF-8 bytes; never a pattern character');
  });

  test('a device fetches every kind of index of the sources it has, and nothing for a source that did not open', () {
    final only = indexesFetchOnly([
      _source('zim', '6ba7b810-9dad-11d1-80b4-00c04fd430c8'),
      _source('library', 'field-guide@2'),
      _source('zim', null),
      _source('something-new', 'x'),
    ]);
    expect(only, [
      'library/field-guide@2',
      'places-index',
      'region-index',
      'zim-captions/6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      'zim-epub/6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      'zim-pdf/6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      'zim/6ba7b810-9dad-11d1-80b4-00c04fd430c8',
    ]);
    expect(indexesFetchOnly(const []), ['places-index', 'region-index'], reason: 'the regions\' tile indexes, before any region');
  });

  test("the folder's rules: builds and SQLite working files stay, deletes stay, manifests last", () {
    expect(kIndexesNotShared, containsAll(['*/*/.build', '**/*-shm', '**/*-wal', '**/*-journal']));
    expect(kIndexesLocalDeletes, ['*/*/snap']);
    expect(kIndexesLast, ['*/*/snap/*/manifest.json']);
  });

  test('snapshots the core rejected are never fetched again; its own notes (.local) never travel', () {
    expect(kIndexesNotShared, contains('.local'));
    expect(
      indexesNeverFetch(const [
        RejectedSnapshot(kind: 'zim-pdf', sourceId: '6ba7b810-9dad-11d1-80b4-00c04fd430c8', buildId: 'b-7', reason: 'format'),
        RejectedSnapshot(kind: 'library', sourceId: 'guide@2', buildId: 'b-1'),
        RejectedSnapshot(kind: '', sourceId: 'x', buildId: 'y'),
        // As e541cb2 gives it: the path the core wrote, the source id encoded as a folder name.
        RejectedSnapshot(kind: 'captions', sourceId: 'p.example/v1', buildId: 'b-2', path: 'captions/p.example%2Fv1/snap/b-2'),
      ]),
      ['captions/p.example%2Fv1/snap/b-2', 'library/guide@2/snap/b-1', 'zim-pdf/6ba7b810-9dad-11d1-80b4-00c04fd430c8/snap/b-7'],
    );
    // The path built here matches the core's for the same snapshot.
    expect(indexesNeverFetch(const [RejectedSnapshot(kind: 'captions', sourceId: 'p.example/v1', buildId: 'b-2')]), ['captions/p.example%2Fv1/snap/b-2']);
  });

  test("Tantivy's hidden files in a snapshot travel (its manifest lists .managed.json)", () {
    expect(kIndexesHidden, ['*/*/snap/*/.managed.json', '*/*/snap/*/.tantivy-meta.lock']);
  });
}
