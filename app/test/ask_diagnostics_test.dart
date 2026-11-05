import 'package:flutter_test/flutter_test.dart';
import 'package:cache/platform/ask_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('admits only numeric memory counters', () {
    expect(procMemoryCounters('Name: private\nVmRSS: 1234 kB\nVmSwap: 56 kB\nMemAvailable: 987 kB\nSwapFree: invalid\n'), {
      'VmRSS_kb': 1234,
      'VmSwap_kb': 56,
      'MemAvailable_kb': 987,
    });
  });
  test('process offsets tolerate spaces and parentheses in command', () {
    final fields = List<String>.generate(13, (i) => '${i + 3}');
    fields[0] = 'R';
    expect(procProcessCounters('123 (name with ) spaces) ${fields.join(' ')}'), {
      'minor_faults': 10,
      'major_faults': 12,
      'user_ticks': 14,
      'system_ticks': 15,
    });
  });
  test('unavailable counters remain optional', () {
    expect(procProcessCounters(''), isEmpty);
    expect(procProcessCounters('123 (name) R bad'), isEmpty);
  });
  test('sampling follows the diagnostic build flag and stops cleanly', () {
    final diagnostics = AskDiagnostics.start(1);
    expect(diagnostics != null, kAskDiagnostics);
    diagnostics?.stop();
  });
}
