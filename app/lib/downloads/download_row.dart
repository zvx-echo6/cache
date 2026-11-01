import 'package:flutter/material.dart';

import '../maps/ui/format.dart';
import '../screens/hold.dart';
import '../theme.dart';

/// Where one download stands, in the one pattern every download in the app shows (UX-downloads-29): a title, one status line,
/// a bar while it is active, and one trailing control for the state.
enum DlPhase { idle, starting, running, pausing, paused, failed, waiting, verifying, unpacking, done }

/// Why a download stopped, in the plain words the row shows after "Stopped: ".
enum DlReason {
  noConnection('no connection'),
  full('this device is full'),
  noAnswer('server did not answer'),
  cutOff('download was cut off');

  const DlReason(this.words);
  final String words;

  /// The reason for an error text or code from any download engine (the codes and messages they already use).
  static DlReason of(Object? error) {
    final s = '${error ?? ''}'.toLowerCase();
    if (s.contains('no_space') || s.contains('out of space') || s.contains('free space') || s.contains('full')) return DlReason.full;
    if (s.contains('too long') || s.contains('timed out') || s.contains('answered') || s.contains('redirect') || s.contains('no longer on') ||
        s.contains('did not say') || s.contains('http ')) {
      return DlReason.noAnswer;
    }
    if (s.contains('connection') || s.contains('offline') || s.contains('network') || s.contains('fetch_failed') || s.contains('host')) {
      return DlReason.noConnection;
    }
    return DlReason.cutOff;
  }
}

/// One download as a row shows it.
class DlState {
  const DlState(this.phase, {this.done = 0, this.total = 0, this.speed, this.reason, this.reasonText, this.waitingFor, this.waitLine, this.part});

  final DlPhase phase;
  final int done;

  /// 0 when the size is not known.
  final int total;

  /// Bytes a second, once there are 5 seconds of data; null before.
  final double? speed;
  final DlReason? reason;

  /// A reason in the engine's own plain words when it is not one of [DlReason] (a model that needs an account); shown as is.
  final String? reasonText;

  /// What a waiting download waits for: "Idaho map", "Gemma 4 E2B".
  final String? waitingFor;

  /// A waiting line that is not "Waiting for <name> to finish" ("Waiting for Wi-Fi").
  final String? waitLine;

  /// For a region: the part a stop is about ("Places").
  final String? part;

  static const idle = DlState(DlPhase.idle);

  bool get active => phase != DlPhase.idle && phase != DlPhase.done;
  bool get hasBytes => done > 0;
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;
}

/// "1.7 of 4.6 GB" (one unit when both read in it), "650 MB of 4.6 GB", or "1.7 GB so far" with no total.
String dlBytes(int done, int total) {
  if (total <= 0) return '${formatBytes(done)} so far';
  final d = formatBytes(done), t = formatBytes(total);
  final du = d.split(' ').last, tu = t.split(' ').last;
  return du == tu ? '${d.substring(0, d.length - du.length - 1)} of $t' : '$d of $t';
}

/// "6.2 MB/s".
String dlSpeed(double bytesPerSecond) => '${formatBytes(bytesPerSecond.round())}/s';

/// "less than a minute", "about 8 min", "about 2 hr".
String dlTimeLeft(Duration d) {
  if (d.inSeconds < 60) return 'less than a minute';
  if (d.inMinutes < 60) return 'about ${(d.inSeconds / 60).round()} min';
  return 'about ${(d.inMinutes / 60).round()} hr';
}

/// The status line of [s]; [idle] and [done] are the item's own words for those states.
String dlLine(DlState s, {String idle = '', String? done}) {
  final bytes = s.hasBytes ? dlBytes(s.done, s.total) : null;
  return switch (s.phase) {
    DlPhase.idle => idle,
    DlPhase.starting => 'Starting…',
    DlPhase.running => [
        dlBytes(s.done, s.total),
        if (s.speed != null && s.speed! > 0) ...[
          dlSpeed(s.speed!),
          if (s.total > s.done) '${dlTimeLeft(Duration(seconds: ((s.total - s.done) / s.speed!).round()))} left',
        ],
      ].join(' · '),
    DlPhase.pausing => 'Pausing…',
    DlPhase.paused => ['Paused', ?bytes].join(' · '),
    DlPhase.failed => ['Stopped: ${s.reasonText ?? (s.reason ?? DlReason.cutOff).words}', ?s.part, if (s.part == null && bytes != null) bytes].join(' · '),
    DlPhase.waiting => s.waitLine ?? 'Waiting for ${s.waitingFor ?? 'the download before it'} to finish',
    DlPhase.verifying => 'Checking the file…',
    DlPhase.unpacking => 'Unpacking…',
    DlPhase.done => done ?? (s.total > 0 ? 'On this device · ${formatBytes(s.total)}' : 'On this device'),
  };
}

/// Measures the speed of each download (by key), so every row of one item shows the same figure: a value only after 5 seconds
/// of data, from the last 10 seconds.
class DlMeter {
  DlMeter._();
  static final Map<String, List<(DateTime, int)>> _samples = {};

  /// Clock for tests.
  static DateTime Function() now = DateTime.now;

  /// Records [done] bytes for [key] and returns the speed, or null before 5 seconds of data.
  static double? speed(String key, int done) {
    final t = now();
    final list = _samples.putIfAbsent(key, () => []);
    if (list.isNotEmpty && done < list.last.$2) list.clear();
    if (list.isEmpty || list.last.$2 != done || t.difference(list.last.$1).inMilliseconds > 900) list.add((t, done));
    list.removeWhere((s) => t.difference(s.$1).inSeconds > 10 && list.length > 2);
    final first = list.first;
    final secs = t.difference(first.$1).inMilliseconds / 1000;
    if (secs < 5) return null;
    return (done - first.$2) / secs;
  }

  /// Forgets [key] (a stop, a pause): the next start measures afresh.
  static void reset(String key) => _samples.remove(key);

  /// Test hook.
  static void clear() => _samples.clear();
}

/// The things a row can be told to do. A null callback leaves that control out.
class DlActions {
  const DlActions({this.download, this.pause, this.resume, this.remove, this.removeAsks = false, this.freeSpace, this.downloadLabel = 'Download'});

  final VoidCallback? download;
  final VoidCallback? pause;
  final VoidCallback? resume;

  /// Removes the download and what it saved. The row asks first when bytes are saved.
  final Future<void> Function()? remove;

  /// [remove] asks in its own words (deleting a region): the row does not ask again.
  final bool removeAsks;
  final VoidCallback? freeSpace;

  /// "Download", or "Add" where a screen has always said that.
  final String downloadLabel;
}

/// Asks before throwing away saved bytes: "Remove the 1.7 GB already downloaded?" [Keep] [Remove].
Future<bool> confirmRemoveDownload(BuildContext context, int bytes) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('remove-download-confirm'),
      content: Text('Remove the ${formatBytes(bytes)} already downloaded?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        TextButton(
          key: const ValueKey('remove-download-yes'),
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: ctx.t.emergency),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// Removes a download the way every row does: with saved bytes it asks first; with none it removes at once and offers Undo.
Future<void> removeDownload(BuildContext context, DlState s, Future<void> Function() remove, {VoidCallback? undo, bool asks = false}) async {
  if (asks) {
    await remove();
    return;
  }
  if (s.hasBytes) {
    if (!await confirmRemoveDownload(context, s.done)) return;
    await remove();
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  await remove();
  messenger?.showSnackBar(SnackBar(
    content: const Text('Removed.'),
    action: undo == null ? null : SnackBarAction(label: 'Undo', onPressed: undo),
  ));
}

/// The press-and-hold menu of an active download: "Pause" or "Resume", and "Remove download".
Future<void> showDownloadMenu(BuildContext context, DlState s, DlActions a) async {
  final canPause = (s.phase == DlPhase.running || s.phase == DlPhase.starting) && a.pause != null;
  final canResume = (s.phase == DlPhase.paused || s.phase == DlPhase.failed) && a.resume != null;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        key: const ValueKey('download-menu'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canPause)
            ListTile(leading: const Icon(Icons.pause), title: const Text('Pause'), onTap: () {
              Navigator.pop(ctx);
              a.pause!();
            }),
          if (canResume)
            ListTile(leading: const Icon(Icons.play_arrow), title: const Text('Resume'), onTap: () {
              Navigator.pop(ctx);
              a.resume!();
            }),
          if (a.remove != null)
            ListTile(
              key: const ValueKey('download-menu-remove'),
              leading: Icon(Icons.delete_outline, color: ctx.t.emergency),
              title: Text('Remove download', style: TextStyle(color: ctx.t.emergency)),
              onTap: () {
                Navigator.pop(ctx);
                removeDownload(context, s, a.remove!, asks: a.removeAsks);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// The trailing control of a row for [s]: Download, a spinner while starting or pausing, Pause, Resume (or Free space), Remove
/// while waiting, nothing while checking or unpacking, and the item's own [doneAction] when done. [idleAction] replaces the
/// Download button where an item has its own (an already-on-this-device badge).
Widget dlControl(BuildContext context, DlState s, DlActions a, {String keyBase = 'dl', Widget? doneAction, Widget? idleAction}) {
  final k = context.t;
  Widget spinner() => SizedBox(
        width: 48,
        height: 48,
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: k.secondary))),
      );
  return switch (s.phase) {
    DlPhase.idle => idleAction ??
        (a.download == null
            ? const SizedBox.shrink()
            : TextButton(key: ValueKey('$keyBase-download'), onPressed: a.download, child: Text(a.downloadLabel))),
    DlPhase.starting || DlPhase.pausing => KeyedSubtree(key: ValueKey('$keyBase-busy'), child: spinner()),
    DlPhase.running => a.pause == null
        ? const SizedBox.shrink()
        : TextButton(key: ValueKey('$keyBase-pause'), onPressed: a.pause, child: const Text('Pause')),
    DlPhase.paused => a.resume == null
        ? const SizedBox.shrink()
        : TextButton(key: ValueKey('$keyBase-resume'), onPressed: a.resume, child: const Text('Resume')),
    DlPhase.failed => s.reason == DlReason.full && a.freeSpace != null
        ? TextButton(key: ValueKey('$keyBase-free-space'), onPressed: a.freeSpace, child: const Text('Free space'))
        : a.resume == null
            ? const SizedBox.shrink()
            : TextButton(key: ValueKey('$keyBase-resume'), onPressed: a.resume, child: const Text('Resume')),
    DlPhase.waiting => a.remove == null
        ? const SizedBox.shrink()
        : TextButton(key: ValueKey('$keyBase-remove'), onPressed: () => removeDownload(context, s, a.remove!, asks: a.removeAsks), child: const Text('Remove')),
    DlPhase.verifying || DlPhase.unpacking => const SizedBox.shrink(),
    DlPhase.done => doneAction ?? const SizedBox.shrink(),
  };
}

/// The status line, the bar and (on Paused and Failed rows) the small "Remove" under it, for rows that lay out their own title and
/// trailing control (a region part, a library card).
class DlStatus extends StatelessWidget {
  const DlStatus({super.key, required this.state, this.actions = const DlActions(), this.idle = '', this.idleSpan, this.done, this.idleColor, this.keyBase = 'dl'});

  final DlState state;
  final DlActions actions;
  final String idle;

  /// The idle line with its own colours (a size in grey and a fit in green); replaces [idle].
  final InlineSpan? idleSpan;
  final String? done;
  final Color? idleColor;
  final String keyBase;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = state;
    if (s.phase == DlPhase.idle && idleSpan != null) {
      return Text.rich(idleSpan!, key: ValueKey('$keyBase-line'), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13));
    }
    final failed = s.phase == DlPhase.failed;
    final line = dlLine(s, idle: idle, done: done);
    final colour = failed ? k.emergency : (s.phase == DlPhase.idle ? (idleColor ?? k.secondary) : k.secondary);
    final bar = switch (s.phase) {
      DlPhase.starting || DlPhase.verifying || DlPhase.unpacking => const _Bar(value: null),
      DlPhase.running || DlPhase.pausing => _Bar(value: s.fraction),
      DlPhase.paused => _Bar(value: s.fraction, color: k.secondary),
      DlPhase.failed => _Bar(value: s.fraction, color: k.emergency),
      _ => null,
    };
    final removable = (s.phase == DlPhase.paused || s.phase == DlPhase.failed) && actions.remove != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (line.isNotEmpty)
          Text(line, key: ValueKey('$keyBase-line'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colour)),
        if (bar != null) Padding(padding: const EdgeInsets.only(top: 6), child: bar),
        if (removable)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('$keyBase-remove'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), tapTargetSize: MaterialTapTargetSize.padded, textStyle: const TextStyle(fontSize: 13)),
              onPressed: () => removeDownload(context, s, actions.remove!, asks: actions.removeAsks),
              child: const Text('Remove'),
            ),
          ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, this.color});

  final double? value;
  final Color? color;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(value: value, minHeight: value == null ? 2 : 4, color: color, backgroundColor: context.t.secondary.withValues(alpha: 0.15)),
      );
}

/// One download row: title, [detail] lines under it when idle or done, the status line, the bar and the trailing control.
/// Tapping: [onOpen] when the item has a page (in every state); otherwise idle downloads, paused and failed resume, done uses
/// [onDoneTap], and a running row only ripples. Press and hold on an active row opens the Pause/Resume and Remove menu.
class DownloadRow extends StatelessWidget {
  const DownloadRow({
    super.key,
    required this.title,
    required this.state,
    required this.actions,
    this.subtitle,
    this.idleLine = '',
    this.idleSpan,
    this.idleLineColor,
    this.doneLine,
    this.extra,
    this.doneAction,
    this.idleAction,
    this.onOpen,
    this.onDoneTap,
    this.onDoneHold,
    this.leading,
    this.selected = false,
    this.holdLabel,
    this.keyBase = 'dl',
  });

  final String title;

  /// A line under the title that stays in every state (a model's note).
  final String? subtitle;
  final DlState state;
  final DlActions actions;

  /// The item's own detail while not downloaded ("4.6 GB · May be tight on this device"), and its colour.
  final String idleLine;
  final InlineSpan? idleSpan;
  final Color? idleLineColor;

  /// The line when done; "On this device · <size>" when null.
  final String? doneLine;

  /// Extra lines under the status while idle or done (a model's kind).
  final Widget? extra;
  final Widget? doneAction;
  final Widget? idleAction;
  final VoidCallback? onOpen;
  final VoidCallback? onDoneTap;
  final VoidCallback? onDoneHold;
  final Widget? leading;

  /// The item open in the detail pane beside the list (a tablet).
  final bool selected;

  /// What press and hold does on a row that is not downloading ([onDoneHold]), for the accessibility menu.
  final String? holdLabel;
  final String keyBase;

  VoidCallback? _tap() {
    if (onOpen != null) return onOpen;
    return switch (state.phase) {
      DlPhase.idle => actions.download,
      DlPhase.paused || DlPhase.failed => state.reason == DlReason.full && actions.freeSpace != null ? actions.freeSpace : actions.resume,
      DlPhase.done => onDoneTap,
      _ => () {},
    };
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = state;
    final holdable = s.active && (actions.remove != null || actions.pause != null || actions.resume != null);
    return Padding(
      key: ValueKey('$keyBase-row'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Holdable(
        borderRadius: BorderRadius.circular(16),
        color: selected ? Color.alphaBlend(k.accent.withValues(alpha: 0.16), k.surface) : null,
        onTap: _tap(),
        onHold: holdable ? () => showDownloadMenu(context, s, actions) : onDoneHold,
        holdLabel: holdable ? 'Pause, resume or remove' : (holdLabel ?? 'Options'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
                      DlStatus(state: s, actions: actions, idle: idleLine, idleSpan: idleSpan, done: doneLine, idleColor: idleLineColor, keyBase: keyBase),
                      if (extra != null && (s.phase == DlPhase.idle || s.phase == DlPhase.done)) extra!,
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                dlControl(context, s, actions, keyBase: keyBase, doneAction: doneAction, idleAction: idleAction),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
