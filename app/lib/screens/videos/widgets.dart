import 'dart:io';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/format.dart';

/// A rounded surface row, the shape every list in the app uses.
class VideoTile extends StatelessWidget {
  const VideoTile({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 72), child: child),
        ),
      ),
    );
  }
}

/// A video thumbnail from a URL or a file, with the duration on it.
class VideoThumb extends StatelessWidget {
  const VideoThumb({super.key, this.url, this.fallbackUrl, this.path, this.durationS, this.width = 120, this.audio = false, this.blankIcon = Icons.play_circle_outline});

  final String? url;

  /// Tried when [url] cannot be loaded (an instance may not have the large picture).
  final String? fallbackUrl;
  final String? path;
  final int? durationS;
  final double width;
  final bool audio;

  /// The sign on a video with no picture; null: none.
  final IconData? blankIcon;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    Widget image;
    if (path != null && File(path!).existsSync()) {
      image = Image.file(File(path!), fit: BoxFit.cover);
    } else if (url != null) {
      image = Image.network(
        url!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallbackUrl == null ? _blank(k) : Image.network(fallbackUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => _blank(k)),
      );
    } else {
      image = _blank(k);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (audio) Center(child: Icon(Icons.music_note, size: width / 4, color: k.text.withValues(alpha: 0.8))),
            if (durationS != null && durationS! > 0)
              Positioned(
                right: 4,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(4)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    child: Text(formatDuration(durationS!), style: const TextStyle(fontSize: 12, color: Colors.white)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _blank(CacheTokens k) => ColoredBox(color: k.background, child: blankIcon == null ? null : Icon(blankIcon, color: k.secondary));
}

/// A message in the middle of an empty or failed screen.
class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.error = false, this.action, this.actionLabel});

  final String text;
  final bool error;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: error ? k.emergency : k.secondary)),
            if (action != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: action, child: Text(actionLabel ?? 'Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

/// The one question before a saved video is deleted, the same from every place that offers Delete.
Future<bool> confirmDeleteVideo(BuildContext context, {required int bytes}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this video?'),
      content: Text('It is deleted from this device (${formatBytes(bytes)}). You can download it again later.'),
      actions: [
        TextButton(key: const ValueKey('video-delete-keep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        TextButton(key: const ValueKey('video-delete-yes'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ),
  );
  return yes == true;
}

/// A small capital heading over a part of a list ("DOWNLOADING", "ON THIS DEVICE · 14 videos · 3.2 GB").
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key, this.detail, this.top = 16, this.trailing});

  /// Shown in capitals.
  final String text;

  /// After the heading as written ("14 videos · 3.2 GB").
  final String? detail;
  final double top;

  /// A quiet control at the right of the heading ("Add").
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final heading = Semantics(
        header: true,
        label: detail == null ? text : '$text, $detail',
        excludeSemantics: true,
        child: Text(
          detail == null ? text.toUpperCase() : '${text.toUpperCase()} · $detail',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: k.secondary),
        ),
      );
    return Padding(
      padding: EdgeInsets.fromLTRB(4, trailing == null ? top : top - 8, 0, trailing == null ? 6 : 0),
      child: trailing == null ? heading : Row(children: [Expanded(child: heading), trailing!]),
    );
  }
}
