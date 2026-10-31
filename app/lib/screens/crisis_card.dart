import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Where the nearest emergency room stands for the card.
enum ErState {
  /// Found in the offline map data: [NearestEr.place].
  found,

  /// No offline map (places) for the area.
  noMap,

  /// A map, but no emergency room in it.
  noEr,

  /// The location is off or there is no fix, and no last known place.
  locationOff,
}

class NearestEr {
  const NearestEr(this.state, {this.place, this.distance, this.lastKnown = false});

  final ErState state;
  final MapPlace? place;

  /// "4.2 mi".
  final String? distance;

  /// Measured from the last known place (the location is off now).
  final bool lastKnown;
}

/// What the card does on this phone: calls and texts through the phone's own apps (never dialled for the person), the nearest
/// emergency room from the offline map, and the Library's crisis guides. The screens only read this.
abstract class CrisisHelp {
  /// The device can place calls (an iPad or a tablet without a phone app cannot): else the numbers show as text.
  Future<bool> canPlaceCalls();

  /// False when there is no signal now (calls and texts need one); null when it cannot be told.
  Future<bool?> hasSignal();

  /// Opens the phone app or messages for [uri] (`tel:988`, `sms:988`, `tel:911`); false when it could not be opened.
  Future<bool> launch(Uri uri);

  Future<NearestEr> nearestEr();

  /// A crisis guide is in the Library.
  Future<bool> guidesInstalled();

  void openGuides(BuildContext context);
  void getGuides(BuildContext context);
  void getMap(BuildContext context);
  Future<void> turnOnLocation();
  void directions(BuildContext context, MapPlace place);
}

// The card's words. Section 2 and the states of section 8 of the spec are final: they are used exactly.
const String kCrisisTitle = "You don't have to go through this alone";
const String kCrisisBody = "If you're thinking about ending your life or hurting yourself, help is available right now.";
const String kCrisisRepeat = 'Help is available: 988 · nearest ER';
const List<String> kCrisisRightNow = [
  'Put distance between you and anything you could use to hurt yourself.',
  'Go where other people are.',
  'Reach one person you trust, even with one message.',
];

/// The safety card: the fixed words, Call 988 and Text 988, Call 911, the nearest emergency room with Directions, "Right now", and
/// the Library's crisis guides. Never red, no warning icon: the same card as Home's. [onClose] shows Close at the top right (the
/// card closes to its one line); the sheet passes its own.
class CrisisCard extends StatefulWidget {
  const CrisisCard({super.key, required this.help, this.onClose, this.announce = true});

  final CrisisHelp help;
  final VoidCallback? onClose;

  /// Says the title to a screen reader when it appears (politely: no focus is taken).
  final bool announce;

  @override
  State<CrisisCard> createState() => _CrisisCardState();
}

class _CrisisCardState extends State<CrisisCard> {
  bool? _canCall;
  bool? _signal;
  NearestEr? _er;
  bool? _guides;

  /// The number whose app could not be opened ("988" or "911").
  String? _failed;

  @override
  void initState() {
    super.initState();
    final h = widget.help;
    h.canPlaceCalls().then((v) => _set(() => _canCall = v)).catchError((_) => _set(() => _canCall = true));
    h.hasSignal().then((v) => _set(() => _signal = v)).catchError((_) {});
    h.nearestEr().then((v) => _set(() => _er = v)).catchError((_) => _set(() => _er = const NearestEr(ErState.noMap)));
    h.guidesInstalled().then((v) => _set(() => _guides = v)).catchError((_) {});
    if (widget.announce) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        SemanticsService.sendAnnouncement(View.of(context), kCrisisTitle, Directionality.of(context), assertiveness: Assertiveness.polite);
      });
    }
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  Future<void> _launch(String number, String scheme) async {
    HapticFeedback.lightImpact();
    final ok = await widget.help.launch(Uri.parse('$scheme:$number'));
    _set(() => _failed = ok ? null : number);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final small = TextStyle(fontSize: 12, height: 1.35, color: k.secondary);
    final head = TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: k.text);
    final canCall = _canCall ?? true;
    Widget gap([double h = 12]) => SizedBox(height: h);

    Widget button(String label, String spoken, VoidCallback onTap, {bool filled = false, Key? key}) {
      final style = ButtonStyle(minimumSize: const WidgetStatePropertyAll(Size(0, 52)), padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)));
      final text = Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600));
      return Semantics(
        label: spoken,
        button: true,
        excludeSemantics: true,
        child: filled
            ? FilledButton(key: key, style: style, onPressed: onTap, child: text)
            : OutlinedButton(
                key: key,
                style: style.copyWith(
                  foregroundColor: WidgetStatePropertyAll(k.text),
                  side: WidgetStatePropertyAll(BorderSide(color: k.text.withValues(alpha: 0.55), width: 1.5)),
                ),
                onPressed: onTap,
                child: text,
              ),
      );
    }

    Widget numberRow(String label, String number, String spoken) => Semantics(
      label: '$spoken: $number',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 15, color: k.text))),
            SelectableText(number, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text)),
          ],
        ),
      ),
    );

    final stack = scale > 1.3 || MediaQuery.sizeOf(context).width < 360;
    final call988 = button('Call 988', 'Call nine eight eight', () => _launch('988', 'tel'), filled: true, key: const ValueKey('crisis-call-988'));
    final text988 = button('Text 988', 'Text nine eight eight', () => _launch('988', 'sms'), key: const ValueKey('crisis-text-988'));
    final noSignal = _signal == false;
    final lifelineLine = _failed == '988'
        ? "Couldn't open the phone app. Dial 988 yourself."
        : noSignal
        ? 'No signal right now. Calls and texts need a signal.'
        : 'Suicide & Crisis Lifeline. Needs a phone signal.';

    final calls = <Widget>[
      if (!canCall) ...[
        Text("This device can't place calls. Use another phone.", key: const ValueKey('crisis-cannot-call'), style: TextStyle(fontSize: 13, color: k.text)),
        gap(4),
        numberRow('Call 988', '988', 'Call nine eight eight'),
        numberRow('Text 988', '988', 'Text nine eight eight'),
        Text('Suicide & Crisis Lifeline.', style: small),
        numberRow('Call 911', '911', 'Call nine one one'),
        Text("If you're in danger right now.", style: small),
      ] else ...[
        if (stack) ...[call988, gap(8), text988] else Row(children: [Expanded(child: call988), const SizedBox(width: 8), Expanded(child: text988)]),
        gap(4),
        Text(lifelineLine, key: const ValueKey('crisis-988-line'), style: small.copyWith(color: _failed == '988' ? k.text : k.secondary)),
        gap(),
        SizedBox(width: double.infinity, child: button('Call 911', 'Call nine one one', () => _launch('911', 'tel'), key: const ValueKey('crisis-call-911'))),
        gap(4),
        Text(_failed == '911' ? "Couldn't open the phone app. Dial 911 yourself." : "If you're in danger right now.", style: small),
      ],
    ];

    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Container(
        key: const ValueKey('crisis-card'),
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
        decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Semantics(header: true, child: Text(kCrisisTitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: k.text))),
                    ),
                  ),
                  if (widget.onClose != null)
                    TextButton(
                      key: const ValueKey('crisis-close'),
                      onPressed: widget.onClose,
                      style: TextButton.styleFrom(minimumSize: const Size(48, 44), padding: const EdgeInsets.symmetric(horizontal: 10)),
                      child: const Text('Close'),
                    ),
                ],
              ),
              gap(6),
              Text(kCrisisBody, style: TextStyle(fontSize: 14, height: 1.4, color: k.text)),
              gap(14),
              ...calls,
              gap(16),
              Text('Nearest emergency room', style: head),
              gap(4),
              _erRow(context, small),
              gap(16),
              Semantics(container: true, child: Text('Right now', style: head)),
              gap(4),
              for (var i = 0; i < kCrisisRightNow.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 20, child: Text('${i + 1}.', style: TextStyle(fontSize: 14, color: k.text))),
                      Expanded(child: Text(kCrisisRightNow[i], style: TextStyle(fontSize: 14, height: 1.35, color: k.text))),
                    ],
                  ),
                ),
              gap(12),
              _guidesRow(context, small),
            ],
          ),
        ),
      ),
    );
  }

  Widget _erRow(BuildContext context, TextStyle small) {
    final k = context.t;
    final er = _er;
    if (er == null) return Text('Looking in your map…', style: small);
    Widget withButton(String line, String label, VoidCallback onTap, Key key) => Row(
      children: [
        Expanded(child: Text(line, style: TextStyle(fontSize: 13, color: k.text))),
        TextButton(key: key, onPressed: onTap, child: Text(label)),
      ],
    );
    switch (er.state) {
      case ErState.noMap:
        return withButton('No offline map for this area.', 'Get map', () => widget.help.getMap(context), const ValueKey('crisis-get-map'));
      case ErState.noEr:
        return Text('No emergency room in your map data.', key: const ValueKey('crisis-no-er'), style: TextStyle(fontSize: 13, color: k.text));
      case ErState.locationOff:
        return withButton('Location is off.', 'Turn on location', widget.help.turnOnLocation, const ValueKey('crisis-location'));
      case ErState.found:
        final p = er.place!;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                label: [p.name, ?er.distance, ?p.phone].join(', '),
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text([p.name, ?er.distance].join(' · '), key: const ValueKey('crisis-er'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text)),
                    if (p.phone != null) Text(p.phone!, style: small),
                    if (er.lastKnown) Text('From your last known place.', style: small),
                  ],
                ),
              ),
            ),
            TextButton(key: const ValueKey('crisis-directions'), onPressed: () => widget.help.directions(context, p), child: const Text('Directions')),
          ],
        );
    }
  }

  Widget _guidesRow(BuildContext context, TextStyle small) {
    final k = context.t;
    final have = _guides ?? true;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('crisis-guides'),
        borderRadius: BorderRadius.circular(12),
        onTap: have ? () => widget.help.openGuides(context) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Crisis guides', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: k.text)),
                    Text(have ? 'In your Library, works offline' : 'Not in your Library yet', key: const ValueKey('crisis-guides-line'), style: small),
                  ],
                ),
              ),
              if (have)
                Icon(Icons.chevron_right, color: k.secondary)
              else
                TextButton(key: const ValueKey('crisis-get-guides'), onPressed: () => widget.help.getGuides(context), child: const Text('Get guides')),
            ],
          ),
        ),
      ),
    );
  }
}

/// The card's one line ("Help is available: 988 · nearest ER"): a later triggering turn in a row, or a card that was closed. A tap
/// opens the card in full.
class CrisisLine extends StatelessWidget {
  const CrisisLine({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: const ValueKey('crisis-line'),
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(child: Text(kCrisisRepeat, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text))),
                Icon(Icons.expand_more, color: k.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Need help now?" in Ask's top bar: the same card as a sheet (Close, a drag down or a tap outside closes it).
Future<void> showCrisisSheet(BuildContext context, CrisisHelp help) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
  builder: (ctx) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: CrisisCard(help: help, onClose: () => Navigator.pop(ctx)),
    ),
  ),
);

/// The quiet link: small, the muted colour, no icon.
class NeedHelpLink extends StatelessWidget {
  const NeedHelpLink({super.key, required this.help});

  final CrisisHelp help;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Need help now? Opens support options',
    button: true,
    excludeSemantics: true,
    child: TextButton(
      key: const ValueKey('need-help'),
      onPressed: () => showCrisisSheet(context, help),
      style: TextButton.styleFrom(
        foregroundColor: context.t.secondary,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      // At most 120 wide in the bar (the words take about 90), so the model's name keeps its room on a narrow phone.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: const Text('Need help now?', maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
      ),
    ),
  );
}
