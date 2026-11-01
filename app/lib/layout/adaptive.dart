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
  const TwoPane({
    super.key,
    required this.list,
    this.initialKey,
    this.initial,
    this.placeholder = 'Choose an item',
    this.id,
    this.listName = 'list',
    this.prefs,
  });

  final Widget list;

  /// The item chosen at first on a regular window (Settings opens on its first page); null shows the placeholder.
  final Object? initialKey;
  final WidgetBuilder? initial;
  final String placeholder;

  /// The page's name for remembering whether its list is hidden ("settings", "regions"...); null: it is not remembered.
  final String? id;

  /// What the list is called on its Show button: "Show Settings", "Show contents".
  final String listName;

  /// Where the hidden lists are kept (the app's support folder when null).
  final PanePrefs? prefs;

  @override
  State<TwoPane> createState() => TwoPaneState();
}

class TwoPaneState extends State<TwoPane> {
  late Object? _key = widget.initialKey;
  late WidgetBuilder? _builder = widget.initial;
  bool _listHidden = false;
  late final PanePrefs _prefs = widget.prefs ?? PanePrefs();

  @override
  void initState() {
    super.initState();
    final id = widget.id;
    if (id != null) {
      _prefs.hidden(id).then((h) {
        if (mounted && h != _listHidden) setState(() => _listHidden = h);
      });
    }
  }

  /// Shows [builder]'s page in the detail pane as item [key] (a new stack: the item's page is its first page).
  void open(Object key, WidgetBuilder builder) => setState(() {
    _key = key;
    _builder = builder;
  });

  /// Hides the list (the detail takes the whole width) or shows it again; kept for this page on this device.
  void setListHidden(bool hidden) {
    setState(() => _listHidden = hidden);
    final id = widget.id;
    if (id != null) _prefs.setHidden(id, hidden);
  }

  // The width the pages have (the window less the rail when it shows): two panes when it fits, else the list alone.
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) => _panes(context, c.maxWidth));

  Widget _panes(BuildContext context, double width) {
    if (MediaQuery.sizeOf(context).width < kRegularWidth || width < kTwoPaneMinWidth) return widget.list;
    final k = context.t;
    final b = _builder;
    // Nothing chosen yet: the list stays (there would be nothing to show).
    final hidden = _listHidden && b != null;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRect(
          child: AnimatedAlign(
            duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerRight,
            widthFactor: hidden ? 0 : 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: width >= kWideWidth ? kWideListWidth : kListWidth,
                  // A hidden list is out of reach: no taps, and a screen reader skips it. Shown, it is a semantics container of its
                  // own beside the detail's (below), so the detail page's route barrier, which blocks the semantics of whatever
                  // was painted before it in its container, cannot take the list out of the screen reader's reach.
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: ExcludeSemantics(
                      excluding: hidden,
                      child: IgnorePointer(ignoring: hidden, child: _PaneScope(state: this, inList: true, selected: _key, hidden: hidden, child: widget.list)),
                    ),
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: k.secondary.withValues(alpha: 0.2)),
              ],
            ),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: k.background,
            child: Center(
              child: ConstrainedBox(
                // With the list hidden the detail takes the whole width.
                constraints: BoxConstraints(maxWidth: hidden ? double.infinity : kDetailMaxWidth),
                // The detail's own Navigator: its page's barrier blocks semantics only inside this container (see the list's).
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: _PaneScope(
                    state: this,
                    inList: false,
                    selected: _key,
                    hidden: hidden,
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
        ),
      ],
    );
  }
}

class _PaneScope extends InheritedWidget {
  const _PaneScope({required this.state, required this.inList, required this.selected, required this.hidden, required super.child});

  final TwoPaneState state;
  final bool inList;
  final Object? selected;
  final bool hidden;

  static _PaneScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PaneScope>();

  @override
  bool updateShouldNotify(_PaneScope old) => selected != old.selected || inList != old.inList || hidden != old.hidden;
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

/// "Hide list", for the top bar of a two-pane page's list: slides the list away so the detail takes the whole width. Null on a
/// phone, outside a list pane, or while nothing is chosen (the list cannot be hidden then).
Widget? paneHideButton(BuildContext context) {
  final pane = _PaneScope.of(context);
  if (pane == null || !pane.inList || pane.selected == null || pane.state._builder == null) return null;
  return IconButton(
    key: const ValueKey('pane-hide'),
    tooltip: 'Hide list',
    icon: const Icon(Icons.keyboard_double_arrow_left),
    onPressed: () => pane.state.setListHidden(true),
  );
}

/// "Show [list]", for the detail page's own top bar, left of its title, while its list is hidden; null otherwise (and on a page
/// opened inside the detail, which has its back arrow there).
Widget? paneShowButton(BuildContext context) {
  final pane = _PaneScope.of(context);
  if (pane == null || pane.inList || !pane.hidden || (ModalRoute.of(context)?.canPop ?? false)) return null;
  return IconButton(
    key: const ValueKey('pane-show'),
    tooltip: 'Show ${pane.state.widget.listName}',
    icon: const Icon(Icons.keyboard_double_arrow_right),
    onPressed: () => pane.state.setListHidden(false),
  );
}

/// Which two-pane pages have their list hidden, kept on this device (a small file next to the settings).
class PanePrefs {
  PanePrefs({Directory? dirOverride}) : _dir = dirOverride;

  /// Tests: the folder every PanePrefs uses when none is given.
  static Directory? testDir;

  final Directory? _dir;

  Future<File> _file() async => File('${(_dir ?? testDir ?? await getApplicationSupportDirectory()).path}/panes.json');

  Future<Map<String, dynamic>> _read() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return {};
      final j = jsonDecode(f.readAsStringSync());
      return j is Map ? j.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  Future<bool> hidden(String id) async => (await _read())[id] == true;

  Future<void> setHidden(String id, bool hidden) async {
    try {
      final m = await _read();
      m[id] = hidden;
      (await _file()).writeAsStringSync(jsonEncode(m));
    } catch (_) {}
  }
}

/// Item [key] is the one shown in the detail pane beside this list (its row is marked).
bool isPaneSelected(BuildContext context, Object key) {
  final pane = _PaneScope.of(context);
  return pane != null && pane.inList && pane.selected == key;
}

/// Whether the rail (a tablet held sideways) is hidden, kept on this device across restarts (a small file next to the settings).
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

/// The window is taller than it is wide (a tablet held upright): the bottom bar, as on a phone, instead of the rail.
bool isPortrait(BuildContext context) {
  final s = MediaQuery.sizeOf(context);
  return s.height > s.width;
}
