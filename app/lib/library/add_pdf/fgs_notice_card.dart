import 'package:flutter/material.dart';

import '../../background/fgs_add.dart';
import '../../theme.dart';

/// The in-app notice, on the Library, when Cache is next opened after a background add failed or ended before it was done. Silent
/// notifications cannot be relied on (the person may have refused them), so the app says it itself. The words are
/// [FgsAddNotice]'s (the Add PDF page's own words where they fit; new ones are drafts, marked in fgs_add.dart).
class FgsAddNoticeCard extends StatelessWidget {
  const FgsAddNoticeCard({super.key, required this.state});

  final FgsAddNoticeState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final n = state.notice;
      if (n == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FgsAddNoticeBody(notice: n, onDismiss: state.dismiss),
      );
    },
  );
}

/// The card itself (the pictures draw it without a state).
class FgsAddNoticeBody extends StatelessWidget {
  const FgsAddNoticeBody({super.key, required this.notice, this.onDismiss});

  final FgsAddNotice notice;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final tone = notice.failed ? k.emergency : k.accent;
    Widget lines(String title, String text, {bool strong = true}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: strong ? 15 : 13, fontWeight: strong ? FontWeight.w500 : FontWeight.w400, color: k.text)),
        if (text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(text, style: TextStyle(fontSize: 13, height: 1.4, color: k.secondary))),
      ],
    );
    return Container(
      key: const ValueKey('fgs-add-notice'),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16), border: Border(left: BorderSide(color: tone, width: 4))),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: Color.alphaBlend(k.secondary.withValues(alpha: 0.12), k.surface), borderRadius: BorderRadius.circular(9)),
                child: Icon(notice.failed ? Icons.warning_amber_rounded : Icons.pause_circle_outline, size: 21, color: tone),
              ),
              const SizedBox(width: 10),
              Expanded(child: lines(notice.title, notice.text)),
            ],
          ),
          if (notice.alsoTitle != null) ...[
            const SizedBox(height: 8),
            Padding(padding: const EdgeInsets.only(left: 48), child: lines(notice.alsoTitle!, notice.alsoText ?? '', strong: false)),
          ],
          if (onDismiss != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(key: const ValueKey('fgs-add-notice-dismiss'), onPressed: onDismiss, child: const Text(FgsWords.dismiss)),
            ),
          ],
        ],
      ),
    );
  }
}
