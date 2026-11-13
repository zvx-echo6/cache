import 'package:flutter/material.dart';

import '../../screens/settings/widgets.dart' show GroupLabel;
import '../../settings/space.dart' show reserveFor;
import '../../theme.dart';
import '../../video/format.dart';
import 'build_common.dart' show DashedBox;
import 'build_list.dart';
import 'device_api.dart';
import 'device_library.dart';
import 'build_text.dart' show isPdfName;
import 'local_files.dart';

const int _gb = 1 << 30;

/// One card of the Library list, in the phone's transfer card shape: a title, a line, a progress bar, and actions.
class TransferCard extends StatelessWidget {
  const TransferCard({super.key, required this.title, required this.line, this.warn = false, this.fraction, this.indeterminate = false, this.actions = const [], this.cardKey});

  final String title;
  final String line;
  final bool warn;
  final double? fraction;
  final bool indeterminate;
  final List<Widget> actions;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      key: cardKey,
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text(line, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: warn ? k.warning : k.secondary)),
                      ],
                    ),
                  ),
                  ...actions,
                ],
              ),
              if (fraction != null || indeterminate)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 2),
                  child: LinearProgressIndicator(value: indeterminate ? null : fraction, minHeight: 3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _cancel(Key key, String tooltip, VoidCallback? onPressed) =>
    IconButton(key: key, tooltip: tooltip, icon: const Icon(Icons.close), onPressed: onPressed);

String _rate(double bytesPerSecond) => '${formatBytes(bytesPerSecond.round())}/s';

String _left(int seconds) {
  if (seconds < 60) return 'less than a minute left';
  final m = (seconds / 60).ceil();
  if (m < 90) return 'about $m min left';
  final h = (m / 60).round();
  return 'about $h h left';
}

/// What sits above the Library list in a browser: the card for what happened while the tab was closed, the upload, the transfers the
/// device is running, and library packages that wait to be added.
class DeviceLibraryTop extends StatelessWidget {
  const DeviceLibraryTop({super.key, required this.device, required this.onAddPackage, this.onOpenBuilt, this.whileClosed = true});

  final DeviceLibrary device;

  /// Whether the "While this tab was closed" card is drawn here, above the list. The Linux desktop draws it after the list instead
  /// ([DeviceWhileClosedBelow]): it turns up once the page is open, and the rows under the pointer must not move.
  final bool whileClosed;

  /// The person tapped a building library's card.
  final void Function(String libraryId)? onOpenBuilt;

  /// The person added a downloaded library package.
  final void Function(DeviceJob package) onAddPackage;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) {
        final up = device.upload;
        final shown = [for (final j in device.jobs) if (j.active || j.paused || j.failed) j];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (device.problem != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(device.problem!, key: const ValueKey('device-problem'), style: TextStyle(fontSize: 13, color: k.warning)),
              ),
            if (device.jobProblem != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(device.jobProblem!, key: const ValueKey('job-problem'), style: TextStyle(fontSize: 13, color: k.warning)),
              ),
            if (whileClosed && hasWhileClosed(device)) WhileClosedCard(device: device),
            if (up != null) _uploadCard(up),
            if (device.build != null) BuildListCards(ctl: device.build!, onOpen: onOpenBuilt),
            for (final j in shown) _jobCard(j),
            for (final j in device.readyPackages)
              TransferCard(
                cardKey: ValueKey('package-${j.id}'),
                title: j.name,
                line: 'Downloaded. Ready to add to your library.',
                actions: [
                  TextButton(key: ValueKey('add-package-${j.id}'), onPressed: () => onAddPackage(j), child: const Text('Add')),
                  _cancel(ValueKey('drop-package-${j.id}'), 'Dismiss', () => device.packageHandled(j)),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _uploadCard(DeviceUpload up) {
    if (!up.running) {
      return TransferCard(
        cardKey: const ValueKey('upload-card'),
        title: 'Uploading ${up.name}',
        line: up.error!,
        warn: true,
        actions: [TextButton(key: const ValueKey('dismiss-upload'), onPressed: device.dismissUpload, child: const Text('OK'))],
      );
    }
    final speed = up.speed;
    final left = up.secondsLeft;
    final line = up.finishing
        ? '${up.name}\nPutting it in place…'
        : [
            up.name,
            [
              '${formatBytes(up.sent)} of ${formatBytes(up.total)}',
              if (speed != null) _rate(speed),
              if (left != null) _left(left),
            ].join(' · '),
          ].join('\n');
    return TransferCard(
      cardKey: const ValueKey('upload-card'),
      title: 'Uploading',
      line: line,
      fraction: up.finishing ? null : up.fraction,
      indeterminate: up.finishing,
      actions: [_cancel(const ValueKey('cancel-upload'), 'Cancel', up.finishing ? null : device.cancelUpload)],
    );
  }

  Widget _jobCard(DeviceJob j) {
    final title = device.titleOfJob(j);
    if (j.failed) {
      return TransferCard(
        cardKey: ValueKey('job-${j.id}'),
        title: title,
        line: deviceJobWords(j),
        warn: true,
        actions: [
          TextButton(key: ValueKey('retry-${j.id}'), onPressed: () => device.retry(j), child: const Text('Try again')),
          _cancel(ValueKey('dismiss-${j.id}'), 'Dismiss', () => device.cancelJob(j)),
        ],
      );
    }
    if (j.paused) {
      // Paused keeps its part file on the device: it stays on screen with a way on (Resume) and a way out (Remove, which cancels it
      // on the device, where the part file is then deleted).
      return TransferCard(
        cardKey: ValueKey('job-${j.id}'),
        title: title,
        line: j.total > 0 ? 'Paused · ${formatBytes(j.bytes)} of ${formatBytes(j.total)}' : 'Paused · ${formatBytes(j.bytes)}',
        fraction: j.fraction,
        actions: [
          TextButton(key: ValueKey('resume-${j.id}'), onPressed: () => device.resumeJob(j), child: const Text('Resume')),
          TextButton(key: ValueKey('remove-${j.id}'), onPressed: () => device.cancelJob(j), child: const Text('Remove')),
        ],
      );
    }
    final waiting = j.state == 'queued';
    final since = j.createdAt == null ? '' : ' · started ${startedWords(j.createdAt!)}';
    return TransferCard(
      cardKey: ValueKey('job-${j.id}'),
      title: title,
      line: waiting ? 'Waiting its turn…' : (j.total > 0 ? 'Downloading · ${formatBytes(j.bytes)} of ${formatBytes(j.total)}$since' : 'Downloading · ${formatBytes(j.bytes)}$since'),
      fraction: waiting ? null : j.fraction,
      indeterminate: waiting || j.total <= 0,
      actions: [_cancel(ValueKey('cancel-${j.id}'), 'Cancel', () => device.cancelJob(j))],
    );
  }
}

/// "03:12": a time of day in the browser's own time zone, on a 24-hour clock.
String clockTime(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// "22:10" for today, "yesterday 22:10" for the day before and "3 Oct 22:10" for anything older ([now] is for tests).
String startedWords(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(l.year, l.month, l.day)).inDays;
  if (days <= 0) return clockTime(l);
  if (days == 1) return 'yesterday ${clockTime(l)}';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${l.day} ${months[l.month - 1]} ${clockTime(l)}';
}

/// Whether there is anything to say under "While this tab was closed".
bool hasWhileClosed(DeviceLibrary device) => device.whileClosed.isNotEmpty || (device.build?.whileClosed.isNotEmpty ?? false);

/// The "While this tab was closed" card after the Library list (the Linux desktop), so it never pushes the rows above it down.
class DeviceWhileClosedBelow extends StatelessWidget {
  const DeviceWhileClosedBelow({super.key, required this.device});

  final DeviceLibrary device;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: device,
        builder: (context, _) => hasWhileClosed(device) ? Padding(padding: const EdgeInsets.only(top: 16), child: WhileClosedCard(device: device)) : const SizedBox.shrink(),
      );
}

/// "While this tab was closed": what finished, still runs or stopped since the tab was last open, with Dismiss.
class WhileClosedCard extends StatelessWidget {
  const WhileClosedCard({super.key, required this.device});

  final DeviceLibrary device;

  String _line(DeviceJob j) {
    final name = device.titleOfJob(j);
    final end = j.finishedAt == null ? '' : ' at ${clockTime(j.finishedAt!)}';
    final begin = j.createdAt == null ? '' : ', started ${startedWords(j.createdAt!)}';
    return switch (j.state) {
      'done' => '$name finished$end.',
      'failed' => '$name stopped$end.',
      'cancelled' => '$name was canceled.',
      _ => '$name is still downloading$begin.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      key: const ValueKey('while-closed'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: k.accent, width: 3)), borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('While this tab was closed', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
              const SizedBox(height: 4),
              for (final j in device.whileClosed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('•  ${_line(j)}', style: TextStyle(fontSize: 13, color: k.text)),
                ),
              for (final line in device.build?.whileClosed ?? const <String>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('•  $line', style: TextStyle(fontSize: 13, color: k.text)),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('dismiss-while-closed'),
                  onPressed: () {
                    device.build?.dismissWhileClosed();
                    device.dismissWhileClosed();
                  },
                  child: const Text('Dismiss'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The foot of the Library list, always in view: the device's free space as a bar, what the Library and other files take, and the room
/// still to be used by transfers under way.
class DeviceStorageFooter extends StatelessWidget {
  const DeviceStorageFooter({super.key, required this.device});

  final DeviceLibrary device;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) {
        final free = device.space.free;
        final total = device.space.total;
        final library = device.items.fold<int>(0, (s, i) => s + i.bytes);
        final reserve = reserveFor(total);
        final toDownload = device.stillToDownload;
        final up = device.upload;
        final toUpload = up != null && up.running ? up.total - up.sent : 0;
        final small = TextStyle(fontSize: 11, color: k.secondary, height: 1.35);
        final Widget head;
        if (free == null || total == null || total <= 0) {
          head = Text('Device storage', style: TextStyle(fontSize: 12, color: k.secondary));
        } else {
          head = Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Device storage', style: TextStyle(fontSize: 12, color: k.secondary)),
              const SizedBox(width: 8),
              Flexible(
                child: Text.rich(
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                TextSpan(
                  style: TextStyle(fontSize: 12, color: k.secondary),
                  children: [
                    TextSpan(text: formatBytes(free), style: TextStyle(fontWeight: FontWeight.w500, color: k.text)),
                    TextSpan(text: ' free of ${formatBytes(total)}'),
                  ],
                ),
              ),
              ),
            ],
          );
        }
        return DecoratedBox(
          key: const ValueKey('device-storage'),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: k.secondary.withValues(alpha: 0.25)))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                if (free != null && total != null && total > 0) ...[
                  const SizedBox(height: 6),
                  _StorageBar(total: total, library: library, other: (total - free - library).clamp(0, total), reserve: reserve),
                  const SizedBox(height: 6),
                  Text(
                    'Library ${formatBytes(library)} · Other files ${formatBytes((total - free - library).clamp(0, total))}\n'
                    'Cache keeps ${reserve ~/ _gb} GB free for the device',
                    style: small,
                  ),
                ] else
                  Padding(padding: const EdgeInsets.only(top: 6), child: Text('Library ${formatBytes(library)}', style: small)),
                if (toDownload > 0 && free != null)
                  Text('${formatBytes(toDownload)} still to download, ${formatBytes((free - toDownload).clamp(0, free))} will be free after', key: const ValueKey('still-to-download'), style: small.copyWith(color: k.warning)),
                if (toUpload > 0) Text('${formatBytes(toUpload)} still to upload', key: const ValueKey('still-to-upload'), style: small.copyWith(color: k.warning)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StorageBar extends StatelessWidget {
  const _StorageBar({required this.total, required this.library, required this.other, required this.reserve});

  final int total;
  final int library;
  final int other;
  final int reserve;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      label: 'Device storage',
      child: Container(
        height: 8,
        decoration: BoxDecoration(
          color: k.background,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: k.secondary.withValues(alpha: 0.3)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LayoutBuilder(
            builder: (context, c) {
              double w(int n) => c.maxWidth * (n / total).clamp(0.0, 1.0);
              return Stack(
                children: [
                  Positioned(left: 0, top: 0, bottom: 0, width: w(library), child: ColoredBox(color: k.accent)),
                  Positioned(left: w(library), top: 0, bottom: 0, width: w(other), child: ColoredBox(color: k.secondary.withValues(alpha: 0.55))),
                  Positioned(right: 0, top: 0, bottom: 0, width: w(reserve), child: ColoredBox(color: k.warning.withValues(alpha: 0.35))),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Files dropped anywhere on the page. While a file is dragged over it shows what dropping does; a drop is handed to [onFile].
class DropOverlay extends StatefulWidget {
  const DropOverlay({super.key, required this.child, required this.onFile, this.onPdfs, this.enabled = true});

  final Widget child;
  final void Function(LocalFile file) onFile;

  /// Where a drop that holds PDFs (or a folder of them) goes, with every file in it; null leaves PDFs to [onFile] like any other file.
  final void Function(List<LocalFile> files)? onPdfs;
  final bool enabled;

  @override
  State<DropOverlay> createState() => _DropOverlayState();
}

class _DropOverlayState extends State<DropOverlay> {
  DropListener? _listener;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _listener = DropListener(
      onActive: (a) {
        if (mounted && widget.enabled) setState(() => _active = a);
      },
      onDrop: (files) {
        if (!mounted || !widget.enabled || files.isEmpty) return;
        final pdfs = widget.onPdfs;
        if (pdfs != null && files.any((f) => isPdfName(f.name))) {
          pdfs(files);
        } else {
          widget.onFile(files.first);
        }
      },
    );
  }

  @override
  void dispose() {
    _listener?.dispose();
    super.dispose();
  }

  /// A file to add to this device's library: the box in the middle.
  Widget _plainBox(CacheTokens k) => Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(28),
          constraints: const BoxConstraints(maxWidth: 520),
          decoration: BoxDecoration(border: Border.all(color: k.accent, width: 2), borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.upload_file, size: 56, color: k.accent),
              const SizedBox(height: 10),
              Text("Drop to add to this device's library", textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: k.text)),
              const SizedBox(height: 6),
              Text('A .zim file, a .cache-library file or a library snapshot.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: k.secondary)),
            ],
          ),
        ),
      );

  /// PDFs to build a library: a dashed frame round the whole page.
  Widget _pdfFrame(CacheTokens k) => Padding(
        padding: const EdgeInsets.all(24),
        child: DashedBox(
          color: k.accent,
          radius: 28,
          padding: EdgeInsets.zero,
          child: SizedBox.expand(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.library_books, size: 56, color: k.accent),
                    const SizedBox(height: 12),
                    Text('Drop PDFs to build a library', textAlign: TextAlign.center, style: TextStyle(fontSize: 30, color: k.text)),
                    const SizedBox(height: 8),
                    Text(
                      'Release to choose where they go. A folder works too. A .zim or .cache-library file is added to the Library as usual.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, height: 1.4, color: k.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Stack(
      children: [
        widget.child,
        if (_active)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                key: const ValueKey('drop-overlay'),
                color: k.background.withValues(alpha: 0.82),
                child: widget.onPdfs == null ? _plainBox(k) : _pdfFrame(k),
              ),
            ),
          ),
      ],
    );
  }
}

/// "From this computer", first section of Add to Library: a drop zone and the file chooser. [onChoose] runs straight from the tap (a
/// browser opens its file chooser only then).
class FromThisComputer extends StatelessWidget {
  const FromThisComputer({super.key, required this.device, required this.onChoose});

  final DeviceLibrary device;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) {
        final busy = device.upload?.running == true;
        final err = device.refusal;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const GroupLabel('From this computer'),
            Opacity(
              opacity: busy ? 0.7 : 1,
              child: Container(
                key: const ValueKey('drop-zone'),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                decoration: BoxDecoration(
                  color: k.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: err != null ? k.warning : k.secondary.withValues(alpha: 0.55), width: 2),
                ),
                child: Row(
                  children: [
                    Icon(Icons.upload_file, size: 32, color: err != null ? k.warning : (busy ? k.secondary : k.accent)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(busy ? 'Uploading ${device.upload!.name}' : 'Drop a file here', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                          const SizedBox(height: 2),
                          Text(
                            busy
                                ? 'One file at a time. Watch it in the list on the left.'
                                : 'A .zim file, a .cache-library file or a library snapshot. Files of several GB are fine.',
                            style: TextStyle(fontSize: 12, color: k.secondary, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                    if (!busy) ...[
                      const SizedBox(width: 8),
                      FilledButton(key: const ValueKey('choose-file'), onPressed: onChoose, child: const Text('Choose a file')),
                    ],
                  ],
                ),
              ),
            ),
            if (err != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(err, key: const ValueKey('refusal'), style: TextStyle(fontSize: 13, color: k.warning, height: 1.4)),
              ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }
}

/// A DeviceException is not shown as it is: it can name the machine.
String deviceErrorWords(Object e) => e is DeviceException && e.code == 'unauthorized' ? 'Sign in again.' : 'This device could not be reached. Try again.';

/// Builds with whether the mouse pointer is over it (a touch screen never is).
class HoverReveal extends StatefulWidget {
  const HoverReveal({super.key, required this.builder});

  final Widget Function(bool hovering) builder;

  @override
  State<HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<HoverReveal> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: widget.builder(_hover),
      );
}
