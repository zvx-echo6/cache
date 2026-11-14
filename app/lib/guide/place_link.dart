import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_links.dart';
import 'guide_reader.dart' show goToAppPlace;

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
    // only the words are the link, also in a column that stretches its children
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      heightFactor: 1,
      child: Semantics(
      link: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Text(
          text,
          style: (style ?? const TextStyle()).copyWith(color: k.accent, decoration: TextDecoration.underline, decorationColor: k.accent),
        ),
      ),
      ),
    );
  }
}

/// A [LinkText] to an [AppPlace], opened as a guide link opens it ([goToAppPlace]). The shell's place screens are read when it
/// is tapped, not when it is built, so a link drawn before the shell set them still goes there.
Widget placeLink(String text, AppPlace place, {Key? key, TextStyle? style}) =>
    Builder(key: key, builder: (context) => LinkText(text, style: style, onTap: () => goToAppPlace(context, place)));
