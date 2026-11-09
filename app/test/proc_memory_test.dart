import 'package:cache/platform/app_log.dart';
import 'package:cache/platform/ask_diagnostics.dart';
import 'package:cache/platform/memory.dart';
import 'package:flutter_test/flutter_test.dart';

const _status = '''Name:\tco.cache
Umask:\t0077
State:\tR (running)
VmPeak:\t 9876543 kB
VmRSS:\t 2402304 kB
RssAnon:\t 1228800 kB
RssFile:\t 1171456 kB
RssShmem:\t    2048 kB
VmSwap:\t 2215936 kB
Threads:\t42
''';

const _meminfo = '''MemTotal:        7654321 kB
MemFree:          123456 kB
MemAvailable:    1048576 kB
SwapTotal:       4194304 kB
SwapFree:        2097152 kB
''';

void main() {
  test('status: RSS with anon and file parts, and swap', () {
    expect(procStatusSummary(_status), 'RSS 2346 MB (anon 1200 MB, file 1144 MB), swap 2164 MB');
  });

  test('status without the breakdown or swap keeps what it has', () {
    expect(procStatusSummary('VmRSS:\t 1048576 kB\n'), 'RSS 1024 MB');
    expect(procStatusSummary('VmRSS:\t 1048576 kB\nRssAnon:\t 524288 kB\n'), 'RSS 1024 MB (anon 512 MB)');
    expect(procStatusSummary('Name:\tx\n'), 'memory unknown');
    expect(procStatusSummary(''), 'memory unknown');
  });

  test('counters take only the memory names, in kB, and skip bad values', () {
    expect(procMemoryCounters(_status), {
      'VmRSS_kb': 2402304,
      'RssAnon_kb': 1228800,
      'RssFile_kb': 1171456,
      'VmSwap_kb': 2215936,
    });
    expect(procMemoryCounters(_meminfo), {'MemAvailable_kb': 1048576, 'SwapFree_kb': 2097152});
    expect(procMemoryCounters('VmRSS: 12 kB\nSwapFree: invalid\n'), {'VmRSS_kb': 12});
  });

  test('stat fault counters tolerate spaces and parentheses in the command', () {
    final fields = List<String>.generate(13, (i) => '${i + 3}');
    fields[0] = 'R';
    expect(procProcessCounters('123 (name with ) spaces) ${fields.join(' ')}'), {
      'minor_faults': 10,
      'major_faults': 12,
      'user_ticks': 14,
      'system_ticks': 15,
    });
    expect(procProcessCounters(''), isEmpty);
    expect(procProcessCounters('123 (name) R bad'), isEmpty);
  });

  test('Ask progress samples run only from the Detailed level', () {
    expect(appLog.writes(LogLevel.detailed), isFalse);
    expect(AskDiagnostics.start(1), isNull);
  });
}
