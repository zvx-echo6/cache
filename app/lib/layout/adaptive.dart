import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_fs.dart';
import '../desktop/desktop.dart';
import '../theme.dart';

/// One adaptive system, three width classes, measured on the window (not the device), so iPad Split View and Android multi-window
/// behave: under [kRegularWidth] the phone layout (bottom bar, one pane); from it on, a left rail and two panes where a list has a
/// detail; from [kDesktopMinWidth] the same frame with a wider list and a detail that fills the window (see [WidthClass.desktop]).
const double kRegularWidth = 640;

/// The window's width class (see [widthClassOf]).
enum WidthClass {
  /// Under [kRegularWidth]: the phone layout.
  compact,

  /// From [kRegularWidth]: the rail and two panes, the detail at most [kDetailMaxWidth] wide.
  regular,

  /// From [kDesktopMinWidth] (a computer's window, a 12.9" iPad Pro held sideways): the list [kDesktopListWidth] wide and the
  /// detail up to [kDesktopDetailMaxWidth], so a wide window has no empty bands; pages may lay out in a [TwoColumn], and reading
  /// text keeps to a [ReadingWidth]. Below it nothing changes.
  desktop,
}

/// From this window width the desktop class: two columns of about 380 need about 800 for the detail, and with the rail (80) and
/// a 380 list that is 1260.
const double kDesktopMinWidth = 1280;

/// The list pane on a desktop window (340 from [kWideWidth], 280 under it).
const double kDesktopListWidth = 380;

/// The detail pane on a desktop window at most (the page tint shows beyond it).
const double kDesktopDetailMaxWidth = 1400;

/// The width class of a window [width] wide.
WidthClass widthClassFor(double width) => width >= kDesktopMinWidth
    ? WidthClass.desktop
    : width >= kRegularWidth
    ? WidthClass.regular
    : WidthClass.compact;

/// The width class of the window [context] is in.
WidthClass widthClassOf(BuildContext context) => widthClassFor(MediaQuery.sizeOf(context).width);

/// The window is in the desktop class.
bool isDesktop(BuildContext context) => widthClassOf(context) == WidthClass.desktop;

/// From this width the list pane is wider ([kWideListWidth] instead of [kListWidth]).
const double kWideWidth = 900;

/// From this width a map's place and repeater cards sit as a left card instead of a bottom sheet (the rail and a card would
/// leave too little map on a 640 window).
const double kSideCardWidth = 800;

/// The map's left column from [kSideCardWidth] wide: the search bar and the card or the way to go under it.
const double kMapSideWidth = 380;

const double kRailWidth = 80;

/// The narrowest page that takes two panes (a 640 window less the rail: list 280, detail 280).
const double kTwoPaneMinWidth = 559;
const double kListWidth = 280;
const double kWideListWidth = 340;

/// The detail pane's reading width at most; the page tint shows either side.
const double kDetailMaxWidth = 640;

/// Under this window height a window is short (a phone held sideways, 390 high): however wide, its pages keep the phone layout
/// (one pane), since two panes would each show only a few rows. The app's frame keeps its rail there, which scrolls.
const double kShortHeight = 480;

/// The window is short (see [kShortHeight]).
bool isShort(BuildContext context) => MediaQuery.sizeOf(context).height < kShortHeight;

/// The window is wide enough for two panes, and tall enough for them to be worth it (not [isShort]).
bool isRegular(BuildContext context) {
  final s = MediaQuery.sizeOf(context);
  return s.width >= kRegularWidth && s.height >= kShortHeight;
}

/// The window is wide enough for the rail (on its side, see [isPortrait]); a short window has it too, scrolling.
bool hasRailWidth(BuildContext context) => MediaQuery.sizeOf(context).width >= kRegularWidth;

/// A two-pane list's width on a page [width] wide that is not a desktop window's: 40% of it, from [kListWidth] to
/// [kWideListWidth], so an upright tablet's list (328 on an 820 window) has room for its names on one line.
double listPaneWidth(double width) => (width * 0.4).clamp(kListWidth, kWideListWidth).toDouble();

/// A list with its detail beside it on a regular window: the list on the left (280, or 340 from 900, 380 on a desktop window), the
/// chosen item's page on the right (at most 640 wide, 1400 on a desktop window, centred), "Choose an item" while nothing is chosen
/// (or [desktopInitial]'s page on a desktop window). On a compact window it is just the list, and an item
/// opens as a page of its own. The list's rows open items with [openDetail] and mark the chosen one with [isPaneSelected]; a page
/// opened inside the detail stacks there (with its back arrow); the item's own page has none, the list stays.
class TwoPane extends StatefulWidget {
  const TwoPane({
    super.key,
    required this.list,
    this.initialKey,
    this.initial,
    this.desktopInitial,
    this.placeholder = 'Choose an item',
    this.id,
    this.listName = 'list',
    this.prefs,
    this.listAloneUntilChosen = false,
  });

  final Widget list;

  /// While nothing is chosen and there is no page to show beside the list, the list takes the whole page instead of sitting
  /// beside an empty "Choose an item" (Notebooks, Regions); choosing an item brings the detail in beside it.
  final bool listAloneUntilChosen;

  /// The item chosen at first on a regular window (Settings opens on its first page); null shows the placeholder.
  final Object? initialKey;
  final WidgetBuilder? initial;

  /// The page the detail shows on a desktop window while nothing is chosen, instead of the placeholder (Library opens on Add to
  /// Library); no row is marked for it. Narrower windows show the placeholder as before.
  final WidgetBuilder? desktopInitial;
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

  // The list keeps its state (tab, scroll) when it moves between the page alone and the list pane.
  final _listKey = GlobalKey(debugLabel: 'pane-list');

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

  /// Closes the detail page (back to the list's starting page) and shows the list again.
  void closeDetail() {
    setState(() {
      _key = null;
      _builder = null;
    });
    setListHidden(false);
  }

  // The width the pages have (the window less the rail when it shows): two panes when it fits, else the list alone.
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) => _panes(context, c.maxWidth));

  Widget _panes(BuildContext context, double width) {
    if (!isRegular(context) || width < kTwoPaneMinWidth) return widget.list;
    final k = context.t;
    final desktop = isDesktop(context);
    // Nothing chosen yet: the list stays (there would be nothing to show), and a desktop window may show the starting page.
    final hidden = _listHidden && _builder != null;
    final b = _builder ?? (desktop ? widget.desktopInitial : null);
    if (b == null && widget.listAloneUntilChosen) return _listScope(hidden: false);
    final Object? navKey = _builder == null ? const _DesktopInitial() : _key;
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
                  width: DesktopMetrics.of(context)?.listWidth ?? (desktop ? kDesktopListWidth : listPaneWidth(width)),
                  // A hidden list is out of reach: no taps, and a screen reader skips it. Shown, it is a semantics container of its
                  // own beside the detail's (below), so the detail page's route barrier, which blocks the semantics of whatever
                  // was painted before it in its container, cannot take the list out of the screen reader's reach.
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: ExcludeSemantics(
                      excluding: hidden,
                      child: IgnorePointer(ignoring: hidden, child: _listScope(hidden: hidden)),
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
                constraints: BoxConstraints(maxWidth: hidden ? double.infinity : (desktop ? kDesktopDetailMaxWidth : kDetailMaxWidth)),
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
                              key: ValueKey(navKey),
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

  Widget _listScope({required bool hidden}) => KeyedSubtree(
    key: _listKey,
    child: _PaneScope(state: this, inList: true, selected: _key, hidden: hidden, child: widget.list),
  );
}

/// The key of the detail's Navigator while it shows [TwoPane.desktopInitial].
class _DesktopInitial {
  const _DesktopInitial();
}

/// Two columns for a page in a desktop window's detail pane, opt in: [left] about 36% of the width (at least
/// [kTwoColumnLeftMinWidth]), [right] the rest, [gap] between. Where they do not fit (any window under [kDesktopMinWidth], or a
/// page narrower than [kTwoColumnMinWidth]) it shows [narrow], the page's one-column layout, so nothing changes there.
class TwoColumn extends StatelessWidget {
  const TwoColumn({super.key, required this.left, required this.right, required this.narrow, this.gap = kTwoColumnGap});

  final Widget left;
  final Widget right;
  final Widget narrow;
  final double gap;

  /// Whether two columns fit a page [width] wide in the window [context] is in.
  static bool fits(BuildContext context, double width) => isDesktop(context) && width >= kTwoColumnMinWidth;

  /// The left column's width on a page [width] wide.
  static double leftWidth(double width) => (width * kTwoColumnLeftFraction).clamp(kTwoColumnLeftMinWidth, double.infinity).toDouble();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      if (!fits(context, c.maxWidth)) return narrow;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(key: const ValueKey('two-column-left'), width: leftWidth(c.maxWidth), child: left),
          SizedBox(width: gap),
          Expanded(key: const ValueKey('two-column-right'), child: right),
        ],
      );
    },
  );
}

/// The share of the page [TwoColumn]'s left column takes.
const double kTwoColumnLeftFraction = 0.36;
const double kTwoColumnLeftMinWidth = 380;
const double kTwoColumnGap = 24;

/// The narrowest page that takes two columns: two of 380 and the gap.
const double kTwoColumnMinWidth = 2 * kTwoColumnLeftMinWidth + kTwoColumnGap;

/// Reading text (an article, search results with their snippets, a long answer) kept to about [chars] characters a line on any
/// window wider than that (a tablet held sideways, a desktop window); placed by [alignment] in the room it has. A phone is narrower,
/// so nothing changes there.
/// A character is the width of "0" in [style] (the surrounding text style when null), as CSS's `ch`.
class ReadingWidth extends StatelessWidget {
  const ReadingWidth({super.key, required this.child, this.chars = kReadingChars, this.style, this.alignment = Alignment.topCenter});

  final Widget child;
  final double chars;
  final TextStyle? style;
  final AlignmentGeometry alignment;

  /// The widest reading text may be. For a scrolling list, pad it with [padFor] so it scrolls from anywhere across the page.
  static double maxWidthOf(BuildContext context, {double chars = kReadingChars, TextStyle? style}) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final tp = TextPainter(
      text: TextSpan(text: '0', style: base),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final w = tp.width * chars;
    tp.dispose();
    return w;
  }

  /// Side padding that keeps a list's content to the reading width on a page [width] wide, at least [min] each side.
  static EdgeInsets padFor(BuildContext context, double width, {double min = 16, double chars = kReadingChars, TextStyle? style}) {
    final cap = maxWidthOf(context, chars: chars, style: style);
    final side = cap.isFinite ? ((width - cap) / 2).clamp(min, double.infinity).toDouble() : min;
    return EdgeInsets.symmetric(horizontal: side);
  }

  @override
  Widget build(BuildContext context) {
    final cap = maxWidthOf(context, chars: chars, style: style);
    if (!cap.isFinite) return child;
    return Align(
      alignment: alignment,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: cap), child: child),
    );
  }
}

/// Characters a line of reading text keeps to.
const double kReadingChars = 70;

/// The widest a page's rows, forms and cards are (Settings, Home, Weather, Models...): a wider window centres them, with the page's
/// background either side, so a label and its switch or chevron stay close. A phone is narrower.
const double kContentMaxWidth = 720;

/// A page's content kept to [maxWidth] (at most [kContentMaxWidth]) and placed by [alignment]; a narrower page is not touched.
/// For a scrolling list, pad it with [padFor] instead, so it scrolls from anywhere across the page.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = kContentMaxWidth, this.alignment = Alignment.topCenter});

  final Widget child;
  final double maxWidth;
  final AlignmentGeometry alignment;

  /// Side padding that keeps a list's content to [maxWidth] on a page [width] wide, at least [min] each side.
  static EdgeInsets padFor(double width, {double min = 16, double maxWidth = kContentMaxWidth}) =>
      EdgeInsets.symmetric(horizontal: ((width - maxWidth) / 2).clamp(min, double.infinity).toDouble());

  @override
  Widget build(BuildContext context) => Align(
    alignment: alignment,
    child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
  );
}

/// Side padding for a Settings page's rows on a page [width] wide: [ContentWidth.padFor] (centred, at most [kContentMaxWidth]),
/// except in Cache on Linux's desktop window, where the rows sit left-aligned under the title, at most
/// [DesktopMetrics.formMaxWidth] wide.
EdgeInsets settingsDetailPad(BuildContext context, double width, {double min = 16}) {
  final m = DesktopMetrics.of(context);
  if (m == null) return ContentWidth.padFor(width, min: min);
  return EdgeInsets.only(left: m.gutter, right: (width - m.gutter - DesktopMetrics.formMaxWidth).clamp(m.gutter, double.infinity).toDouble());
}

/// A bottom sheet that fits any window: as tall as its content, up to the window's height (less the status bar), and scrolling
/// when the content is taller (a phone held sideways), so no choice is ever off the screen. 560 wide at most, as every sheet.
Future<T?> showFittedSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool showDragHandle = false,
  Color? backgroundColor,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: showDragHandle,
  backgroundColor: backgroundColor,
  builder: (ctx) => SingleChildScrollView(child: builder(ctx)),
);

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

/// Closes the page in the detail pane and shows its list again; null outside a detail pane.
VoidCallback? paneClose(BuildContext context) {
  final pane = _PaneScope.of(context);
  return pane == null || pane.inList ? null : pane.state.closeDetail;
}

/// Which two-pane pages have their list hidden, kept on this device (a small file next to the settings).
class PanePrefs {
  PanePrefs({Directory? dirOverride}) : _dir = dirOverride;

  /// Tests: the folder every PanePrefs uses when none is given.
  static Directory? testDir;

  final Directory? _dir;

  AppFs get _fs => createAppFs(supportOverride: _dir ?? testDir);

  Future<Map<String, dynamic>> _read() async {
    try {
      final text = await _fs.readString(AppRoot.support, 'panes.json');
      if (text == null) return {};
      final j = jsonDecode(text);
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
      await _fs.writeString(AppRoot.support, 'panes.json', jsonEncode(m));
    } catch (_) {}
  }
}

/// The detail pane beside this list shows [TwoPane.desktopInitial]'s page (a desktop window, nothing chosen): the list leaves out
/// its own way to that page, so there are never two.
bool paneShowsDesktopInitial(BuildContext context) {
  final pane = _PaneScope.of(context);
  return pane != null && pane.inList && pane.state._builder == null && pane.state.widget.desktopInitial != null && isDesktop(context);
}

/// This widget is in the list of a [TwoPane] (not its detail).
bool inPaneList(BuildContext context) => _PaneScope.of(context)?.inList ?? false;

/// Item [key] is the one shown in the detail pane beside this list (its row is marked).
bool isPaneSelected(BuildContext context, Object key) {
  final pane = _PaneScope.of(context);
  return pane != null && pane.inList && pane.selected == key;
}

/// Whether the rail (a tablet held sideways) is hidden, kept on this device across restarts (a small file next to the settings).
class RailPrefs {
  RailPrefs({Directory? dirOverride}) : _dir = dirOverride;

  final Directory? _dir;

  AppFs get _fs => createAppFs(supportOverride: _dir);

  Future<bool> hidden() async {
    try {
      final text = await _fs.readString(AppRoot.support, 'rail.json');
      if (text == null) return false;
      final j = jsonDecode(text);
      return j is Map && j['hidden'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setHidden(bool hidden) async {
    try {
      await _fs.writeString(AppRoot.support, 'rail.json', jsonEncode({'hidden': hidden}));
    } catch (_) {}
  }
}

/// The window is taller than it is wide (a tablet held upright): the bottom bar, as on a phone, instead of the rail.
bool isPortrait(BuildContext context) {
  final s = MediaQuery.sizeOf(context);
  return s.height > s.width;
}
