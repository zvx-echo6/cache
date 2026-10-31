import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../theme.dart';

/// One adaptive system, two width classes, measured on the window (not the device), so iPad Split View and Android multi-window
/// behave: under [kRegularWidth] the phone layout (bottom bar, one pane); from it on, a left rail and two panes where a list has a
/// detail. One threshold, so there is no middle layout.
const double kRegularWidth = 640;

/// From this width the list pane is wider ([kWideListWidth] instead of [kListWidth]).
const double kWideWidth = 900;

/// From this width a map's place and repeater cards sit as a left card instead of a bottom sheet (the rail and a card would
/// leave too little map on a 640 window).
const double kSideCardWidth = 800;

const double kRailWidth = 80;

/// The narrowest page that takes two panes (a 640 window less the rail: list 280, detail 280).
const double kTwoPaneMinWidth = 559;
const double kListWidth = 280;
const double kWideListWidth = 340;

/// The detail pane's reading width at most; the page tint shows either side.
const double kDetailMaxWidth = 640;

/// The window is wide enough for the rail and two panes.
bool isRegular(BuildContext context) => MediaQuery.sizeOf(context).width >= kRegularWidth;

/// A list with its detail beside it on a regular window: the list on the left (280, or 340 from 900), the chosen item's page on the
/// right (at most 640 wide, centred), "Choose an item" while nothing is chosen. On a compact window it is just the list, and an item
/// opens as a page of its own. The list's rows open items with [openDetail] and mark the chosen one with [isPaneSelected]; a page
/// opened inside the detail stacks there (with its back arrow); the item's own page has none, the list stays.
class TwoPane extends StatefulWidget {
  const TwoPane({super.key, required this.list, this.initialKey, this.initial, this.placeholder = 'Choose an item'});

  final Widget list;

  /// The item chosen at first on a regular window (Settings opens on its first page); null shows the placeholder.
  final Object? initialKey;
  final WidgetBuilder? initial;
  final String placeholder;

  @override
  State<TwoPane> createState() => TwoPaneState();
}

class TwoPaneState extends State<TwoPane> {
  late Object? _key = widget.initialKey;
  late WidgetBuilder? _builder = widget.initial;

  /// Shows [builder]'s page in the detail pane as item [key] (a new stack: the item's page is its first page).
  void open(Object key, WidgetBuilder builder) => setState(() {
    _key = key;
    _builder = builder;
  });

  // The width the pages have (the window less the rail when it shows): two panes when it fits, else the list alone.
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) => _panes(context, c.maxWidth));

  Widget _panes(BuildContext context, double width) {
    if (MediaQuery.sizeOf(context).width < kRegularWidth || width < kTwoPaneMinWidth) return widget.list;
    final k = context.t;
    final b = _builder;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: width >= kWideWidth ? kWideListWidth : kListWidth,
          child: _PaneScope(state: this, inList: true, selected: _key, child: widget.list),
        ),
        VerticalDivider(width: 1, thickness: 1, color: k.secondary.withValues(alpha: 0.2)),
        Expanded(
          child: ColoredBox(
            color: k.background,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kDetailMaxWidth),
                child: _PaneScope(
                  state: this,
                  inList: false,
                  selected: _key,
                  child: b == null
                      ? Scaffold(
                          key: const ValueKey('pane-placeholder'),
                          body: Center(child: Text(widget.placeholder, style: TextStyle(fontSize: 15, color: k.secondary))),
                        )
                      : HeroControllerScope.none(
                          child: Navigator(
                            key: ValueKey(_key),
                            onGenerateRoute: (_) => MaterialPageRoute<void>(builder: b),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaneScope extends InheritedWidget {
  const _PaneScope({required this.state, required this.inList, required this.selected, required super.child});

  final TwoPaneState state;
  final bool inList;
  final Object? selected;

  static _PaneScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PaneScope>();

  @override
  bool updateShouldNotify(_PaneScope old) => selected != old.selected || inList != old.inList;
}

/// Opens item [key]: in the detail pane when called from a [TwoPane]'s list on a regular window, else as a page of its own.
Future<void> openDetail(BuildContext context, {required Object key, required WidgetBuilder builder}) async {
  final pane = _PaneScope.of(context);
  if (pane != null && pane.inList) {
    pane.state.open(key, builder);
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
}

/// Item [key] is the one shown in the detail pane beside this list (its row is marked).
bool isPaneSelected(BuildContext context, Object key) {
  final pane = _PaneScope.of(context);
  return pane != null && pane.inList && pane.selected == key;
}

/// Whether the rail is hidden in portrait, kept on this device across restarts (a small file next to the settings).
class RailPrefs {
  RailPrefs({Directory? dirOverride}) : _dir = dirOverride;

  final Directory? _dir;

  Future<File> _file() async => File('${(_dir ?? await getApplicationSupportDirectory()).path}/rail.json');

  Future<bool> hidden() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return false;
      final j = jsonDecode(f.readAsStringSync());
      return j is Map && j['hidden'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setHidden(bool hidden) async {
    try {
      (await _file()).writeAsStringSync(jsonEncode({'hidden': hidden}));
    } catch (_) {}
  }
}

/// The window is taller than it is wide (a tablet held upright): the rail can be hidden to give the page the full width.
bool isPortrait(BuildContext context) {
  final s = MediaQuery.sizeOf(context);
  return s.height > s.width;
}
