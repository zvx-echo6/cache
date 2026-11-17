// Settings > Storage in the browser: used and free come from the server (the Library's own figures), not from folders a browser
// does not have.

import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/storage_usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/web_fakes.dart';

void main() {
  test('with a device library, Storage measures what the server holds and the server\'s free space', () async {
    final api = FakeDeviceApi()
      ..itemList = [item('a.zim', bytes: 3 << 30), item('proof', kind: 'library', bytes: 2 << 30)]
      ..spaceInfo = const DeviceSpaceInfo(free: 11 << 30, total: 61 << 30);
    final device = DeviceLibrary(api: api, fs: MemoryAppFs(), leaveWarning: (_) {});
    final u = StorageUsage(
      kinds: [DataKind(id: 'library', label: 'Library', icon: Icons.menu_book_outlined)],
      freeIn: () => null,
      device: device,
    );
    await u.measure();
    expect(u.measured, isTrue);
    expect(u.freeBytes, 11 << 30);
    expect(u.totalBytes, 61 << 30);
    expect(u.bytesOf('library'), 5 << 30);
    expect(u.usedBytes, 5 << 30);
    device.dispose();
  });

  test('a server that cannot be reached leaves free space unknown and measures nothing', () async {
    final api = FakeDeviceApi()..failWith = const DeviceException('unreachable', 'x');
    final device = DeviceLibrary(api: api, fs: MemoryAppFs(), leaveWarning: (_) {});
    final u = StorageUsage(kinds: [DataKind(id: 'library', label: 'Library', icon: Icons.menu_book_outlined)], freeIn: () => null, device: device);
    await u.measure();
    expect(u.freeBytes, isNull);
    expect(u.usedBytes, 0);
    device.dispose();
  });
}
