import 'package:flutter/material.dart';

import '../app_state.dart';
import '../browse/browse_state.dart';
import '../browse/catalogue_screen.dart' show CatalogueScreen;
import '../layout/layout_state.dart';
import '../maps/ui/format.dart';
import '../models/model_downloads.dart';
import '../regions/regions_state.dart';
import '../sources/sources_state.dart';
import '../theme.dart';
import '../weather/weather_state.dart';
import 'libraries_screen.dart';

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
    required this.layout,
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
  });

  /// Remembers whether the person hid the card.
  final LayoutState layout;
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

  /// A region with its road routing on the phone is done; one with road routing on its way runs.
  SetupLine get areaLine {
    final withRouting = [for (final l in regions?.local ?? const <LocalRegion>[]) if (l.hasRouting) l];
    final ready = withRouting.where((l) => l.phase == RegionPhase.ready).firstOrNull;
    if (ready != null) {
      final parts = [if (ready.hasMap) 'map', 'directions', if (ready.hasPlaces) 'places'];
      final words = parts.length == 1 ? parts.single : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
      return SetupLine(SetupPhase.done, detail: '${ready.name} · $words · ${formatBytes(ready.bytes)}');
    }
    final going = withRouting.firstOrNull;
    if (going == null) return const SetupLine(SetupPhase.todo);
    return switch (going.phase) {
      RegionPhase.paused => SetupLine(SetupPhase.running, detail: '${going.name} · ${regions!.paused ?? 'paused'}', fraction: going.fraction),
      RegionPhase.failed => SetupLine(SetupPhase.todo, detail: '${going.name} · ${going.error ?? 'could not be downloaded'}'),
      _ => SetupLine(SetupPhase.running, detail: '${going.name} · downloading${_percent(going.fraction)}', fraction: going.fraction),
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

/// "Add to Library": the Kiwix catalogue (Wikipedia, WikiMed and more) or your own library from a file or a download link.
Future<void> showAddToLibrary(BuildContext context, BrowseState browse) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (ctx) {
    final k = ctx.t;
    final libraries = browse.libraries;
    void open(Widget page) {
      Navigator.pop(ctx);
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Add to Library', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text)),
          ),
          ListTile(
            key: const ValueKey('add-from-kiwix'),
            minTileHeight: 64,
            leading: Icon(Icons.menu_book_outlined, color: k.text),
            title: const Text('From the Kiwix catalogue', style: TextStyle(fontSize: 17)),
            subtitle: const Text('Wikipedia, WikiMed and more'),
            onTap: () => open(CatalogueScreen(browse: browse)),
          ),
          if (libraries != null)
            ListTile(
              key: const ValueKey('add-own-library'),
              minTileHeight: 64,
              leading: Icon(Icons.library_books_outlined, color: k.text),
              title: const Text('Your own library', style: TextStyle(fontSize: 17)),
              subtitle: const Text('From a file or a download link'),
              onTap: () => open(LibrariesScreen(libraries: libraries)),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  },
);

/// The "Set up Cache" card at the top of Home: four lines, each with its button and a tick when done. It goes away when all four
/// are done, or when the person hides it (Settings > Set up Cache brings it back). With [onHide] null (the Settings page) it has no
/// close button and stays while everything is done.
class SetupCard extends StatelessWidget {
  const SetupCard({super.key, required this.setup, this.onHide});

  final SetupCache setup;
  final VoidCallback? onHide;

  static const _titles = ['Choose a model', 'Get your area', 'Turn on weather', 'Add a library'];
  static const _reasons = ['Needed to answer questions', 'Map, directions and places', 'Forecast and alerts', 'Wikipedia, WikiMed or your own'];
  static const _keys = ['setup-model', 'setup-area', 'setup-weather', 'setup-library'];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: setup.changes,
    builder: (context, _) => FutureBuilder<SetupStatus>(
      future: setup.read(),
      builder: (context, snap) {
        final s = snap.data;
        if (s == null || (onHide != null && s.allDone)) return const SizedBox.shrink();
        // On Home it keeps the gap the blocks under it keep between them.
        return onHide == null ? _card(context, s) : Padding(padding: const EdgeInsets.only(bottom: 16), child: _card(context, s));
      },
    ),
  );

  Widget _card(BuildContext context, SetupStatus s) {
    final k = context.t;
    final actions = [setup.chooseModel, setup.getArea, setup.turnOnWeather, setup.addLibrary];
    return Container(
      key: const ValueKey('setup-card'),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Set up Cache', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: k.text))),
              Text('${s.doneCount} of ${s.lines.length} done', key: const ValueKey('setup-count'), style: TextStyle(fontSize: 14, color: k.secondary)),
              if (onHide != null)
                IconButton(key: const ValueKey('setup-hide'), tooltip: 'Hide setup', icon: Icon(Icons.close, color: k.secondary), onPressed: onHide)
              else
                const SizedBox(width: 12),
            ],
          ),
          for (var i = 0; i < 4; i++)
            _SetupRow(
              key: ValueKey(_keys[i]),
              title: _titles[i],
              reason: _reasons[i],
              line: s.lines[i],
              onTap: () => actions[i](context),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
            child: Text(
              'Each step works right here. Big downloads keep going while you use the app.',
              style: TextStyle(fontSize: 14, color: k.secondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({super.key, required this.title, required this.reason, required this.line, required this.onTap});

  final String title;
  final String reason;
  final SetupLine line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final Widget mark = switch (line.phase) {
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
      padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: k.text)),
                const SizedBox(height: 2),
                Text(line.detail ?? reason, style: TextStyle(fontSize: 14, color: k.secondary)),
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
          if (!line.done) ...[
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: k.secondary),
          ],
        ],
      ),
    );
    if (line.done) return ConstrainedBox(constraints: const BoxConstraints(minHeight: 64), child: body);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 64), child: body),
      ),
    );
  }
}

/// Hides the card on Home and says once where it is found again.
void hideSetup(BuildContext context, SetupCache setup) {
  setup.layout.setSetupHidden(true);
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(const SnackBar(content: Text('You can find this again in Settings > Set up Cache.')));
}

/// Settings > Set up Cache: shows the card on Home again, and opens a page with the same card and its states.
void openSetup(BuildContext context, SetupCache setup) {
  setup.layout.setSetupHidden(false);
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SetupPage(setup: setup)));
}

/// The page Settings > Set up Cache opens.
class SetupPage extends StatelessWidget {
  const SetupPage({super.key, required this.setup});

  final SetupCache setup;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Set up Cache')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [SetupCard(setup: setup)],
    ),
  );
}
