import 'dart:convert';

import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/browse/web/compression_settings_page.dart';
import 'package:cache/browse/web/device_api.dart' show DeviceException;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _SettingsApi implements BuildCompressionApi {
  _SettingsApi(this.settings);
  BuildCompressionSettings settings;
  int gets = 0;
  bool failFirstGet = false;
  int puts = 0;

  @override
  Future<BuildCompressionSettings> getCompressionSettings() async {
    gets++;
    if (failFirstGet && gets == 1) throw const DeviceException('unreachable', 'unreachable');
    return settings;
  }

  @override
  Future<BuildCompressionSettings> putCompressionSettings(BuildCompressionSettings value) async {
    puts++;
    settings = value;
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ThemeData _theme() => ThemeData(
  extensions: const [
    CacheTokens(
      background: Color(0xfffafafa),
      surface: Colors.white,
      text: Colors.black,
      secondary: Colors.black54,
      accent: Colors.blue,
      primary: Colors.blue,
      onPrimary: Colors.white,
      emergency: Colors.red,
      warning: Colors.orange,
      ok: Colors.green,
    ),
  ],
);

void main() {
  test('settings API reads and writes the standard envelope', () async {
    final calls = <http.Request>[];
    final api = HttpBuildApi(
      client: MockClient((request) async {
        calls.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'result': {
                'compression': {'level': 'smaller_scans', 'preset': 'balanced'},
                'ask_when_one': false,
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'ok': true, 'result': jsonDecode(request.body)}), 200);
      }),
    );

    final read = await api.getCompressionSettings();
    expect(read.compression, CompressionChoice.balanced);
    expect(read.askWhenOne, isFalse);
    final written = await api.putCompressionSettings(const BuildCompressionSettings(compression: CompressionChoice.smallest, askWhenOne: true));
    expect(written.compression, CompressionChoice.smallest);
    expect(calls.map((r) => '${r.method} ${r.url.path}'), ['GET /api/build/settings', 'PUT /api/build/settings']);
    expect(jsonDecode(calls.last.body), {
      'compression': {'level': 'smaller_scans', 'preset': 'smallest'},
      'ask_when_one': true,
    });
  });

  testWidgets('settings page retries a load and saves the selected preset explicitly', (tester) async {
    final api = _SettingsApi(const BuildCompressionSettings(compression: CompressionChoice.lossless))..failFirstGet = true;
    final controller = BuildController(api: api, poll: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: CompressionSettingsPage(build: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('High quality'), findsNothing);
    await tester.tap(find.text('Smaller scans'));
    await tester.pumpAndSettle();
    expect(find.text('Balanced'), findsOneWidget);
    expect(api.puts, 0);
    await tester.tap(find.text('Smallest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.puts, 1);
    expect(api.settings.compression, CompressionChoice.smallest);
    expect(find.text('Saved.'), findsOneWidget);
    controller.dispose();
  });
}
