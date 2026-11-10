import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../layout/adaptive.dart' show ContentWidth;
import '../../maps/ui/format.dart' show formatBytes;
import '../../theme.dart';
import '../discover_state.dart';
import '../ledger.dart' show InstallPlan;
import '../recipe.dart';
import '../words.dart';
import 'discover_screen.dart' show DiscoverLinks, discoverLinks;
import 'kit.dart';
import 'progress_page.dart';

/// Settings' "Run setup again": the wizard on its own page, with the activities added now, the place and its choice picked. Start
/// adds what is picked and not added yet; nothing added is taken away here (that is Remove, on the activity's page).
Future<void> openSetupAgain(BuildContext context, DiscoverState d) => Navigator.of(context).push(MaterialPageRoute<void>(
  builder: (_) => DiscoverWizard(discover: d, links: discoverLinks, initialPicked: {for (final a in d.catalogue.activities) if (d.ledger.has(a.id)) a.id}, again: true),
));

/// The number of steps the wizard has.
const int kWizardSteps = 5;

/// What the wizard's activities step shows for each activity, worked out from the plans in order: what it adds on its own, what it
/// adds on top of the activities picked above it, and the total of the picked ones.
class WizardSizes {
  const WizardSizes({required this.own, required this.extra, required this.total});

  final Map<String, int> own;
  final Map<String, int> extra;
  final int total;

  static Future<WizardSizes> of(DiscoverState d, Set<String> picked) async {
    final own = <String, int>{}, extra = <String, int>{};
    final counted = <String>{};
    var total = 0;
    for (final a in d.catalogue.activities) {
      final p = await d.plan(a);
      final adds = [for (final x in p.adds) if (x.item.kind.downloads) x.item];
      own[a.id] = await d.sizeOf(a);
      if (!picked.contains(a.id)) continue;
      var b = 0;
      for (final i in adds) {
        if (counted.add(i.key)) b += d.bytesOf(i);
      }
      extra[a.id] = b;
      total += b;
    }
    return WizardSizes(own: own, extra: extra, total: total);
  }
}

/// The first-run wizard, Discover's first screen: Next, Next, Next. One step a screen (welcome, where you are, activities, an
/// optional device link, a short summary), big cards with the defaults picked, Skip on every step, and nothing installs before
/// Start on the summary.
class DiscoverWizard extends StatefulWidget {
  const DiscoverWizard({super.key, required this.discover, required this.links, this.initialStep = 1, this.initialPicked, this.startDetailsOpen = false, this.again = false});

  /// Run again from Settings: its own page, closed when it is done.
  final bool again;

  final DiscoverState discover;
  final DiscoverLinks links;

  /// 1-based (renders open on a step).
  final int initialStep;

  /// The activities picked at first; the first two of the catalogue when null.
  final Set<String>? initialPicked;

  /// The summary opens with "See everything" open (renders).
  final bool startDetailsOpen;

  @override
  State<DiscoverWizard> createState() => _DiscoverWizardState();
}

class _DiscoverWizardState extends State<DiscoverWizard> {
  late int _step = widget.initialStep;
  late final Set<String> _picked = widget.initialPicked ?? {for (final a in widget.discover.catalogue.activities.take(2)) a.id};
  late bool _choose = widget.discover.choosePlace;
  bool _link = false;
  late bool _details = widget.startDetailsOpen;
  bool _starting = false;

  DiscoverState get d => widget.discover;

  void _go(int step) => setState(() => _step = step.clamp(1, kWizardSteps));

  Future<void> _back() async {
    if (_step > 1) {
      _go(_step - 1);
      return;
    }
    await Navigator.of(context).maybePop();
  }

  /// Next: the step's choice is acted on (the location asked for, the device link opened), then the next step.
  Future<void> _next() async {
    switch (_step) {
      case 2:
        if (!_choose) {
          await widget.links.askLocation?.call(context);
          await d.setPlace(null, chosen: false);
        }
      case 4:
        if (_link) await widget.links.linkDevice?.call(context);
      case 5:
        return _start();
    }
    if (mounted) _go(_step + 1);
  }

  /// Skip: on to the next step with nothing done for this one; on the summary, out of the wizard with nothing added.
  Future<void> _skip() async {
    if (_step < kWizardSteps) {
      if (_step == 3) setState(_picked.clear);
      _go(_step + 1);
      return;
    }
    await d.setFirstRunDone();
    if (mounted) await Navigator.of(context).maybePop();
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    final chosen = [for (final a in d.catalogue.activities) if (_picked.contains(a.id)) a];
    final nav = Navigator.of(context);
    for (final a in chosen) {
      await d.get(a);
    }
    await d.setFirstRunDone();
    final adding = [for (final a in chosen) if (d.progress(a).any((p) => p.$2.active)) a];
    final show = widget.again ? adding : chosen;
    if (show.isEmpty) {
      if (widget.again) nav.pop();
      return;
    }
    final route = MaterialPageRoute<void>(builder: (_) => ProgressPage(discover: d, activities: show));
    await (widget.again ? nav.pushReplacement(route) : nav.push(route));
  }

  Future<void> _chooseCard() async {
    final f = widget.links.choosePlace;
    if (f == null) return;
    final p = await f(context);
    if (p == null || !mounted) return;
    await d.setPlace(p, chosen: true);
    if (mounted) setState(() => _choose = true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (context, _) => Computed<WizardSizes>(
      listenable: d,
      compute: () => WizardSizes.of(d, _picked),
      builder: (context, sizes) => _page(context, sizes),
    ),
  );

  Widget _page(BuildContext context, WizardSizes? sizes) {
    final k = context.t;
    final free = d.device.freeBytes();
    final total = sizes?.total ?? 0;
    final usable = d.device.usableBytes();
    final tooBig = (usable ?? free) != null && total > (usable ?? free)!;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(key: const ValueKey('wizard-back'), tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: _back),
        actions: [
          TextButton(
            key: const ValueKey('wizard-skip'),
            onPressed: _starting ? null : _skip,
            style: TextButton.styleFrom(foregroundColor: k.accent, textStyle: buttonText(context, 14, FontWeight.w500)),
            child: const Text('Skip'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) => ListView(
          key: ValueKey('wizard-step-$_step'),
          padding: ContentWidth.padFor(c.maxWidth, min: 12, maxWidth: 560).copyWith(bottom: 16),
          children: switch (_step) {
            1 => _welcome(context),
            2 => _where(context),
            3 => _activities(context, sizes),
            4 => _device(context),
            _ => _summary(context, sizes, free),
          },
        ),
      ),
      bottomNavigationBar: Dock(
        maxWidth: 560,
        children: [
          if (_step == 3) SpaceLine(label: (s) => widget.again ? (total == 0 ? 'Nothing new to add' : '$s to add') : '$s selected', bytes: total, free: free, usable: usable),
          StepDots(step: _step, of: kWizardSteps),
          PillButton(
            key: const ValueKey('wizard-next'),
            label: _step == kWizardSteps ? 'Start' : 'Next',
            onPressed: _starting || (_step >= 3 && tooBig) ? null : _next,
          ),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
    child: Text(text, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: context.t.text)),
  );

  List<Widget> _welcome(BuildContext context) => [
    _heading(context, 'Welcome to Cache'),
    const DHint('A few quick choices to get started. You can change any of them later.'),
    const SizedBox(height: 32),
    const Center(child: BrandWordmark(height: 44)),
  ];

  List<Widget> _where(BuildContext context) {
    final p = d.device.place;
    return [
      _heading(context, 'Where are you?'),
      const DHint('Cache gets maps and weather for this area.'),
      BigCard(
        key: const ValueKey('wizard-here'),
        icon: discoverIcon('pin'),
        title: 'Where I am now',
        line: "Uses this device's location",
        selected: !_choose,
        onTap: () => setState(() => _choose = false),
      ),
      const SizedBox(height: 8),
      BigCard(
        key: const ValueKey('wizard-choose'),
        icon: discoverIcon('map'),
        title: 'Choose a place',
        line: _choose && p != null && p.name.isNotEmpty ? p.name : 'Search for it by name',
        selected: _choose,
        onTap: _chooseCard,
      ),
    ];
  }

  List<Widget> _activities(BuildContext context, WizardSizes? sizes) {
    var first = true;
    return [
      _heading(context, 'Pick your activities'),
      const DHint('Pick one or two. You can add more later.'),
      for (final a in d.catalogue.activities) ...[
        () {
          final on = _picked.contains(a.id);
          String? size;
          if (widget.again && d.ledger.has(a.id)) {
            size = 'Added';
          } else if (sizes != null) {
            if (on) {
              size = first ? formatBytes(sizes.extra[a.id] ?? 0) : '+${formatBytes(sizes.extra[a.id] ?? 0)}';
              first = false;
            } else {
              size = formatBytes(sizes.own[a.id] ?? 0);
            }
          }
          return BigCard(
            key: ValueKey('wizard-activity-${a.id}'),
            icon: discoverIcon(a.icon),
            title: a.title,
            line: a.tagline,
            size: size,
            selected: on,
            onTap: () => setState(() => on ? _picked.remove(a.id) : _picked.add(a.id)),
          );
        }(),
        const SizedBox(height: 8),
      ],
    ];
  }

  List<Widget> _device(BuildContext context) => [
    _heading(context, 'Link another device?'),
    const DHint('Share libraries, maps and notebooks between your devices.'),
    BigCard(
      key: const ValueKey('wizard-link'),
      icon: discoverIcon('link'),
      title: 'Link a device',
      line: 'Opens Sharing and sync',
      selected: _link,
      onTap: widget.links.linkDevice == null ? () {} : () => setState(() => _link = true),
    ),
    const SizedBox(height: 8),
    BigCard(
      key: const ValueKey('wizard-not-now'),
      icon: discoverIcon('later'),
      title: 'Not now',
      line: 'You can link one later in Settings',
      selected: !_link,
      onTap: () => setState(() => _link = false),
    ),
  ];

  List<Widget> _summary(BuildContext context, WizardSizes? sizes, int? free) {
    final k = context.t;
    final chosen = [for (final a in d.catalogue.activities) if (_picked.contains(a.id)) a];
    final total = sizes?.total ?? 0;
    final connects = d.connectsTo([
      for (final a in chosen)
        for (final i in a.items)
          if (!d.leftOutOf(a).contains(i.key) && i.kind == ItemKind.liveSource) i,
      for (final a in chosen)
        for (final i in a.items)
          if (!d.leftOutOf(a).contains(i.key) && i.kind == ItemKind.library) i,
    ]);
    return [
      _heading(context, chosen.isEmpty || (widget.again && total == 0) ? 'Nothing to add' : 'Ready to start'),
      Container(
        key: const ValueKey('wizard-summary'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(formatBytes(total), style: TextStyle(fontSize: 34, fontWeight: FontWeight.w300, color: k.text)),
            Text(['to download', if (free != null) '${formatBytes(free)} free'].join(' · '), style: TextStyle(fontSize: 13, color: free != null && total > free ? k.emergency : k.secondary)),
            const SizedBox(height: 8),
            SpaceBar(fraction: free == null || free <= 0 ? 0 : total / free, color: free != null && total > free ? k.emergency : null),
          ],
        ),
      ),
      if (connects.isNotEmpty) ...[
        const DLabel('Connects to'),
        RowStack(rows: [for (final (who, what) in connects) DRow(leading: DTile(discoverIcon('globe')), title: who, subtitle: what)]),
      ],
      if (chosen.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SeeAllToggle(key: const ValueKey('wizard-see-everything'), label: 'See everything', open: _details, onTap: () => setState(() => _details = !_details)),
        ),
      if (_details)
        for (final a in chosen) _ActivityDetails(discover: d, activity: a),
    ];
  }
}

/// What one activity adds and changes, for the summary's "See everything".
class _ActivityDetails extends StatelessWidget {
  const _ActivityDetails({required this.discover, required this.activity});

  final DiscoverState discover;
  final Activity activity;

  @override
  Widget build(BuildContext context) => Computed<InstallPlan>(
    listenable: discover,
    compute: () => discover.plan(activity),
    builder: (context, plan) {
      if (plan == null) return const SizedBox.shrink();
      final lines = planDownloadLines(discover, plan);
      final changes = [for (final c in plan.changes) settingWords(discover, c.key, c.after)];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DLabel(activity.title),
          MiniList(lines: [...lines, ...changes]),
        ],
      );
    },
  );
}
