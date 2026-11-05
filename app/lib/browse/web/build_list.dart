import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/format.dart' show formatBytes;
import 'build_api.dart';
import 'build_common.dart';
import 'build_page.dart';
import 'build_state.dart';
import 'build_text.dart';
import 'device_library.dart';
import 'device_widgets.dart' show TransferCard;
import 'drop_folder_page.dart';
import 'compression_default_link.dart';

/// What the building adds above the Library list: the PDFs going up, and a card for each library being built (its books done, the time
/// left, Pause or Resume). A tap on a card opens the library.
class BuildListCards extends StatelessWidget {
  const BuildListCards({super.key, required this.ctl, this.onOpen});

  final BuildController ctl;
  final void Function(String libraryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final up = ctl.upload;
    final q = ctl.queue;
    final libs = [for (final l in ctl.libraries) if (ctl.isBuilding(l.id)) l];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (up != null) _upload(up),
        for (final l in libs) _card(context, l, q),
      ],
    );
  }

  Widget _upload(BuildUpload u) {
    final title = u.replaceDocId != null ? 'Uploading the new copy of ${u.replaceTitle}' : 'Uploading ${thousands(u.count)} ${u.count == 1 ? 'PDF' : 'PDFs'}';
    if (!u.running) {
      return TransferCard(
        cardKey: const ValueKey('build-upload-card'),
        title: title,
        line: u.stopped ?? '${thousands(u.failed.length)} could not be sent. ${thousands(u.doneCount)} of ${thousands(u.count)} are on this device.',
        warn: true,
        actions: [TextButton(key: const ValueKey('dismiss-build-upload'), onPressed: ctl.dismissUpload, child: const Text('OK'))],
      );
    }
    final speed = u.speed;
    final left = u.secondsLeft;
    final line = [
      '${thousands(u.doneCount)} of ${thousands(u.count)} done',
      '${formatBytes(u.sentBytes)} of ${formatBytes(u.totalBytes)}',
      if (speed != null) '${formatBytes(speed.round())}/s',
      if (left != null) left < 60 ? 'less than a minute left' : (left < 90 * 60 ? 'about ${(left / 60).ceil()} min left' : 'about ${(left / 3600).round()} h left'),
    ].join(' · ');
    return TransferCard(
      cardKey: const ValueKey('build-upload-card'),
      title: title,
      line: line,
      fraction: u.finishing ? null : u.fraction,
      indeterminate: u.finishing,
      actions: [IconButton(key: const ValueKey('cancel-build-upload'), tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: ctl.cancelUpload)],
    );
  }

  Widget _card(BuildContext context, BuildLibrary l, BuildQueue q) {
    final p = ctl.progressOf(l.id);
    final paused = q.paused;
    final parts = <String>[
      if (paused) 'Paused',
      if (!paused && q.blocked != null) 'Waiting for the search model',
      '${thousands(p.finished)} of ${thousands(p.total)} books',
      if (p.attention > 0) '${p.attention} need attention',
      if (!paused && q.blocked == null && q.etaLow != null && q.etaHigh != null) 'roughly ${etaShort(q.etaLow!, q.etaHigh!)} left',
    ];
    final card = TransferCard(
      cardKey: ValueKey('build-card-${l.id}'),
      title: 'Building ${l.title}',
      line: parts.join(' · '),
      fraction: p.total == 0 ? 0 : p.finished / p.total,
      actions: [
        IconButton(
          key: ValueKey(paused ? 'list-resume-${l.id}' : 'list-pause-${l.id}'),
          tooltip: paused ? 'Resume' : 'Pause',
          icon: Icon(paused ? Icons.play_arrow : Icons.pause),
          onPressed: () => paused ? ctl.resume() : ctl.pause(),
        ),
      ],
    );
    return onOpen == null ? card : GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => onOpen!(l.id), child: card);
  }
}

/// The rows Add to Library gets for building: "Build from your PDFs" and "Drop folder".
List<Widget> buildAddRows(BuildContext context, DeviceLibrary device) {
  final b = device.build;
  if (b == null) return const [];
  return [
    _AddRow(
      rowKey: const ValueKey('add-build-pdfs'),
      icon: Icons.library_books_outlined,
      title: 'Build from your PDFs',
      subtitle: 'Make a searchable library from PDF files on this computer.',
      onTap: () => openBuildPage(context, b),
    ),
    const SizedBox(height: 6),
    _AddRow(
      rowKey: const ValueKey('add-drop-folder'),
      icon: Icons.folder_open_outlined,
      title: 'Drop folder',
      subtitle: 'Files you copy into a folder on this device are added automatically.',
      trailing: b.drop == null ? null : (b.drop!.settings.enabled ? 'On' : 'Off'),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DropFolderPage(build: b))),
    ),
    const Padding(padding: EdgeInsets.fromLTRB(6, 4, 6, 6), child: Small('Dropping PDFs anywhere on Library opens Build from your PDFs too.')),
    if (b.api is BuildCompressionApi) ExpansionTile(
      key: const ValueKey('library-build-advanced'),
      title: const Text('Advanced'),
      children: [
        _AddRow(
          rowKey: const ValueKey('compression-defaults'),
          icon: Icons.picture_as_pdf_outlined,
          title: 'Making PDFs smaller',
          subtitle: 'Choose the default for books added to this device.',
          onTap: () => openCompressionDefaults(context, b),
        ),
      ],
    ),

  ];
}

class _AddRow extends StatelessWidget {
  const _AddRow({required this.rowKey, required this.icon, required this.title, required this.subtitle, required this.onTap, this.trailing});

  final Key rowKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: rowKey,
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 22, color: k.text),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                      Text(subtitle, style: TextStyle(fontSize: 12, color: k.secondary)),
                    ],
                  ),
                ),
                if (trailing != null) Padding(padding: const EdgeInsets.only(right: 4), child: Text(trailing!, style: TextStyle(fontSize: 12, color: k.secondary))),
                Icon(Icons.chevron_right, color: k.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
