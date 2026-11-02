import 'package:flutter/material.dart';

import '../downloads/download_row.dart';
import '../screens/download_confirm.dart' show openStorageForSpace;
import '../sources/libraries_state.dart';
import 'browse_state.dart';
import 'opds.dart';

/// A ZIM download (a library from the catalogue, Wikipedia) as its row shows it.
DlState zimDl(ZimTransfer? t, {int size = 0}) {
  if (t == null) return DlState(DlPhase.idle, total: size);
  final total = t.total > 0 ? t.total : t.entry.size;
  return switch (t.phase) {
    TransferPhase.starting => DlState(DlPhase.starting, done: t.done, total: total),
    TransferPhase.downloading =>
      t.done == 0 ? DlState(DlPhase.starting, total: total) : DlState(DlPhase.running, done: t.done, total: total, speed: DlMeter.speed('zim:${t.entry.id}', t.done)),
    TransferPhase.paused => DlState(DlPhase.paused, done: t.done, total: total),
    TransferPhase.failed => DlState(DlPhase.failed, done: t.done, total: total, reason: DlReason.of(t.error)),
    TransferPhase.blockedByMobileData => DlState(DlPhase.waiting, done: t.done, total: total, waitLine: 'Waiting for Wi-Fi'),
    TransferPhase.verifying => DlState(DlPhase.verifying, done: t.done, total: total),
    TransferPhase.adding => DlState(DlPhase.unpacking, done: t.done, total: total),
  };
}

/// What a ZIM row's controls do.
DlActions zimActions(BuildContext context, BrowseState b, CatalogEntry e, {VoidCallback? download, String label = 'Download'}) {
  final t = b.transfers[e.id];
  return DlActions(
    download: download,
    downloadLabel: label,
    pause: () => b.pause(e),
    resume: () => t?.phase == TransferPhase.paused ? b.resume(e) : b.download(e, replaces: t?.replaces),
    remove: () => b.cancel(e),
    downloadNow: () => b.download(e, replaces: t?.replaces, allowMobile: true),
    freeSpace: openStorageForSpace == null ? null : () => openStorageForSpace!(context),
  );
}

/// A library being added (from a link, a file or the built-in guide) as its row shows it: the download, then unpacking and putting
/// it in place.
DlState addDl(AddTask t) {
  if (t.blockedByMobileData && t.error != null) return DlState(DlPhase.waiting, waitLine: 'Waiting for Wi-Fi');
  if (t.paused) return DlState(DlPhase.paused, done: t.done, total: t.total);
  if (t.error != null) {
    return t.step == AddStep.downloading
        ? DlState(DlPhase.failed, done: t.done, total: t.total, reason: DlReason.of(t.error))
        : DlState(DlPhase.failed, reasonText: _lower(t.error!));
  }
  return switch (t.step) {
    AddStep.downloading => t.done == 0
        ? DlState(DlPhase.starting, total: t.total)
        : DlState(DlPhase.running, done: t.done, total: t.total, speed: DlMeter.speed('add:${t.link ?? t.name}', t.done)),
    AddStep.checking => const DlState(DlPhase.verifying),
    AddStep.unpacking || AddStep.indexing || AddStep.swapping => const DlState(DlPhase.unpacking),
  };
}

String _lower(String s) {
  final t = s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1);
}

/// What an add row's controls do: Pause and Resume while it downloads, Resume (Try again) after a failed download, Remove.
DlActions addActions(LibrariesState s, AddTask t, {VoidCallback? downloadNow}) => DlActions(
      pause: t.step == AddStep.downloading ? s.pauseAdd : null,
      resume: t.again == null ? null : () => s.resumeAdd(),
      remove: () => s.removeAdd(),
      downloadNow: downloadNow,
    );
