import 'package:flutter/material.dart';

import '../theme.dart';

/// One row of a [FactTable].
class FactRow {
  const FactRow({required this.key, required this.leading, required this.label, this.items, required this.size, this.onTap});

  /// The row's key (the phone's row for the same item has it too).
  final Key key;
  final Widget leading;
  final String label;

  /// The count column; null leaves it empty.
  final String? items;
  final String size;

  /// Opens the item; a row with none is not a link and shows no chevron.
  final VoidCallback? onTap;
}

/// A list of things with comparable facts as a table, for the Linux desktop: a header (small caps), then one 44-pixel row each with
/// the kind, the item count and the size (numbers right-aligned). Used in place of the phone's card rows, which
/// the caller keeps for any other window.
class FactTable extends StatelessWidget {
  const FactTable({super.key, required this.headers, required this.rows});

  /// The three column heads: kind, items, size.
  final List<String> headers;
  final List<FactRow> rows;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final line = k.secondary.withValues(alpha: 0.2);
    final head = TextStyle(fontSize: 12, letterSpacing: 0.6, fontWeight: FontWeight.w500, color: k.secondary);
    final cell = TextStyle(fontSize: 14, color: k.text);
    Widget cells(Widget first, Widget items, Widget size) => Row(
      children: [
        Expanded(child: first),
        SizedBox(width: 90, child: Align(alignment: Alignment.centerRight, child: items)),
        SizedBox(width: 110, child: Align(alignment: Alignment.centerRight, child: size)),
        const SizedBox(width: 40),
      ],
    );
    return Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.only(left: 16),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line))),
            child: cells(
              Align(alignment: Alignment.centerLeft, child: Text(headers[0].toUpperCase(), style: head)),
              Text(headers[1].toUpperCase(), style: head),
              Text(headers[2].toUpperCase(), style: head),
            ),
          ),
          for (var i = 0; i < rows.length; i++)
            Container(
              decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: line))),
              child: InkWell(
                key: rows[i].key,
                onTap: rows[i].onTap,
                child: SizedBox(
                  height: 44,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: cells(
                      Row(
                        children: [
                          rows[i].leading,
                          const SizedBox(width: 12),
                          Expanded(child: Text(rows[i].label, maxLines: 1, overflow: TextOverflow.ellipsis, style: cell.copyWith(fontSize: 15, fontWeight: FontWeight.w500))),
                        ],
                      ),
                      Text(rows[i].items ?? '', style: cell),
                      Text(rows[i].size, style: cell),
                    ).wrapChevron(rows[i].onTap != null, k.secondary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

extension on Widget {
  /// The row with a chevron at its right edge when [on] (the 40 pixels [FactTable] leaves there).
  Widget wrapChevron(bool on, Color color) => Stack(
    fit: StackFit.expand,
    alignment: Alignment.centerRight,
    children: [
      this,
      if (on) Padding(padding: const EdgeInsets.only(right: 10), child: Icon(Icons.chevron_right, size: 20, color: color)),
    ],
  );
}
