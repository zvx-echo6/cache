import 'dart:convert';
import 'package:cache/linked_folders/linked_folders.dart';
import 'package:cache/linked_folders/linked_folder_management.dart';
import 'package:cache/linked_folders/linked_folder_setup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cache/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'shot_kit.dart';

MockClient _client({
  bool unavailable = false,
  bool complete = false,
}) => MockClient((request) async {
  if (request.method == 'GET' &&
      request.url.path == '/api/linked-folders/libraries') {
    return http.Response(
      jsonEncode({
        'ok': true,
        'result': [
          {'id': 'recon-library', 'title': 'Recon library'},
        ],
      }),
      200,
    );
  }
  final root = {
    'id': 'root-a',
    'label': 'Field manuals',
    'mode': 'keep',
    'path': '/library/field',
    'exclusions': ['private'],
    'paused': !complete && !unavailable,
    'state': unavailable ? 'permission_lost' : 'ready',
  };
  final job = {
    'job_id': 'job-a',
    'state': unavailable
        ? 'failed'
        : complete
        ? 'done'
        : 'running',
    'stage': complete || unavailable ? null : 'checking',
    'scope': {'root_id': 'root-a'},
    'started_at': 1793971200000,
    'finished_at': complete || unavailable ? 1793974800000 : null,
    'last_attempt_at': 1793971200000,
    'last_successful_at': complete ? 1793974800000 : null,
    'paused_for_future': !complete && !unavailable,
    'counts': {
      'files_seen': 14,
      'files_hashed': 9,
      'bytes_hashed': 94000000,
      'matched_unique_ids': 7,
      'matched_locations': 9,
      'unmatched_identity': 1,
      'settling_file_count': 4,
      'errors': unavailable
          ? 1
          : complete
          ? 0
          : 1,
    },
    'roots': [
      {
        'root_id': 'root-a',
        'paused': false,
        'unavailable': unavailable,
        'complete': complete,
        'candidates': 14,
        'pending': 1,
        'settling_file_count': 4,
        'errors': unavailable
            ? [
                {
                  'code': 'permission_denied',
                  'path': '',
                  'message':
                      'Cache cannot read this folder. Restore access, then check again.',
                },
              ]
            : complete
            ? []
            : [
                {
                  'code': 'file_changing',
                  'path': 'manuals/draft.pdf',
                  'message': 'This file is still changing.',
                },
              ],
      },
    ],
    'error': unavailable
        ? {
            'code': 'permission_denied',
            'message':
                'Cache cannot read this folder. Restore access, then check again.',
          }
        : null,
  };
  if (request.method == 'GET' && request.url.path.endsWith('/checks')) {
    return http.Response(
      jsonEncode({
        'ok': true,
        'result': {
          'active': complete || unavailable ? null : job,
          'latest': complete || unavailable ? job : null,
        },
      }),
      200,
    );
  }
  if (request.method == 'GET') {
    return http.Response(
      jsonEncode({
        'ok': true,
        'result': {
          'local_config': {
            'roots': [root],
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
                    'available': !unavailable,
                  },
                  {
                    'root_id': 'root-a',
                    'relative_path': 'water-copy.pdf',
                    'blake3': 'hash-a',
                    'available': !unavailable,
                  },
                ],
              },
              {
                'doc_id': 'book-new',
                'blake3': 'hash-new',
                'title': 'New field notes',
                'pending_indexing': true,
                'pending_reason': 'not found in existing catalog',
                'locations': [
                  {
                    'root_id': 'root-a',
                    'relative_path': 'unmatched/field-notes.pdf',
                    'available': !unavailable,
                  },
                ],
              },
            ],
          },
          'capabilities': {'index_new_pdfs': false},
        },
      }),
      200,
    );
  }
  return http.Response('{"ok":true,"result":{}}', 200);
});
void main() {
  setUpAll(loadShotFonts);
  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('linked folder setup and active progress ${theme.name}', (
      tester,
    ) async {
      phone(tester, size: const Size(1440, 1000), ratio: 1);
      final controller = LinkedFolderController(
        api: LinkedFolderApi(client: _client()),
      );
      await tester.pumpWidget(
        shotApp(
          LinkedFolderSetupPage(controller: controller),
          theme: theme,
          insets: EdgeInsets.zero,
        ),
      );
      await tester.pumpAndSettle();
      await snap(tester, 'linked-folders', '1440-setup-${theme.name}');
      await tester.pumpWidget(
        shotApp(
          LinkedFolderManagementPage(
            controller: controller,
            libraryId: 'recon-library',
          ),
          theme: theme,
          insets: EdgeInsets.zero,
        ),
      );
      await tester.pumpAndSettle();
      await snap(tester, 'linked-folders', '1440-progress-${theme.name}');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
  testWidgets('linked folder completed and permission-lost states', (
    tester,
  ) async {
    phone(tester, size: const Size(1440, 1000), ratio: 1);
    final complete = LinkedFolderController(
      api: LinkedFolderApi(client: _client(complete: true)),
    );
    await tester.pumpWidget(
      shotApp(
        LinkedFolderManagementPage(
          controller: complete,
          libraryId: 'recon-library',
        ),
        theme: CacheThemeId.light,
        insets: EdgeInsets.zero,
      ),
    );
    await tester.pumpAndSettle();
    await snap(tester, 'linked-folders', '1440-completed-unmatched-settling');
    await tester.pumpWidget(const SizedBox());
    complete.dispose();
    final offline = LinkedFolderController(
      api: LinkedFolderApi(client: _client(unavailable: true)),
    );
    await tester.pumpWidget(
      shotApp(
        LinkedFolderManagementPage(
          controller: offline,
          libraryId: 'recon-library',
        ),
        theme: CacheThemeId.light,
        insets: EdgeInsets.zero,
      ),
    );
    await tester.pumpAndSettle();
    await snap(tester, 'linked-folders', '1440-permission-lost');
    await tester.pumpWidget(const SizedBox());
    offline.dispose();
  });
}
