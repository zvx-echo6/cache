// The First aid module: its home (a list of tools, one so far) and the CPR metronome screen.


import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../net/web_link.dart';
import '../platform/app_log.dart';
import '../platform/screen_awake.dart';
import '../theme.dart';
import 'cpr_feedback.dart';
import 'cpr_metronome.dart';
import 'cpr_prefs.dart';
import 'emergency_number.dart';

/// WORDING (the reminder the owner approved, shown before the metronome starts).
const String kCprReminder = 'Push hard and fast in the center of the chest, 5–6 cm (2–2.4 in) deep. Let the chest come all the way back up.';

/// The source the guidance is taken from: its credit line (the wording MedlinePlus asks for) and the page it links to.
const String kFirstAidSourceText = 'Source: MedlinePlus, National Library of Medicine';
const String kFirstAidSourceUrl = 'https://medlineplus.gov/cpr.html';

/// The module's home: the tools First aid has.
class FirstAidScreen extends StatelessWidget {
  const FirstAidScreen({super.key, required this.prefs, this.feedback, this.canCall, this.openDialer});

  final CprPrefs prefs;

  /// How the metronome makes its tick and buzz (the phone's by default).
  final CprFeedback? feedback;

  /// Whether the Call button is drawn (a phone has a dialer; null: ask the platform).
  final bool? canCall;

  /// How the dialer opens (a test gives its own).
  final Future<bool> Function()? openDialer;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('First aid')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              key: const ValueKey('first-aid-cpr'),
              minTileHeight: 72,
              leading: Icon(Icons.monitor_heart_outlined, color: k.accent, size: 30),
              title: Text('CPR metronome', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: k.text)),
              subtitle: Text('Keeps the beat for chest compressions', style: TextStyle(fontSize: 15, color: k.secondary)),
              trailing: Icon(Icons.chevron_right, color: k.secondary),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CprScreen(prefs: prefs, feedback: feedback, canCall: canCall, openDialer: openDialer))),
            ),
          ),
        ],
      ),
    );
  }
}

/// The CPR metronome: ready, pushing (with the count or hands-only), and the pause for two breaths. "Call emergency services" is on
/// every one of them (where the device has a dialer).
class CprScreen extends StatefulWidget {
  const CprScreen({super.key, required this.prefs, this.feedback, this.canCall, this.openDialer, this.metronome});

  final CprPrefs prefs;
  final CprFeedback? feedback;
  final bool? canCall;
  final Future<bool> Function()? openDialer;

  /// A test's own metronome (with its own clock); the screen makes one when null.
  final CprMetronome? metronome;

  @override
  State<CprScreen> createState() => _CprScreenState();
}

class _CprScreenState extends State<CprScreen> {
  late final CprMetronome _m;

  @override
  void initState() {
    super.initState();
    _m = widget.metronome ??
        CprMetronome(
          feedback: widget.feedback ?? ChannelCprFeedback(),
          keepAwake: keepScreenOn,
          log: (line) => appLog.add(LogLevel.detailed, 'INFO', line),
          sound: widget.prefs.sound,
          vibration: widget.prefs.vibration,
        );
  }

  @override
  void dispose() {
    _m.dispose(); // the screen is let go
    super.dispose();
  }

  bool get _canCall => widget.canCall ?? emergencyDialerAvailable;

  Future<void> _call() async {
    final ok = await (widget.openDialer ?? () => openEmergencyDialer())();
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Couldn't open the phone app. Dial the emergency number yourself.")));
    }
  }

  Widget _callButton(BuildContext context, {bool compact = false}) {
    if (!_canCall) return const SizedBox.shrink();
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        width: double.infinity,
        height: compact ? 56 : 68,
        child: FilledButton.icon(
          key: const ValueKey('cpr-call'),
          style: FilledButton.styleFrom(backgroundColor: k.emergency, foregroundColor: Colors.white, textStyle: TextStyle(fontSize: compact ? 17 : 20, fontWeight: FontWeight.w700)),
          onPressed: _call,
          icon: Icon(Icons.call, size: compact ? 22 : 28),
          label: const Text('Call emergency services'),
        ),
      ),
    );
  }

  /// The beat's circle: it swells a little on each compression.
  Widget _pulse(BuildContext context, Widget child, {double core = 230}) {
    final k = context.t;
    return TweenAnimationBuilder<double>(
      key: ValueKey('beat-${_m.totalBeats}'),
      tween: Tween(begin: 1.07, end: 1.0),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOut,
      builder: (context, s, c) => Transform.scale(scale: s, child: c),
      child: SizedBox(
        width: core + 70,
        height: core + 70,
        child: Stack(alignment: Alignment.center, children: [
          Container(width: core + 70, height: core + 70, decoration: BoxDecoration(shape: BoxShape.circle, color: k.primary.withValues(alpha: 0.14))),
          Container(width: core + 36, height: core + 36, decoration: BoxDecoration(shape: BoxShape.circle, color: k.primary.withValues(alpha: 0.26))),
          Container(width: core, height: core, decoration: BoxDecoration(shape: BoxShape.circle, color: k.primary), alignment: Alignment.center, child: SizedBox(width: core - 24, child: FittedBox(fit: BoxFit.scaleDown, child: child))),
        ]),
      ),
    );
  }

  Widget _timer(BuildContext context) {
    final k = context.t;
    return Column(children: [
      Text(cprClock(_m.elapsed), key: const ValueKey('cpr-time'), style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700, color: k.text, fontFeatures: const [FontFeature.tabularFigures()])),
      Text('$kCprPerMinute per minute', style: TextStyle(fontSize: 16, color: k.secondary)),
    ]);
  }

  /// One screen's content: it scrolls when the phone is too small, and every part is built (so Call is always there).
  Widget _page({required List<Widget> children}) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _ready(BuildContext context) {
    final k = context.t;
    return _page(
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<CprMode>(
            key: const ValueKey('cpr-mode'),
            segments: const [
              ButtonSegment(value: CprMode.withBreaths, label: Text('With breaths (30:2)')),
              ButtonSegment(value: CprMode.handsOnly, label: Text('Hands-only')),
            ],
            selected: {_m.mode},
            onSelectionChanged: (s) => _m.setMode(s.first),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 150,
          child: FilledButton(
            key: const ValueKey('cpr-start'),
            style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700)),
            onPressed: _m.start,
            child: const Text('Start'),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(padding: const EdgeInsets.all(16), child: Text(kCprReminder, style: TextStyle(fontSize: 17, height: 1.35, color: k.text))),
        ),
        _callButton(context),
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: [
          _toggleChip(context, const ValueKey('cpr-sound'), Icons.volume_up_outlined, 'Sound', _m.sound, (v) {
            _m.setSound(v);
            widget.prefs.set(sound: v);
          }),
          _toggleChip(context, const ValueKey('cpr-vibration'), Icons.vibration, 'Vibration', _m.vibration, (v) {
            _m.setVibration(v);
            widget.prefs.set(vibration: v);
          }),
        ]),
        const SizedBox(height: 24),
        const Center(child: _SourceLine()),
      ],
    );
  }

  Widget _pushing(BuildContext context) {
    final k = context.t;
    final counted = _m.mode == CprMode.withBreaths;
    return _page(
      children: [
        Center(child: _timer(context)),
        const SizedBox(height: 16),
        Center(
          child: _pulse(
            context,
            counted
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${_m.count} / $kCprCompressions', key: const ValueKey('cpr-count'), style: TextStyle(fontSize: 64, fontWeight: FontWeight.w700, color: k.onPrimary)),
                    Text('compressions', style: TextStyle(fontSize: 18, color: k.onPrimary.withValues(alpha: 0.85))),
                  ])
                : Text('Push', key: const ValueKey('cpr-push'), style: TextStyle(fontSize: 64, fontWeight: FontWeight.w700, color: k.onPrimary)),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            counted ? 'Push hard and fast' : 'Keep pushing until help arrives',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: counted ? 22 : 26, fontWeight: FontWeight.w700, color: k.text),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 64,
          child: OutlinedButton(key: const ValueKey('cpr-stop'), style: OutlinedButton.styleFrom(textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)), onPressed: _m.stop, child: const Text('Stop')),
        ),
        _callButton(context, compact: true),
      ],
    );
  }

  Widget _breaths(BuildContext context) {
    final k = context.t;
    return _page(
      children: [
        Center(child: _timer(context)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
          decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(kControlRadius), border: Border.all(color: k.accent, width: 3)),
          child: Column(children: [
            Text('Give 2 breaths', textAlign: TextAlign.center, style: TextStyle(fontSize: 46, fontWeight: FontWeight.w800, color: k.text, height: 1.1)),
            const SizedBox(height: 12),
            Text('One second each. Watch the chest rise.', textAlign: TextAlign.center, style: TextStyle(fontSize: 19, color: k.secondary)),
            const SizedBox(height: 18),
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(shape: BoxShape.circle, color: k.primary),
              alignment: Alignment.center,
              child: Text('${_m.breathsLeft}', key: const ValueKey('cpr-breaths-left'), style: TextStyle(fontSize: 52, fontWeight: FontWeight.w700, color: k.onPrimary)),
            ),
            const SizedBox(height: 10),
            Text('Pushing starts again in ${_m.breathsLeft}', style: TextStyle(fontSize: 17, color: k.secondary)),
          ]),
        ),
        const SizedBox(height: 20),
        SizedBox(height: 64, child: FilledButton(key: const ValueKey('cpr-continue'), style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)), onPressed: _m.continueNow, child: const Text('Continue'))),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, height: 52, child: OutlinedButton(key: const ValueKey('cpr-stop'), onPressed: _m.stop, child: const Text('Stop'))),
        _callButton(context, compact: true),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _m,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('CPR metronome')),
          body: switch (_m.phase) {
            CprPhase.ready => _ready(context),
            CprPhase.pushing => _pushing(context),
            CprPhase.breaths => _breaths(context),
          },
        ),
      );
}

/// "Source: MedlinePlus, National Library of Medicine", a link to the page the guidance is from.
class _SourceLine extends StatefulWidget {
  const _SourceLine();

  @override
  State<_SourceLine> createState() => _SourceLineState();
}

class _SourceLineState extends State<_SourceLine> {
  late final TapGestureRecognizer _tap = TapGestureRecognizer()..onTap = () => openWebLink(context, kFirstAidSourceUrl);

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Text.rich(
      TextSpan(text: kFirstAidSourceText, recognizer: _tap, style: TextStyle(fontSize: 13, color: k.accent, decoration: TextDecoration.underline, fontWeight: FontWeight.w600)),
      key: const ValueKey('cpr-source'),
      textAlign: TextAlign.center,
    );
  }
}


/// A on/off chip that says which it is: on is filled in the theme's primary colour with a check mark; off is outlined with no fill and no check.
Widget _toggleChip(BuildContext context, Key key, IconData icon, String label, bool on, ValueChanged<bool> onChanged) {
  final k = context.t;
  final fg = on ? k.onPrimary : k.text;
  // The check is its own leading icon (the chip's built-in check would draw over the sound or vibration icon).
  return FilterChip(
    key: key,
    avatar: on ? Icon(Icons.check, size: 20, color: fg) : null,
    label: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 20, color: fg), const SizedBox(width: 6), Text(label)]),
    labelStyle: TextStyle(color: fg, fontWeight: FontWeight.w600),
    selected: on,
    showCheckmark: false,
    selectedColor: k.primary,
    backgroundColor: Colors.transparent,
    side: BorderSide(color: on ? k.primary : k.secondary, width: on ? 1 : 1.5),
    onSelected: onChanged,
  );
}
