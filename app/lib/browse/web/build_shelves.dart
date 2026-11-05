import 'package:flutter/material.dart';

import '../../theme.dart';
import 'build_api.dart';

int compareShelfBooks(BuildBook a, BuildBook b) {
  if (a.unsorted != b.unsorted) return a.unsorted ? -1 : 1;
  final division = (a.division ?? '').compareTo(b.division ?? '');
  if (division != 0) return division;
  List<int> number(BuildBook book) {
    final tail = (book.callNumber ?? '').split('-').last.split('.');
    return [int.tryParse(tail.first) ?? 0, tail.length > 1 ? int.tryParse(tail[1]) ?? 0 : 0];
  }

  final x = number(a), y = number(b);
  for (var i = 0; i < 2; i++) {
    final result = x[i].compareTo(y[i]);
    if (result != 0) return result;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

String shelfLabel(String division, List<BuildClass> classes) {
  if (division == 'unsorted') return 'Unsorted';
  for (final c in classes) {
    for (final d in c.divisions) {
      if (d.number == division) return '${c.number} ${c.name} / ${d.number} ${d.name}';
    }
  }
  return division;
}

/// The approved CDS tree; empty shelves remain visible and dimmed.
class BuildShelves extends StatelessWidget {
  const BuildShelves({
    super.key,
    required this.classes,
    required this.books,
    required this.selected,
    required this.onSelect,
    required this.number,
    required this.onGo,
  });
  final List<BuildClass> classes;
  final List<BuildBook> books;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final TextEditingController number;
  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final colors = context.t;
    final counts = <String, int>{};
    for (final b in books) {
      final key = b.division ?? 'unsorted';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    Widget row(String label, String? value, int count, {bool empty = false}) => ListTile(
      dense: true,
      selected: selected == value,
      selectedColor: colors.accent,
      title: Text(label, style: TextStyle(fontSize: 13, color: empty ? colors.secondary.withValues(alpha: 0.55) : colors.text)),
      trailing: Text('$count', style: TextStyle(color: colors.secondary, fontSize: 12)),
      onTap: () => onSelect(value),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('go-to-number'),
          controller: number,
          onSubmitted: (_) => onGo(),
          decoration: InputDecoration(
            labelText: 'Go to a number',
            hintText: '210 or CDS 210-001',
            suffixIcon: IconButton(tooltip: 'Go', onPressed: onGo, icon: const Icon(Icons.arrow_forward)),
          ),
        ),
        const SizedBox(height: 8),
        row('All books', null, books.length),
        row('Unsorted', 'unsorted', counts['unsorted'] ?? 0),
        for (final c in classes)
          ExpansionTile(
            key: ValueKey('class-${c.number}'),
            initiallyExpanded: c.divisions.any((d) => d.number == selected),
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text('${c.number} ${c.name}', style: TextStyle(fontSize: 13, color: colors.text)),
            subtitle: Text(
              '${c.divisions.fold<int>(0, (sum, d) => sum + (counts[d.number] ?? 0))} books',
              style: TextStyle(fontSize: 11, color: colors.secondary),
            ),
            children: [
              for (final d in c.divisions.where((d) => d.assigned))
                row('${d.number} ${d.name}', d.number, counts[d.number] ?? 0, empty: (counts[d.number] ?? 0) == 0),
            ],
          ),
      ],
    );
  }
}

/// Suggestions come from the book's stored classifier result, never a UI guess.
class PlaceBookDialog extends StatefulWidget {
  const PlaceBookDialog({super.key, required this.book, required this.classes});
  final BuildBook book;
  final List<BuildClass> classes;
  @override
  State<PlaceBookDialog> createState() => _PlaceBookDialogState();
}

class _PlaceBookDialogState extends State<PlaceBookDialog> {
  String? selected;
  String query = '';
  @override
  Widget build(BuildContext context) {
    final colors = context.t;
    final available = widget.classes.expand((c) => c.divisions).where((d) => d.assigned && d.number != '060').toList();
    final suggested = widget.book.suggestions.where((s) => available.any((d) => d.number == s.division)).take(3);
    final filtered = available.where((d) => '${d.number} ${d.name}'.toLowerCase().contains(query.toLowerCase())).toList();
    return AlertDialog(
      title: const Text('Place it'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (widget.book.unsureReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(widget.book.unsureReason!, style: TextStyle(color: colors.secondary, fontSize: 13)),
              ),
            if (suggested.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Best matches', style: TextStyle(fontWeight: FontWeight.w600)),
              Wrap(
                spacing: 6,
                children: [
                  for (final s in suggested)
                    ChoiceChip(
                      label: Text('${s.division} ${s.name}'),
                      selected: selected == s.division,
                      onSelected: (_) => setState(() => selected = s.division),
                    ),
                ],
              ),
            ],
            TextField(
              key: const ValueKey('find-division'),
              decoration: const InputDecoration(labelText: 'Find a division', prefixIcon: Icon(Icons.search)),
              onChanged: (value) => setState(() => query = value),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final c in widget.classes)
                    if (filtered.any((d) => d.classNumber == c.number)) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          '${c.number} ${c.name}',
                          style: TextStyle(color: colors.secondary, fontWeight: FontWeight.w600),
                        ),
                      ),
                      for (final d in filtered.where((d) => d.classNumber == c.number))
                        ListTile(
                          dense: true,
                          title: Text('${d.number} ${d.name}'),
                          selected: selected == d.number,
                          leading: Icon(selected == d.number ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                          onTap: () => setState(() => selected = d.number),
                        ),
                    ],
                ],
              ),
            ),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'The file moves to ${shelfLabel(selected!, widget.classes)}. The book stays searchable.',
                  style: TextStyle(fontSize: 12, color: colors.secondary),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('confirm-place'),
          onPressed: selected == null ? null : () => Navigator.pop(context, selected),
          child: Text(selected == null ? 'Choose a division' : 'Place it in $selected'),
        ),
      ],
    );
  }
}
