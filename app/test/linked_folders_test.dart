import 'dart:async';
import 'dart:convert';
import 'package:cache/linked_folders/linked_folders.dart';
import 'package:cache/linked_folders/linked_folder_management.dart';
import 'package:cache/linked_folders/linked_folder_setup.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object result) =>
    http.Response(jsonEncode({'ok': true, 'result': result}), 200);
Map<String, dynamic> _root() => {
  'id': 'root-a',
  'label': 'Field manuals',
  'mode': 'keep',
  'path': '/library/field',
  'exclusions': ['private'],
  'paused': false,
  'state': 'ready',
};
Map<String, dynamic> _config() => {
  'local_config': {
    'roots': [_root()],
    'books': [
      {
        'doc_id': 'book-a',
        'blake3': 'hash-a',
        'title': 'Water treatment',
        'pending_indexing': false,
        'locations': [
          {
            'root_id': 'root-a',
            'relative_path': 'water.pdf',
            'blake3': 'hash-a',
            'available': true,
          },
          {
            'root_id': 'root-a',
            'relative_path': 'water-copy.pdf',
            'blake3': 'hash-a',
            'available': true,
          },
        ],
      },
      {
        'doc_id': null,
        'blake3': 'hash-new',
        'title': null,
        'pending_indexing': true,
        'pending_reason': 'not found in existing catalog',
        'locations': [
          {
            'root_id': 'root-a',
            'relative_path': 'unmatched/field-notes.pdf',
            'available': true,
          },
        ],
      },
    ],
  },
};
Map<String, dynamic> _job({String state = 'running'}) => {
  'job_id': 'job-a',
  'state': state,
  'stage': state == 'running' ? 'checking' : null,
  'scope': {'root_id': 'root-a'},
  'started_at': 1793971200000,
  'last_attempt_at': 1793971200000,
  'last_successful_at': null,
  'paused_for_future': false,
  'counts': {
    'roots_seen': 1,
    'files_seen': 14,
    'files_hashed': 9,
    'bytes_hashed': 94000000,
    'matched_unique_ids': 7,
    'matched_locations': 9,
    'unmatched_identity': 1,
    'settling_file_count': 4,
    'errors': 1,
  },
  'roots': [
    {
      'root_id': 'root-a',
      'paused': false,
      'unavailable': false,
      'complete': false,
      'candidates': 14,
      'pending': 1,
      'settling_file_count': 4,
      'errors': [
        {
          'code': 'file_changing',
          'path': 'manuals/draft.pdf',
          'message': 'This file is still changing.',
        },
      ],
    },
  ],
  'error': null,
};
void main() {
  test(
    'null title and document id retain the hash identity and relative path',
    () {
      final book = LinkedBook.fromJson({
        'doc_id': null,
        'blake3': 'hash-new',
        'title': null,
        'pending_indexing': true,
        'locations': [
          {
            'root_id': 'root-a',
            'relative_path': 'unmatched/field-notes.pdf',
            'blake3': 'hash-new',
            'available': true,
          },
        ],
      });
      expect(book.id, 'hash-new');
      expect(book.title, 'unmatched/field-notes.pdf');
    },
  );

  test(
    'preview is separate from registration and imported libraries are selectable targets',
    () async {
      var registrations = 0;
      final calls = <http.Request>[];
      final api = LinkedFolderApi(
        client: MockClient((request) async {
          calls.add(request);
          if (request.url.path == '/api/linked-folders/libraries') {
            return _ok([
              {'id': 'recon-library', 'title': 'Recon library'},
              {'id': 'built-library', 'title': 'Built library'},
            ]);
          }
          if (request.url.path == '/api/linked-folders/preview') {
            return _ok({
              'readable': true,
              'root': '/cache/docs',
              'exclusions': ['private'],
              'counts': null,
              'warnings': [],
            });
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/linked-folders/recon-library') {
            registrations++;
          }
          return _ok({});
        }),
      );
      final targets = await api.libraries();
      expect(targets.map((x) => x.id), ['recon-library', 'built-library']);
      final preview = await api.preview('/cache/docs', ['private']);
      expect(preview['readable'], isTrue);
      expect(preview['counts'], isNull);
      expect(registrations, 0);
      expect(jsonDecode(calls.last.body), {
        'root': '/cache/docs',
        'exclusions': ['private'],
      });
    },
  );
  testWidgets(
    'setup requires a fresh path check and selected library before linking',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var previews = 0, registrations = 0, checksStarted = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            path == '/api/linked-folders/libraries') {
          return _ok([
            {'id': 'recon-library', 'title': 'Recon library'},
            {'id': 'builder-target', 'title': 'Builder target'},
          ]);
        }
        if (request.method == 'POST' && path == '/api/linked-folders/preview') {
          previews++;
          final body = jsonDecode(request.body);
          return _ok({
            'readable': true,
            'root': body['root'],
            'exclusions': body['exclusions'],
            'counts': null,
            'warnings': [],
          });
        }
        if (request.method == 'POST' &&
            path == '/api/linked-folders/recon-library') {
          registrations++;
          return _ok({
            'registered': true,
            'local_config': {
              'roots': [_root()],
              'books': [],
            },
          });
        }
        if (request.method == 'POST' && path.endsWith('/checks')) {
          checksStarted++;
          return _ok(_job());
        }
        if (request.method == 'GET' && path.endsWith('/checks')) {
          return _ok({'active': _job(), 'latest': _job()});
        }
        if (request.method == 'GET' &&
            path == '/api/linked-folders/recon-library') {
          return _ok(_config());
        }
        return _ok({});
      });
      final controller = LinkedFolderController(
        api: LinkedFolderApi(client: client),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(CacheThemeId.light),
          home: LinkedFolderSetupPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('linked-folder-path')),
        '/cache/docs',
      );
      await tester.enterText(
        find.byKey(const ValueKey('linked-folder-exclusions')),
        'private',
      );
      await tester.tap(find.byKey(const ValueKey('linked-folder-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recon library').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('linked-folder-path')),
        'relative/folder',
      );
      await tester.tap(find.byKey(const ValueKey('check-linked-folder')));
      await tester.pumpAndSettle();
      expect(previews, 0);
      expect(
        find.text(
          'Enter a full folder path on this device and relative excluded folder names.',
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('linked-folder-path')),
        '/cache/docs',
      );
      await tester.enterText(
        find.byKey(const ValueKey('linked-folder-exclusions')),
        '../private',
      );
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('check-linked-folder')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('linked-folder-exclusions')),
        'private',
      );
      await tester.tap(find.byKey(const ValueKey('check-linked-folder')));
      await tester.pumpAndSettle();
      expect(previews, 1);
      expect(registrations, 0, reason: 'checking a folder does not link it');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('link-folder')))
            .onPressed,
        isNotNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('linked-folder-path')),
        '/cache/changed',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('link-folder')))
            .onPressed,
        isNull,
        reason: 'editing the path invalidates its previous check',
      );
      await tester.tap(find.byKey(const ValueKey('check-linked-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('link-folder')));
      await tester.pumpAndSettle();
      expect(registrations, 1);
      expect(checksStarted, 1);
      expect(find.text('Linked folders'), findsWidgets);
      expect(find.text('unmatched/field-notes.pdf'), findsWidgets);
      expect(
        find.text('Available location · unmatched/field-notes.pdf'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  test('duplicate root checks use the scoped durable jobs endpoint', () async {
    final requests = <http.Request>[];
    final api = LinkedFolderApi(
      client: MockClient((request) async {
        requests.add(request);
        return _ok({
          'job_id': 'same-job',
          'state': 'running',
          'scope': {'root_id': 'root-a'},
        });
      }),
    );
    final first = await api.check('recon-library', rootId: 'root-a');
    final second = await api.check('recon-library', rootId: 'root-a');
    expect(second.id, first.id);
    expect(requests.map((r) => r.url.path), [
      '/api/linked-folders/recon-library/checks',
      '/api/linked-folders/recon-library/checks',
    ]);
    expect(jsonDecode(requests.first.body), {'root_id': 'root-a'});
  });

  testWidgets('file retry and pause leave the current check running', (
    tester,
  ) async {
    var checking = false;
    var paused = false;
    var checkRequests = 0;
    var pauseRequests = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' &&
          path == '/api/linked-folders/recon-library') {
        final config = _config();
        final local = config['local_config'] as Map<String, dynamic>;
        (local['roots'] as List)[0] = {..._root(), 'paused': paused};
        return _ok(config);
      }
      if (request.method == 'GET' && path.endsWith('/checks')) {
        if (checking) {
          return _ok({
            'active': {..._job(), 'paused_for_future': paused},
            'latest': _job(),
          });
        }
        return _ok({
          'active': null,
          'latest': {
            ..._job(state: 'failed'),
            'roots': [
              {
                'root_id': 'root-a',
                'complete': false,
                'unavailable': false,
                'errors': [
                  {
                    'code': 'io_error',
                    'path': 'manuals/broken.pdf',
                    'message': 'Cache could not read this file.',
                  },
                ],
              },
            ],
          },
        });
      }
      if (request.method == 'POST' && path.endsWith('/checks')) {
        checkRequests++;
        checking = true;
        return _ok(_job());
      }
      if (request.method == 'POST' && path.endsWith('/pause')) {
        pauseRequests++;
        paused = true;
        return _ok({
          'paused': true,
          'paused_for_future': true,
          'current_check_finishes': true,
        });
      }
      return _ok({});
    });
    final controller = LinkedFolderController(
      api: LinkedFolderApi(client: client),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: LinkedFolderManagementPage(
          controller: controller,
          libraryId: 'recon-library',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(checkRequests, 1);
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(pauseRequests, 1);
    expect(
      find.text('Future checks paused. The current check will finish.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Unlink folder'))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'switching libraries ignores late results and unwatch stops hidden polling',
    (tester) async {
      final delayedA = Completer<http.Response>();
      var checksForB = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            path == '/api/linked-folders/library-a') {
          return delayedA.future;
        }
        if (request.method == 'GET' &&
            path == '/api/linked-folders/library-b') {
          return _ok({
            'local_config': {
              'roots': [
                {..._root(), 'id': 'root-b'},
              ],
              'books': [],
            },
          });
        }
        if (request.method == 'GET' && path.endsWith('/checks')) {
          checksForB++;
          return _ok({
            'active': {
              ..._job(),
              'scope': {'root_id': 'root-b'},
            },
            'latest': null,
          });
        }
        return _ok({});
      });
      final controller = LinkedFolderController(
        api: LinkedFolderApi(client: client),
        pollEvery: const Duration(seconds: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(CacheThemeId.light),
          home: const SizedBox(),
        ),
      );
      controller.watch('library-a');
      await tester.pump();
      controller.watch('library-b');
      await tester.pumpAndSettle();
      expect(controller.snapshot?.roots.single.id, 'root-b');
      delayedA.complete(
        _ok({
          'local_config': {
            'roots': [
              {..._root(), 'id': 'root-a'},
            ],
            'books': [],
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(
        controller.snapshot?.roots.single.id,
        'root-b',
        reason:
            'the late response for library A cannot replace library B state',
      );
      final readsAtUnwatch = checksForB;
      controller.unwatch('library-b');
      await tester.pump(const Duration(seconds: 5));
      expect(
        checksForB,
        readsAtUnwatch,
        reason: 'hidden pages leave no polling timer',
      );
      controller.dispose();
    },
  );

  testWidgets(
    'active checks poll only job status and reload library detail after completion',
    (tester) async {
      var libraryReads = 0, checkReads = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/api/linked-folders/recon-library') {
          libraryReads++;
          return _ok(_config());
        }
        if (request.method == 'GET' && request.url.path.endsWith('/checks')) {
          checkReads++;
          return _ok(
            checkReads < 3
                ? {'active': _job(), 'latest': _job()}
                : {'active': null, 'latest': _job(state: 'done')},
          );
        }
        return _ok({});
      });
      final controller = LinkedFolderController(
        api: LinkedFolderApi(client: client),
        pollEvery: const Duration(seconds: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(CacheThemeId.light),
          home: const SizedBox(),
        ),
      );
      controller.watch('recon-library');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(libraryReads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        libraryReads,
        1,
        reason: 'active progress reads only the compact job endpoint',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        libraryReads,
        2,
        reason: 'library details refresh once when the job finishes',
      );
      expect(controller.latestJob?.state, 'done');
      controller.dispose();
    },
  );
  testWidgets('a late action for A cannot cancel polling for B', (
    tester,
  ) async {
    final delayedAction = Completer<http.Response>();
    var checksForB = 0, libraryReadsForB = 0;
    final controller = LinkedFolderController(
      pollEvery: const Duration(seconds: 1),
      api: LinkedFolderApi(
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' &&
              path == '/api/linked-folders/library-a/checks') {
            return delayedAction.future;
          }
          if (request.method == 'GET' && path.endsWith('/checks')) {
            if (path.contains('/library-b/')) {
              checksForB++;
              return _ok({
                'active': {..._job(), 'job_id': 'job-b'},
                'latest': null,
              });
            }
            return _ok({'active': null, 'latest': null});
          }
          if (request.method == 'GET' &&
              path == '/api/linked-folders/library-b') {
            libraryReadsForB++;
            return _ok({
              'local_config': {
                'roots': [
                  {..._root(), 'id': 'root-b'},
                ],
                'books': [],
              },
            });
          }
          return _ok(_config());
        }),
      ),
    );
    controller.watch('library-a');
    await tester.pumpAndSettle();
    final action = controller.checkNow('library-a', rootId: 'root-a');
    await tester.pump();
    expect(controller.actionBusy, isTrue);
    controller.watch('library-b');
    await tester.pumpAndSettle();
    delayedAction.complete(_ok(_job()));
    await action;
    await tester.pumpAndSettle();
    expect(controller.snapshot?.roots.single.id, 'root-b');
    expect(controller.activeJob?.id, 'job-b');
    expect(controller.actionBusy, isFalse);
    final previousReads = checksForB;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(checksForB, previousReads + 1);
    expect(
      libraryReadsForB,
      1,
      reason: 'active checks still poll compact status only',
    );
    controller.dispose();
  });

  test('late library targets do not update a disposed controller', () async {
    final response = Completer<http.Response>();
    final controller = LinkedFolderController(
      api: LinkedFolderApi(client: MockClient((_) => response.future)),
    );
    final loading = controller.loadTargets();
    controller.dispose();
    response.complete(
      _ok([
        {'id': 'late', 'title': 'Late library'},
      ]),
    );
    await loading;
    expect(controller.targets, isEmpty);
  });
}
