import '../../downloads/download_row.dart';
import '../../video/video_state.dart';

/// A video download as its row shows it. A stopped download (Pause, or a Stop from before) is Paused: it continues from its file.
DlState videoDl(DownloadTask t) {
  final total = t.total > 0 ? t.total : (t.expectedSize ?? 0);
  if (t.pausing) return DlState(DlPhase.pausing, done: t.done, total: total);
  return switch (t.phase) {
    DownloadPhase.running => t.done == 0 && t.total == 0
        ? DlState(DlPhase.starting, total: total)
        : DlState(DlPhase.running, done: t.done, total: total, speed: DlMeter.speed('video:${t.key}', t.done)),
    DownloadPhase.done => DlState(DlPhase.done, total: total),
    DownloadPhase.cancelled => t.blockedByMobile
        ? DlState(DlPhase.waiting, done: t.done, total: total, waitLine: 'Waiting for Wi-Fi')
        : DlState(DlPhase.paused, done: t.done, total: total),
    DownloadPhase.failed => t.blockedByMobile
        ? DlState(DlPhase.waiting, done: t.done, total: total, waitLine: 'Waiting for Wi-Fi')
        : DlState(DlPhase.failed, done: t.done, total: total, reason: DlReason.of(t.error)),
  };
}

/// What a video row's controls do.
DlActions videoActions(VideoState v, DownloadTask t) => DlActions(
      pause: () => v.pause(t),
      resume: () => v.retry(t, anyway: t.blockedByMobile),
      remove: () => v.remove(t),
    );
