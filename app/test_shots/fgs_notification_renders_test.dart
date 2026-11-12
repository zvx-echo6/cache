// The notification shade for the foreground-service add (design only; no service code): the notification while PDFs are being
// added in the background, and the ones that end it (added, paused, failed), as Android 15's shade draws them: a rounded card with
// the app's small icon in a round badge in the accent, "Cache · 12 min left · now" on the header line, the title and the text, a
// progress bar, and (when the card is opened out) the action buttons. 390 wide, light and dark. The wording is wording.md's.
//   1-adding         the notification while adding: collapsed, and opened out with Pause
//   2-ended          Added; added with one that could not be; could not be added
//   3-paused         paused by you; battery low; Android's time limit
//   4-lock-screen    the same, as the lock screen shows it (private version: no file names)
// flutter test test_shots/fgs_notification_renders_test.dart --update-goldens  (pictures in test_shots/fgs/)

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const _out = 'fgs';

class _Shade {
  const _Shade({required this.dark, required this.accent});
  final bool dark;
  final Color accent;

  Color get backdrop => dark ? const Color(0xFF141318) : const Color(0xFFE7E2EA);
  Color get card => dark ? const Color(0xFF2B2930) : const Color(0xFFFAF6FC);
  Color get onCard => dark ? const Color(0xFFE6E0E9) : const Color(0xFF1D1B20);
  Color get onCardVariant => dark ? const Color(0xFFCAC4D0) : const Color(0xFF49454F);
  Color get track => dark ? const Color(0xFF49454F) : const Color(0xFFDDD8E0);
  Color get note => dark ? const Color(0xFF938F99) : const Color(0xFF79747E);
}

class _Note {
  const _Note({required this.title, required this.text, this.subText, this.when = 'now', this.progress, this.actions = const [], this.expanded = false, this.bigText});
  final String title;
  final String text;
  final String? subText;
  final String when;

  /// 0..1; null: no bar.
  final double? progress;
  final List<String> actions;

  /// Opened out: the full text, and the actions.
  final bool expanded;
  final String? bigText;
}

class _Card extends StatelessWidget {
  const _Card(this.n, this.shade, this.icon);
  final _Note n;
  final _Shade shade;
  final ui.Image icon;

  @override
  Widget build(BuildContext context) {
    final head = TextStyle(fontFamily: 'Roboto', fontSize: 12, color: shade.onCardVariant, height: 1.2);
    return Container(
      decoration: BoxDecoration(color: shade.card, borderRadius: BorderRadius.circular(28)),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        // The header line: the small icon in a round badge in the notification's colour, the app name, what is left, the time.
        Row(children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: shade.accent),
            padding: const EdgeInsets.all(4),
            child: RawImage(image: icon, color: shade.dark ? const Color(0xFF1D1B20) : Colors.white, fit: BoxFit.contain),
          ),
          const SizedBox(width: 8),
          Text('Cache', style: head.copyWith(fontWeight: FontWeight.w500)),
          if (n.subText != null) Text(' · ${n.subText}', style: head),
          Text(' · ${n.when}', style: head),
          const Spacer(),
          Icon(n.expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: shade.onCardVariant),
        ]),
        const SizedBox(height: 8),
        Text(n.title, style: TextStyle(fontFamily: 'Roboto', fontSize: 16, fontWeight: FontWeight.w500, color: shade.onCard, height: 1.25)),
        const SizedBox(height: 2),
        Text(n.expanded && n.bigText != null ? n.bigText! : n.text,
            maxLines: n.expanded ? 4 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: 'Roboto', fontSize: 14, color: shade.onCardVariant, height: 1.3)),
        if (n.progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: n.progress, minHeight: 6, backgroundColor: shade.track, valueColor: AlwaysStoppedAnimation(shade.accent)),
          ),
        ],
        if (n.expanded && n.actions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            for (final a in n.actions)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: Text(a, style: TextStyle(fontFamily: 'Roboto', fontSize: 14, fontWeight: FontWeight.w500, color: shade.accent, height: 2.2)),
              ),
          ]),
        ],
      ]),
    );
  }
}

/// A phone's shade: the status bar, then the cards, each with a small design note above it (not part of the phone).
class _Page extends StatelessWidget {
  const _Page({required this.shade, required this.icon, required this.items, required this.lock});
  final _Shade shade;
  final ui.Image icon;
  final List<(String, _Note)> items;
  final bool lock;

  @override
  Widget build(BuildContext context) {
    final big = TextStyle(fontFamily: 'Roboto', fontSize: lock ? 64 : 16, fontWeight: FontWeight.w300, color: shade.onCard, height: 1.1);
    return Container(
      color: shade.backdrop,
      padding: const EdgeInsets.fromLTRB(16, 54, 16, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (lock) ...[
          Center(child: Text('4:12', style: big)),
          Center(child: Text('Thu, Nov 12', style: TextStyle(fontFamily: 'Roboto', fontSize: 14, color: shade.onCardVariant))),
          const SizedBox(height: 28),
        ] else
          Padding(padding: const EdgeInsets.only(left: 8, bottom: 14), child: Text('4:12', style: big)),
        for (final (label, n) in items) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
            child: Text(label, style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: shade.note)),
          ),
          _Card(n, shade, icon),
        ],
      ]),
    );
  }
}

const _adding = _Note(
  title: 'Adding PDFs to Bookshelves',
  text: '2 of 5 PDFs · Radio field manual',
  subText: '12 min left',
  progress: 0.36,
);

final _addingOpen = _Note(
  title: _adding.title,
  text: _adding.text,
  subText: _adding.subText,
  progress: _adding.progress,
  expanded: true,
  bigText: '2 of 5 PDFs · Radio field manual\nGarden notes and 2 more waiting',
  actions: const ['Pause'],
);

const _added = _Note(title: 'Added 5 PDFs to Bookshelves', text: 'Adding to search index');
const _addedNamed = _Note(title: 'Added 3 PDFs to Field guides', text: 'Adding to search index');
const _addedSome = _Note(title: 'Added 4 of 5 PDFs to Bookshelves', text: '1 could not be added · tap to see');
const _failed = _Note(title: 'This PDF could not be added', text: 'Radio field manual · Nothing was added. Your PDF was not changed.');
const _pausedYou = _Note(title: 'Paused · 2 of 5 PDFs', text: 'Paused by you', progress: 0.36, expanded: true, actions: ['Resume']);
const _pausedBattery = _Note(title: 'Paused · 2 of 5 PDFs', text: 'Battery low (12%) · plug in to continue', progress: 0.36, expanded: true, actions: ['Resume anyway']);
const _pausedLimit = _Note(title: 'Paused · 2 of 5 PDFs', text: 'Android limits background work. It carries on while charging, or open Cache.', progress: 0.36);
const _lockAdding = _Note(title: 'Adding PDFs', text: 'In the background', subText: '12 min left', progress: 0.36);
const _lockAdded = _Note(title: 'PDFs added', text: 'Open Cache to see them');

void main() {
  late ui.Image icon;
  setUpAll(() async {
    await loadShotFonts();
  });

  for (final (name, id) in [('light', CacheThemeId.light), ('dark', CacheThemeId.dark)]) {
    final shade = _Shade(dark: id == CacheThemeId.dark, accent: cacheTokens[id]!.accent);
    Future<void> draw(WidgetTester tester, String file, double height, List<(String, _Note)> items, {bool lock = false}) async {
      phone(tester, size: Size(390, height), ratio: 3);
      icon = (await tester.runAsync(() => decodeImageFromList(File('android/app/src/main/res/drawable-xxxhdpi/ic_stat_cache.png').readAsBytesSync())))!;
      await tester.pumpWidget(shotApp(
        Scaffold(backgroundColor: shade.backdrop, body: SingleChildScrollView(child: _Page(shade: shade, icon: icon, items: items, lock: lock))),
        theme: id,
        insets: EdgeInsets.zero,
      ));
      await tester.pump();
      await snap(tester, _out, '$file-390-$name');
    }

    testWidgets('1 adding, $name', (tester) async {
      await draw(tester, '1-adding', 480, [('while adding · collapsed (the actions show when it is opened out)', _adding), ('while adding · opened out', _addingOpen)]);
    });
    testWidgets('2 ended, $name', (tester) async {
      await draw(tester, '2-ended', 660, [('finished', _added), ('finished, a library the person named keeps its name', _addedNamed), ('finished, one could not be added', _addedSome), ('one PDF could not be added', _failed)]);
    });
    testWidgets('3 paused, $name', (tester) async {
      await draw(tester, '3-paused', 640, [('paused by you', _pausedYou), ('paused: battery low', _pausedBattery), ('paused: the time limit', _pausedLimit)]);
    });
    testWidgets('4 lock screen, $name', (tester) async {
      await draw(tester, '4-lock-screen', 520, [('lock screen · adding (private version)', _lockAdding), ('lock screen · finished (private version)', _lockAdded)], lock: true);
    });
  }
}
