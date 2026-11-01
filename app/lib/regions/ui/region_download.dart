import 'package:flutter/material.dart';

import '../../downloads/download_row.dart';
import '../../maps/ui/format.dart';
import '../../screens/download_confirm.dart' show openStorageForSpace;
import '../regions_state.dart';
import 'region_actions.dart';

/// A region as one download (UX-downloads-29): the sum of its parts with one bar. Pause holds every region download (the running
/// part stops, the others wait); Resume carries on in order.
DlState regionDl(RegionsState regions, LocalRegion l) {
  final parts = l.parts;
  final done = parts.fold<int>(0, (s, p) => s + p.bytes);
  final total = regions.totalBytesOf(l) ?? 0;
  if (regions.pausing && l.phase != RegionPhase.ready) return DlState(DlPhase.pausing, done: done, total: total);
  if (regions.resuming && l.phase != RegionPhase.ready) return DlState(DlPhase.starting, done: done, total: total);
  switch (l.phase) {
    case RegionPhase.ready:
      return DlState(DlPhase.done, done: l.bytes, total: l.bytes);
    case RegionPhase.failed:
      final p = parts.where((p) => p.state == PartState.failed).firstOrNull;
      return DlState(DlPhase.failed, done: done, total: total, reason: p == null ? null : partReason(p), part: p?.name);
    case RegionPhase.stopped:
      return DlState(DlPhase.paused, done: done, total: total);
    case RegionPhase.paused:
      if (regions.held) return DlState(DlPhase.paused, done: done, total: total);
      // Paused by the engine (no connection it may use, too little space): it goes on by itself, and says why.
      return DlState(DlPhase.failed, done: done, total: total, reason: DlReason.of(regions.paused), part: l.parts.where((p) => !p.complete).firstOrNull?.name);
    case RegionPhase.downloading:
      final running = l.downloadingPart;
      if (running == null || done == 0) {
        // Region downloads go one at a time: one that has not begun waits for the one that has.
        final other = regions.local
            .where((o) => o.id != l.id && o.phase == RegionPhase.downloading && o.parts.any((p) => p.state == PartState.downloading && p.bytes > 0))
            .firstOrNull;
        if (other != null) return DlState(DlPhase.waiting, done: done, total: total, waitingFor: other.name);
        if (done == 0) return DlState(DlPhase.starting, done: done, total: total);
      }
      return DlState(DlPhase.running, done: done, total: total, speed: DlMeter.speed('region:${l.id}', done));
  }
}

/// Why a part stopped, as the row says it.
DlReason partReason(RegionPartStatus p) => p.noSpace ? DlReason.full : DlReason.of(p.problem);

/// One part of a region on its page: the running part has its own line, bar and Pause; a part not started yet waits for the one
/// running; a stopped or failed part offers Resume (or Free space); the others read as they always have.
DlState partDl(RegionsState regions, LocalRegion l, RegionPartStatus p, {bool own = false}) {
  final running = l.downloadingPart;
  bool first() => own || identical(p, firstUnfinished(l));
  final total = p.totalBytes ?? 0;
  if (regions.pausing && !p.complete && p.state == PartState.downloading) return DlState(DlPhase.pausing, done: p.bytes, total: total);
  if (regions.resuming && !p.complete && first()) return DlState(DlPhase.starting, done: p.bytes, total: total);
  return switch (p.state) {
    PartState.ready || PartState.notAvailable => DlState(DlPhase.done, done: p.bytes, total: p.bytes),
    PartState.downloading => DlState(DlPhase.running, done: p.bytes, total: total, speed: DlMeter.speed('part:${l.id}:${p.kind.name}', p.bytes)),
    PartState.waiting => running == null
        ? DlState(DlPhase.starting, done: p.bytes, total: total)
        : DlState(DlPhase.waiting, done: p.bytes, total: total, waitingFor: running.name),
    PartState.failed => DlState(DlPhase.failed, done: p.bytes, total: total, reason: partReason(p)),
    PartState.stopped => first()
        ? DlState(DlPhase.paused, done: p.bytes, total: total)
        : DlState(DlPhase.waiting, done: p.bytes, total: total, waitingFor: firstUnfinished(l)?.name),
    PartState.paused => !first()
        ? DlState(DlPhase.waiting, done: p.bytes, total: total, waitingFor: firstUnfinished(l)?.name)
        : regions.held
            ? DlState(DlPhase.paused, done: p.bytes, total: total)
            : DlState(DlPhase.failed, done: p.bytes, total: total, reason: DlReason.of(regions.paused)),
  };
}

/// The first part of [l] that is not complete (the one a Resume starts with).
RegionPartStatus? firstUnfinished(LocalRegion l) => l.parts.where((p) => !p.complete).firstOrNull;

/// What a region's controls do: Pause and Resume hold or carry on every region download; Resume on a failed region tries it again;
/// Remove deletes the region (asking first); a full device opens Storage.
DlActions regionDlActions(BuildContext context, RegionsState regions, LocalRegion l) {
  final m = ScaffoldMessenger.of(context);
  return DlActions(
    pause: () => regions.pauseAll(),
    resume: () {
      if (regions.held) {
        regions.resumeAll().catchError((_) {});
      } else {
        carryOnNow(m, regions, l.id, name: l.name, again: l.phase == RegionPhase.failed);
      }
    },
    remove: () async {
      await askDeleteRegion(context, regions, l);
    },
    removeAsks: true,
    freeSpace: openStorageForSpace == null ? null : () => openStorageForSpace!(context),
  );
}

/// "Idaho · 41%": the region's summary above its parts.
String regionSummary(LocalRegion l) => '${l.name} · ${(l.fraction * 100).clamp(0, 99).floor()}%';

/// "On this device · 1.8 GB" for a region that is all here (with "Places not available yet" when nothing is published for it).
String regionDoneLine(LocalRegion l, {required String placesNote}) =>
    ['On this device', formatBytes(l.bytes), if (l.placesNotAvailable) placesNote].join(' · ');
