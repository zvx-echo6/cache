import 'package:cache/platform/launch_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logs once, when both are ready, with the time of the later one', () async {
    final lines = <String>[];
    final c = LaunchClock(lines.add)..begin();
    c.appReady();
    expect(lines, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    c.coreReady();
    c.coreReady();
    c.appReady();
    expect(lines, hasLength(1));
    expect(lines.single, matches(RegExp(r'^Launch screen: 0\.\d s \(app ready at 0\.\d s, core ready at 0\.\d s\)$')));
  });

  test('the core first, then the app', () {
    final lines = <String>[];
    final c = LaunchClock(lines.add)..begin();
    c.coreReady();
    expect(lines, isEmpty);
    c.appReady();
    expect(lines, hasLength(1));
  });
}
