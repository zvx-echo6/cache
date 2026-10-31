import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../actions/setup_status.dart' show kSetupAreas;
import '../app_state.dart';
import '../browse/browse_state.dart';
import '../browse/catalogue_screen.dart' show AddToLibraryScreen;
import '../maps/ui/format.dart';
import '../models/model_downloads.dart';
import '../regions/regions_state.dart';
import '../regions/ui/region_page.dart' show openRegionPage;
import '../sources/sources_state.dart';
import '../theme.dart';
import '../weather/weather_state.dart';

/// Where one line of "Set up Cache" stands.
enum SetupPhase { todo, running, done }

/// One line's state: what it says under its title, and how far a download has got while one runs.
class SetupLine {
  const SetupLine(this.phase, {this.detail, this.fraction});

  final SetupPhase phase;

  /// The words under the title: the result when done, the download while one runs; null keeps the line's reason.
  final String? detail;

  /// 0..1 while a download runs and its size is known.
  final double? fraction;

  bool get done => phase == SetupPhase.done;
}

/// The four lines, each worked out from what is on the phone.
class SetupStatus {
  const SetupStatus({required this.model, required this.area, required this.weather, required this.library});

  final SetupLine model;
  final SetupLine area;
  final SetupLine weather;
  final SetupLine library;

  List<SetupLine> get lines => [model, area, weather, library];
  int get doneCount => lines.where((l) => l.done).length;
  bool get allDone => doneCount == lines.length;
}

String _percent(double? f) => f == null ? '' : ' ${(f * 100).clamp(0, 100).toStringAsFixed(0)}%';

/// What "Set up Cache" reads (a chat model, a region with road routing, weather, a library) and what its buttons open. A line is
/// done from the real state, never from having been tapped.
class SetupCache {
  SetupCache({
    required this.app,
    required this.weather,
    required this.sources,
    this.regions,
    this.browse,
    this.modelDownloads,
    required this.chooseModel,
    required this.getArea,
    required this.turnOnWeather,
    required this.addLibrary,
    this.openGuide,
    this.openWeatherSettings,
  });

  final AppState app;
  final WeatherState weather;
  final SourcesState sources;
  final RegionsState? regions;
  final BrowseState? browse;

  /// The model downloads; the app's when null.
  final ModelDownloads? modelDownloads;

  final void Function(BuildContext) chooseModel;
  final void Function(BuildContext) getArea;
  final void Function(BuildContext) turnOnWeather;
  final void Function(BuildContext) addLibrary;

  /// Opens the guide at a section (its title); null leaves the guide buttons out.
  final void Function(BuildContext, String title)? openGuide;

  /// Settings > Weather and alerts: where "Turn on weather" goes once weather is on (a done line is not a dead line).
  final void Function(BuildContext)? openWeatherSettings;

  /// The guide section for each line: the same pointers the assistant's setup check gives (kSetupAreas).
  static final List<String> guideTitles = [
    for (final id in ['models', 'regions', 'live_data', 'libraries']) kSetupAreas.firstWhere((a) => a.id == id).guide,
  ];

  ModelDownloads? get downloads => modelDownloads ?? ModelDownloads.shared;

  Listenable get changes => Listenable.merge([app, weather, sources, ?regions, ?browse, ?browse?.libraries, ?downloads]);

  /// A chat model on the phone (loaded or not) is done; a chat model downloading or being copied in runs.
  SetupLine get modelLine {
    final e = app.active ?? app.models.firstOrNull;
    if (e != null) return SetupLine(SetupPhase.done, detail: '${app.displayName(e)} · ${formatBytes(e.size)}');
    final d = downloads;
    final f = d?.current;
    if (d != null && f != null && !d.isSearchModel(f)) {
      final fraction = d.total > 0 ? d.done / d.total : null;
      return SetupLine(SetupPhase.running, detail: '${d.labelOf(f)} · downloading${_percent(fraction)}', fraction: fraction);
    }
    if (app.copyProgress != null) {
      return SetupLine(SetupPhase.running, detail: '${app.copyName ?? 'Model'} · copying${_percent(app.copyProgress)}', fraction: app.copyProgress);
    }
    return const SetupLine(SetupPhase.todo);
  }

  /// The region whose download stopped (Cache was closed while it ran, or a part failed) while no region is ready: tapping "Get your
  /// area" carries it on.
  LocalRegion? get stoppedRegion {
    final withRouting = [for (final l in regions?.local ?? const <LocalRegion>[]) if (l.hasRouting) l];
    if (withRouting.any((l) => l.phase == RegionPhase.ready)) return null;
    final going = withRouting.firstOrNull;
    return going?.phase == RegionPhase.failed || going?.phase == RegionPhase.stopped ? going : null;
  }

  /// The first region with its road routing that is ready (places not published for its area count as done).
  LocalRegion? get readyRegion =>
      [for (final l in regions?.local ?? const <LocalRegion>[]) if (l.hasRouting && l.phase == RegionPhase.ready) l].firstOrNull;

  /// A region with its road routing on the phone is done ("Idaho · Ready"; places not published for it are said on its row in
  /// Regions, not here: one fact in one place); one with road routing on its way runs.
  SetupLine get areaLine {
    final withRouting = [for (final l in regions?.local ?? const <LocalRegion>[]) if (l.hasRouting) l];
    final ready = readyRegion;
    if (ready != null) return SetupLine(SetupPhase.done, detail: '${ready.name} · Ready');
    final going = withRouting.firstOrNull;
    if (going == null) return const SetupLine(SetupPhase.todo);
    // The same words as the region's row in Regions (one source: they always agree).
    return switch (going.phase) {
      RegionPhase.paused => SetupLine(SetupPhase.running, detail: '${going.name} · ${regions!.paused ?? 'paused'}', fraction: going.fraction),
      RegionPhase.stopped || RegionPhase.failed => SetupLine(SetupPhase.todo, detail: '${going.name} · ${going.partsLine}. Tap to carry on'),
      _ => SetupLine(SetupPhase.running, detail: '${going.name} · ${going.partsLine}', fraction: going.fraction),
    };
  }

  /// Weather is done once a forecast is on for a place it can use (the same test as the Weather card's "Turn on weather").
  Future<SetupLine> weatherLine() async =>
      await weather.needsTurnOn() ? const SetupLine(SetupPhase.todo) : const SetupLine(SetupPhase.done, detail: 'Weather and alerts on');

  /// A ZIM or a library on the phone is done; a ZIM downloading or a library being added runs.
  SetupLine get libraryLine {
    final zims = sources.zims;
    final libs = browse?.libraries?.libraries ?? const [];
    final n = zims.length + libs.length;
    if (n > 0) {
      final first = zims.isNotEmpty ? sources.titleOf(zims.first) : null;
      final String detail;
      if (first == null) {
        detail = n == 1 ? '1 library' : '$n libraries';
      } else {
        detail = n == 1 ? first : '$first and ${n - 1} more';
      }
      return SetupLine(SetupPhase.done, detail: detail);
    }
    final t = browse?.transfers.values.firstOrNull;
    if (t != null) {
      return SetupLine(SetupPhase.running, detail: '${t.entry.title} · downloading${_percent(t.fraction)}', fraction: t.fraction);
    }
    final task = browse?.libraries?.task;
    if (task != null && task.running) {
      return SetupLine(SetupPhase.running, detail: '${task.name} · adding${_percent(task.fraction)}', fraction: task.fraction);
    }
    return const SetupLine(SetupPhase.todo);
  }

  Future<SetupStatus> read() async =>
      SetupStatus(model: modelLine, area: areaLine, weather: await weatherLine(), library: libraryLine);
}

/// "Add to Library": the one Add screen (Kiwix's collections and your own library).
Future<void> showAddToLibrary(BuildContext context, BrowseState browse) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddToLibraryScreen(browse: browse)));

/// The "Set up Cache" block on Home: four lines, each with a tick when done and a chevron while it is not; tapping a line does it, and
/// pressing and holding it opens its part of the guide. It goes away by itself when all four are done; "Hide" switches it off before
/// that (it is an ordinary Home block, so Edit Home brings it back).
class SetupCard extends StatelessWidget {
  const SetupCard({super.key, required this.setup, this.onHide});

  final SetupCache setup;

  /// "Hide": switches the block off (Edit Home brings it back); null leaves it out.
  final VoidCallback? onHide;

  static const _titles = ['Choose a model', 'Get your area', 'Turn on weather', 'Add a library'];
  static const _reasons = ['The AI that answers your questions', 'Maps, directions and places for your area', 'Forecasts and alerts for your places', 'Wikipedia, medical and survival guides'];
  static const _keys = ['setup-model', 'setup-area', 'setup-weather', 'setup-library'];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: setup.changes,
    builder: (context, _) => FutureBuilder<SetupStatus>(
      future: setup.read(),
      builder: (context, snap) {
        final s = snap.data;
        if (s == null || s.allDone) return const SizedBox.shrink();
        // It keeps the gap the blocks under it keep between them.
        return Padding(padding: const EdgeInsets.only(bottom: 12), child: _card(context, s));
      },
    ),
  );

  Widget _card(BuildContext context, SetupStatus s) {
    final k = context.t;
    // A done line still opens its part of Cache: the model's list, the region's page, the weather settings, the Library.
    void area(BuildContext c) {
      final r = setup.readyRegion, regions = setup.regions;
      if (r != null && regions != null) {
        openRegionPage(c, regions, r.id);
      } else {
        setup.getArea(c);
      }
    }

    void weather(BuildContext c) => s.weather.done && setup.openWeatherSettings != null ? setup.openWeatherSettings!(c) : setup.turnOnWeather(c);
    final actions = [setup.chooseModel, area, weather, setup.addLibrary];
    // "Get your area" with a stopped region starts a download: it says "Starting…" at once.
    final starts = [false, setup.stoppedRegion != null, false, false];
    return Container(
      key: const ValueKey('setup-card'),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Set up Cache', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: k.text))),
              if (onHide != null)
                TextButton(
                  key: const ValueKey('setup-hide'),
                  onPressed: onHide,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 40), padding: const EdgeInsets.symmetric(horizontal: 12)),
                  child: const Text('Hide'),
                )
              else
                const SizedBox(height: 40),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Four things make Cache useful '),
                TextSpan(text: '(${s.doneCount} of ${s.lines.length} done)'),
              ]),
              key: const ValueKey('setup-count'),
              style: TextStyle(fontSize: 13, color: k.secondary),
            ),
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < 4; i++)
            _SetupRow(
              key: ValueKey(_keys[i]),
              title: _titles[i],
              reason: _reasons[i],
              line: s.lines[i],
              starts: starts[i],
              onTap: () => actions[i](context),
              onGuide: setup.openGuide == null ? null : () => setup.openGuide!(context, SetupCache.guideTitles[i]),
            ),
        ],
      ),
    );
  }
}

class _SetupRow extends StatefulWidget {
  const _SetupRow({super.key, required this.title, required this.reason, required this.line, required this.onTap, this.onGuide, this.starts = false});

  final String title;
  final String reason;
  final SetupLine line;
  final VoidCallback onTap;

  /// A tap starts a download (not a screen change): the line says "Starting…" with a spinner until its state moves.
  final bool starts;

  /// Opens this line's section of the guide.
  final VoidCallback? onGuide;

  @override
  State<_SetupRow> createState() => _SetupRowState();
}

class _SetupRowState extends State<_SetupRow> {
  bool _starting = false;
  Timer? _giveUp;

  String get title => widget.title;
  String get reason => widget.reason;
  SetupLine get line => widget.line;
  VoidCallback? get onGuide => widget.onGuide;

  @override
  void didUpdateWidget(_SetupRow old) {
    super.didUpdateWidget(old);
    // The download moved (its line changed): the line shows where it is now.
    if (_starting && (old.line.phase != line.phase || old.line.detail != line.detail)) _stop();
  }

  @override
  void dispose() {
    _giveUp?.cancel();
    super.dispose();
  }

  void _stop() {
    _giveUp?.cancel();
    _starting = false;
  }

  void onTap() {
    if (widget.starts && !_starting) {
      setState(() => _starting = true);
      // Nothing moved in 15 seconds: the line goes back to what it says (the snackbar has said why).
      _giveUp = Timer(const Duration(seconds: 15), () {
        if (mounted) setState(_stop);
      });
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final Widget mark = _starting
        ? SizedBox(key: const ValueKey('setup-starting'), width: 26, height: 26, child: Padding(padding: const EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2.5, color: k.accent)))
        : switch (line.phase) {
      SetupPhase.done => Container(
        key: const ValueKey('setup-tick'),
        width: 26,
        height: 26,
        decoration: BoxDecoration(color: k.ok, shape: BoxShape.circle),
        child: Icon(Icons.check, size: 18, color: k.background),
      ),
      SetupPhase.running => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.accent, width: 2)),
      ),
      SetupPhase.todo => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.secondary, width: 2)),
      ),
    };
    final running = line.phase == SetupPhase.running;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 12, 6),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                Text(_starting ? 'Starting…' : line.detail ?? reason, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                if (running) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    key: const ValueKey('setup-progress'),
                    value: line.fraction,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                    color: k.accent,
                    backgroundColor: k.background,
                  ),
                ],
              ],
            ),
          ),
          if (!line.done && !_starting) ...[
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: k.secondary),
          ],
        ],
      ),
    );
    final guide = onGuide;
    void hold() async {
      HapticFeedback.mediumImpact();
      final open = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!line.done)
                ListTile(leading: const Icon(Icons.play_arrow), title: Text(title), onTap: () => Navigator.pop(ctx, false)),
              ListTile(
                key: ValueKey('${widget.key is ValueKey<String> ? (widget.key as ValueKey<String>).value : title}-guide'),
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('How to, in the guide'),
                onTap: () => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (open == true) guide!();
      if (open == false) onTap();
    }

    return Semantics(
      button: true,
      customSemanticsActions: guide == null ? null : {CustomSemanticsAction(label: 'How to, in the guide'): guide},
      child: InkWell(
        onTap: _starting ? null : onTap,
        onLongPress: guide == null ? null : hold,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: body),
      ),
    );
  }
}
