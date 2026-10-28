import 'package:flutter/material.dart';

import '../chat/answer_reports.dart';
import '../history/share.dart';
import '../theme.dart';
import 'settings/widgets.dart';

/// What the person chose in the report sheet.
class ReportChoice {
  const ReportChoice(this.reason, this.note);
  final ReportReason reason;
  final String note;
}

/// Asks why an answer is being reported. Null when cancelled.
Future<ReportChoice?> showReportSheet(BuildContext context) {
  return showModalBottomSheet<ReportChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => const _ReportSheet(),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet();

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Report this answer', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'The report is saved on this phone with the question, the answer and the model. Nothing is sent anywhere; '
              'you can share reports yourself from Settings > Assistant.',
              style: TextStyle(fontSize: 15, color: k.secondary, height: 1.4),
            ),
            const SizedBox(height: 8),
            RadioGroup<ReportReason>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(
                children: [
                  for (final r in ReportReason.values)
                    RadioListTile<ReportReason>(
                      key: ValueKey('report-reason-${r.name}'),
                      value: r,
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.label, style: const TextStyle(fontSize: 17)),
                    ),
                ],
              ),
            ),
            TextField(
              key: const ValueKey('report-note'),
              controller: _note,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'What was wrong (optional)'),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('report-save'),
                  onPressed: _reason == null ? null : () => Navigator.pop(context, ReportChoice(_reason!, _note.text.trim())),
                  child: const Text('Save report'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings > Assistant > Reported answers: the saved reports, each shareable and removable.
class ReportedAnswersPage extends StatelessWidget {
  const ReportedAnswersPage({super.key, required this.reports, this.share = shareMarkdown});

  final AnswerReports reports;
  final ShareMarkdown share;

  String _when(DateTime at) {
    final l = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: reports,
      builder: (context, _) => FutureBuilder<List<AnswerReport>>(
        future: reports.list(),
        builder: (context, snap) {
          final items = snap.data ?? const <AnswerReport>[];
          return SettingsPage(
            title: 'Reported answers',
            children: [
              if (snap.connectionState != ConnectionState.done)
                const SizedBox.shrink()
              else if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'No reports. Use "Report this answer" under any answer in Ask to save one here.',
                    style: TextStyle(fontSize: 16, color: context.t.secondary),
                  ),
                )
              else ...[
                SettingsGroup(
                  label: 'Saved on this phone',
                  rows: [
                    for (final r in items)
                      SettingsRow(
                        title: r.question.isEmpty ? '(no question)' : r.question,
                        status: [Part('${r.reason.label} · ${r.model} · ${_when(r.at)}')],
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Share',
                              icon: const Icon(Icons.ios_share),
                              onPressed: () => share('Reported answer', r.toMarkdown()),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => reports.remove(r),
                            ),
                          ],
                        ),
                        chevron: false,
                      ),
                  ],
                ),
                SettingsGroup(
                  rows: [
                    SettingsRow(
                      title: 'Share all reports',
                      chevron: false,
                      onTap: () => share('Reported answers', [for (final r in items) r.toMarkdown()].join('\n---\n\n')),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
