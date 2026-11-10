import 'package:flutter/material.dart';

import '../../layout/adaptive.dart';

/// A page in two columns on a desktop window (the app's [TwoColumn]), each column scrolling by itself; one column, [left] then [right], where
/// they do not fit.
class ScrollingTwoColumn extends StatelessWidget {
  const ScrollingTwoColumn({super.key, required this.left, required this.right, this.padding = const EdgeInsets.fromLTRB(24, 8, 24, 24)});

  final Widget left;
  final Widget right;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => TwoColumn(
        narrow: ListView(padding: padding, children: [left, const SizedBox(height: 24), right]),
        left: SingleChildScrollView(padding: EdgeInsets.fromLTRB(padding.left, padding.top, 0, padding.bottom), child: left),
        right: SingleChildScrollView(padding: EdgeInsets.fromLTRB(0, padding.top, padding.right, padding.bottom), child: right),
      );
}
