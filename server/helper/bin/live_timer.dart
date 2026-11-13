import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';

/// Keeps live data (weather, alerts, fires) fresh on the server with no tab open. On a phone the system starts
/// app/lib/weather/background.dart every 30 minutes (runBackgroundUpdate); the core has no scheduler of its own, so this is that run
/// for Cache for Linux: a periodic `liveFetch` of every source that is on, for every watched place.
///
/// What to fetch comes from `live_plan.json` in the support folder, which WeatherState.publishPlan writes from the browser whenever
/// the sources that are on or the watched places change: `{"sources":[{"id","title","alerts"}],"places":[{"id","name","request"}]}`.
/// With no plan (weather never switched on) a tick does nothing.
///
/// A run mirrors WeatherState.updateNow: it has the core read the source folder again (`liveSources`), grants the fetch policy for the
/// sources in the plan, starts every download as a job (as the app does, so the helper keeps answering lines while the network
/// waits), and records the time in `live-catalogues/status.json`, the file the Weather status line reads. It then lists the
/// alerts and fires now in force near each place in `alerts_inbox.json` (support folder), newest last, once each, so a tab opened
/// later can see what arrived. Whether and how an alert pops up (Pop up for, quiet hours, the place's rule, the told list) stays
/// the browser's: it decides when a tab is open.
///
/// The helper answers one line at a time and this runs between lines, so a tick never overlaps a request.
class LiveTimer {
  LiveTimer(
    this.dispatcher, {
    required this.support,
    this.log,
    this.every = const Duration(minutes: 30),
    this.firstAfter = const Duration(minutes: 2),
    this.poll = const Duration(milliseconds: 500),
    this.timeout = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final CoreDispatcher dispatcher;
  final Directory support;
  final void Function(String message)? log;
  final Duration every;
  final Duration firstAfter;
  final Duration poll;

  /// How long one run waits for its downloads before it cancels the rest.
  final Duration timeout;
  final DateTime Function() _now;

  Timer? _timer;
  bool _running = false;

  /// The most alerts kept in the inbox; older ones drop off.
  static const int inboxKeep = 200;

  File get planFile => File('${support.path}/live_plan.json');
  File get statusFile => File('${support.path}/live-catalogues/status.json');
  File get inboxFile => File('${support.path}/alerts_inbox.json');

  void start() {
    _timer?.cancel();
    _timer = Timer(firstAfter, () {
      unawaited(runOnce());
      _timer = Timer.periodic(every, (_) => unawaited(runOnce()));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Map<String, dynamic>? _readJson(File f) {
    try {
      final j = jsonDecode(f.readAsStringSync());
      return j is Map ? j.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// One run. Returns how many downloads were made or found fresh, and how many failed; null when there was nothing to do.
  Future<({int ok, int failed})?> runOnce() async {
    if (_running) return null;
    _running = true;
    try {
      return await _run();
    } catch (e) {
      log?.call('live update failed: $e');
      return null;
    } finally {
      _running = false;
    }
  }

  Future<({int ok, int failed})?> _run() async {
    final plan = _readJson(planFile);
    if (plan == null) return null;
    final sources = [for (final s in (plan['sources'] as List? ?? const [])) if (s is Map && s['id'] is String) s.cast<String, dynamic>()];
    final places = [for (final p in (plan['places'] as List? ?? const [])) if (p is Map && p['request'] is Map) p.cast<String, dynamic>()];
    if (sources.isEmpty || places.isEmpty) return null;
    final now = _isoWithOffset(_now());
    try {
      // The core reads its source folder here; the browser wrote it.
      dispatcher.handle('liveSources', const {});
      dispatcher.handle('liveSetFetchPolicy', {
        'policy': {
          'online': true,
          'allow_metered': true,
          'metered': false,
          'enabled_sources': [for (final s in sources) s['id'] as String]..sort(),
        },
      });
    } catch (e) {
      // The core is not open yet (the server opens it first), or has no live data: try again next time.
      log?.call('live update waits: $e');
      return null;
    }
    var ok = 0, failed = 0;
    String? failure;
    final jobs = <int>{};
    final sync = <Map<String, dynamic>>[];
    for (final s in sources) {
      for (final p in places) {
        final request = {'source': s['id'], 'place': p['request'], 'now': now};
        try {
          final id = dispatcher.handle('liveFetchStart', {'request': request});
          if (id is int) {
            jobs.add(id);
          } else {
            sync.add(request);
          }
        } catch (e) {
          failed++;
          failure ??= '${s['title'] ?? s['id']} for ${p['name']} failed: $e';
        }
      }
    }
    for (final request in sync) {
      try {
        dispatcher.handle('liveFetch', {'request': request});
        ok++;
      } catch (e) {
        failed++;
        failure ??= '${request['source']} failed: $e';
      }
    }
    final stop = _now().add(timeout);
    while (jobs.isNotEmpty) {
      for (final id in jobs.toList()) {
        try {
          final p = (dispatcher.handle('jobProgress', {'job': id}) as Map).cast<String, dynamic>();
          final state = p['state'];
          if (state == 'running') continue;
          if (state == 'done') {
            ok++;
          } else {
            failed++;
            final e = p['error'];
            failure ??= e is Map ? '${e['message']}' : 'A download stopped';
          }
        } catch (_) {
          failed++;
        }
        try {
          dispatcher.handle('jobFree', {'job': id});
        } catch (_) {}
        jobs.remove(id);
      }
      if (jobs.isEmpty) break;
      if (_now().isAfter(stop)) {
        for (final id in jobs) {
          try {
            dispatcher.handle('jobCancel', {'job': id});
            dispatcher.handle('jobFree', {'job': id});
          } catch (_) {}
          failed++;
        }
        failure ??= 'Downloads took too long';
        jobs.clear();
        break;
      }
      await Future<void>.delayed(poll);
    }
    log?.call('live update: $ok done, $failed failed');
    _writeStatus(ok: ok, failure: failure);
    _recordAlerts(sources, places, now);
    return (ok: ok, failed: failed);
  }

  /// The file the Weather status line reads (WeatherState._saveStatus): times in milliseconds since the epoch.
  void _writeStatus({required int ok, required String? failure}) {
    try {
      final t = _now().millisecondsSinceEpoch;
      final old = _readJson(statusFile) ?? const {};
      final next = {
        'ok': ok > 0 ? t : old['ok'],
        'run': t,
        'online': t,
        'failure': failure,
      };
      statusFile.parent.createSync(recursive: true);
      _writeAtomic(statusFile, jsonEncode(next));
    } catch (e) {
      log?.call('live status not written: $e');
    }
  }

  /// Adds the alerts and fires in force near each place to the inbox, once each (by the item's address and the place).
  void _recordAlerts(List<Map<String, dynamic>> sources, List<Map<String, dynamic>> places, String now) {
    try {
      final inbox = <Map<String, dynamic>>[];
      try {
        final j = jsonDecode(inboxFile.readAsStringSync());
        if (j is List) inbox.addAll([for (final e in j) if (e is Map) e.cast<String, dynamic>()]);
      } catch (_) {}
      final have = {for (final e in inbox) '${e['address']}|${e['place']}'};
      var added = 0;
      for (final s in sources) {
        if (s['alerts'] != true) continue;
        for (final p in places) {
          final Map<String, dynamic> got;
          try {
            got = (dispatcher.handle('liveGet', {
              'request': {'source': s['id'], 'place': p['request'], 'now': now},
            }) as Map).cast<String, dynamic>();
          } catch (_) {
            continue;
          }
          if (got['expired'] == true) continue;
          for (final i in (got['items'] as List? ?? const [])) {
            if (i is! Map || i['none_active'] == true) continue;
            final address = '${i['address'] ?? ''}';
            if (address.isEmpty || !have.add('$address|${p['id']}')) continue;
            final fields = (i['fields'] is Map) ? (i['fields'] as Map) : const {};
            inbox.add({
              'at': _now().toUtc().toIso8601String(),
              'source': s['id'],
              'place': p['id'],
              'place_name': p['name'],
              'address': address,
              'label': '${i['label'] ?? ''}',
              'summary': [for (final e in fields.entries) if (e.value != null) '${e.key} ${e.value}'].take(2).join(' · '),
            });
            added++;
          }
        }
      }
      if (added == 0) return;
      final kept = inbox.length > inboxKeep ? inbox.sublist(inbox.length - inboxKeep) : inbox;
      _writeAtomic(inboxFile, jsonEncode(kept));
      log?.call('live update: $added new alert(s) recorded');
    } catch (e) {
      log?.call('alert inbox not written: $e');
    }
  }

  static void _writeAtomic(File f, String text) {
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(f.path);
  }
}

/// The time with its offset ("2026-11-09T14:03:00-07:00"), as the app's isoWithOffset writes it for the core.
String _isoWithOffset(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final off = t.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final abs = off.abs();
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
      '$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
}
