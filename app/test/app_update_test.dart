import 'dart:convert';

import 'package:cache/update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const file = {
    'format': 1,
    'version': '1.0.30',
    'build': 30,
    'published': '2026-11-02',
    'notes': 'Fixes.',
    'ios': {'build': 30, 'link': 'https://testflight.apple.com/join/abc'},
    'android': {'build': 29, 'link': 'https://play.google.com/store/apps/details?id=com.happylittlellc.cache'},
  };

  test('the release file says when a newer build is out for this phone, with its link', () async {
    final ios = ReleaseFileSource(installedBuild: 29, platform: 'ios', fetch: (_) async => jsonEncode(file));
    final u = (await ios.check())!;
    expect((u.version, u.build, u.notes, u.published), ('1.0.30', 30, 'Fixes.', '2026-11-02'));
    expect(u.link.toString(), 'https://testflight.apple.com/join/abc');
    // Play has not got build 30 yet: no update on Android
    expect(await ReleaseFileSource(installedBuild: 29, platform: 'android', fetch: (_) async => jsonEncode(file)).check(), isNull);
    // the newest installed: nothing
    expect(await ReleaseFileSource(installedBuild: 30, platform: 'ios', fetch: (_) async => jsonEncode(file)).check(), isNull);
  });

  test('a platform without its own block uses the top-level build', () {
    final s = ReleaseFileSource(installedBuild: 29, platform: 'ios');
    expect(s.parse(jsonEncode({'format': 1, 'version': '1.0.30', 'build': 30}))?.build, 30);
  });

  test('no connection, another format or a damaged file is no update', () async {
    expect(await ReleaseFileSource(installedBuild: 1, platform: 'ios', fetch: (_) async => throw Exception('offline')).check(), isNull);
    expect(await ReleaseFileSource(installedBuild: 1, platform: 'ios', fetch: (_) async => '{"format": 2, "version": "9", "build": 99}').check(), isNull);
    expect(await ReleaseFileSource(installedBuild: 1, platform: 'ios', fetch: (_) async => 'not json').check(), isNull);
  });

  test('the file lives on cached.info', () {
    expect(kAppReleaseUrl, 'https://data.cached.info/app/latest.json');
  });
}
