// Settings > Storage in the browser: every kind's size comes from the server (GET /api/library/storage), as the phone measures its own.

import 'dart:convert';

import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/storage_usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'browse/web_fakes.dart';

void main() {
  test('readServerStorage reads the bytes of each kind', () async {
    Uri? asked;
    final client = MockClient((r) async {
      asked = r.url;
      return http.Response(jsonEncode({'ok': true, 'result': {'kinds': {'library': 1230, 'models': 4000}}}), 200);
    });
    expect(await readServerStorage(client: client), {'library': 1230, 'models': 4000});
    expect(asked?.path, '/api/library/storage');
    expect(await readServerStorage(client: MockClient((r) async => http.Response('{}', 404))), isNull);
    expect(await readServerStorage(client: MockClient((r) async => throw Exception('down'))), isNull);
  });

  test('the browser\'s Storage rows get non-zero sizes from the server', () async {
    final api = FakeDeviceApi()
      ..itemList = [item('a.zim', bytes: 1000)]
      ..spaceInfo = const DeviceSpaceInfo(free: 11 << 30, total: 61 << 30);
    final device = DeviceLibrary(api: api, fs: MemoryAppFs(), leaveWarning: (_) {});
    DataKind kind(String id) => DataKind(id: id, label: id, icon: Icons.folder);
    final u = StorageUsage(
      kinds: [kind('library'), kind('models'), kind('regions'), kind('videos'), kind('notebooks')],
      freeIn: () => null,
      device: device,
      deviceKinds: () async => {'library': 1230, 'models': 4000, 'regions': 560, 'videos': 7000, 'notebooks': 89},
    );
    await u.measure();
    expect([for (final k in ['library', 'models', 'regions', 'videos', 'notebooks']) u.bytesOf(k)], [1230, 4000, 560, 7000, 89]);
    expect(u.usedBytes, 1230 + 4000 + 560 + 7000 + 89);
    device.dispose();
  });

  test('when the server cannot say, the Library row falls back to what is installed', () async {
    final api = FakeDeviceApi()..itemList = [item('a.zim', bytes: 1000)];
    final device = DeviceLibrary(api: api, fs: MemoryAppFs(), leaveWarning: (_) {});
    final u = StorageUsage(kinds: [DataKind(id: 'library', label: 'Library', icon: Icons.folder)], freeIn: () => null, device: device, deviceKinds: () async => null);
    await u.measure();
    expect(u.bytesOf('library'), 1000);
    device.dispose();
  });
}
