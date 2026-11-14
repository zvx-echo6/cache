import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_links.dart';

/// Words that point to another part of Cache, as a link to it (the owner's rule: everything that points to something links to
/// it). The same look as a link in the guide and in notes: the accent colour, underlined.
class LinkText extends StatelessWidget {
  const LinkText(this.text, {super.key, required this.onTap, this.style});

  final String text;
  final VoidCallback onTap;

  /// The text's own style (its size and weight); the link's colour and underline go on top.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      link: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Text(
          text,
          style: (style ?? const TextStyle()).copyWith(color: k.accent, decoration: TextDecoration.underline, decorationColor: k.accent),
        ),
      ),
    );
  }
}

/// A [LinkText] to an [AppPlace], or the words alone when the app cannot open places here (a test without a shell).
Widget placeLink(String text, AppPlace place, {Key? key, TextStyle? style}) {
  final open = openAppPlace;
  if (open == null) return Text(text, key: key, style: style);
  return LinkText(text, key: key, style: style, onTap: () => open(place));
}
