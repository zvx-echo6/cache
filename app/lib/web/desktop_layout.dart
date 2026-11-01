// Temporary: replaced by app/lib/layout/adaptive.dart in 1.0.30
//
// A private copy of the desktop width class the app team ships in 1.0.30, with the same working names and values, for the browser
// screens only (the Library on a device). When adaptive.dart has them this file goes and its users import adaptive.dart instead.
import 'package:flutter/material.dart';

import '../layout/adaptive.dart' show kRailWidth;
import '../theme.dart';

/// A window this wide (or wider) gets the desktop layout: the rail, a list pane of [kDesktopListWidth] and a detail pane of up to
/// [kDesktopDetailMaxWidth], itself in two columns.
const double kDesktopMinWidth = 1280;
const double kDesktopListWidth = 380;
const double kDesktopDetailMaxWidth = 1400;

/// The detail's own two columns need this much width; narrower, they stack.
const double kTwoColumnMinWidth = 880;

/// A line of reading text at most this many characters wide (about 70ch at the app's 15 px).
const int kReadingChars = 70;
const double kReadingMaxWidth = kReadingChars * 8.6;

enum WidthClass {
  /// Under 640: the phone layout.
  compact,

  /// 640 up to [kDesktopMinWidth]: the rail and two panes (today's tablet layout).
  regular,

  /// [kDesktopMinWidth] and up.
  desktop;

  static WidthClass of(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= kDesktopMinWidth) return WidthClass.desktop;
    if (w >= 640) return WidthClass.regular;
    return WidthClass.compact;
  }
}

/// A detail page in two columns: [left] about 36% (at least 380) and [right] the rest. Under [kTwoColumnMinWidth] they stack, the
/// left one first.
class TwoColumn extends StatelessWidget {
  const TwoColumn({super.key, required this.left, required this.right, this.gap = 28, this.padding = const EdgeInsets.fromLTRB(24, 8, 24, 24)});

  final Widget left;
  final Widget right;
  final double gap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < kTwoColumnMinWidth) {
            return ListView(
              padding: padding,
              children: [left, SizedBox(height: gap), right],
            );
          }
          final inner = c.maxWidth - padding.horizontal - gap;
          final leftWidth = (inner * 0.36).clamp(380.0, inner - 380.0);
          return Padding(
            padding: padding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: leftWidth, child: SingleChildScrollView(child: left)),
                SizedBox(width: gap),
                Expanded(child: SingleChildScrollView(child: right)),
              ],
            ),
          );
        },
      );
}

/// Reading text no wider than [kReadingChars] characters, at the left of the space it has.
class ReadingWidth extends StatelessWidget {
  const ReadingWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: kReadingMaxWidth), child: child),
      );
}

/// The Library at the desktop width: the list on the left (380), the chosen item's page on the right (up to 1400, centred). A page
/// opened in the detail stacks there with its own back arrow; a page opened [fullWindow] hides the list (the rail stays), and
/// closing it brings the list and the page that was there back.
class DesktopFrame extends StatefulWidget {
  const DesktopFrame({super.key, required this.list, required this.initial});

  final Widget list;

  /// The page shown while nothing is chosen (Add to Library).
  final WidgetBuilder initial;

  @override
  State<DesktopFrame> createState() => DesktopFrameState();
}

class DesktopFrameState extends State<DesktopFrame> {
  Object? _key;
  WidgetBuilder? _builder;
  bool _full = false;
  int _gen = 0;
  Object? _backKey;
  WidgetBuilder? _backBuilder;
  late final _FullWindowWatcher _watcher = _FullWindowWatcher(_closeFull);

  /// The key of the page in the detail pane (its row is marked in the list).
  Object? get selected => _key;
  bool get fullWindow => _full;

  /// Shows [builder]'s page in the detail pane as item [key]. [fullWindow] hides the list while it is open.
  void open(Object key, WidgetBuilder builder, {bool fullWindow = false}) {
    setState(() {
      if (fullWindow && !_full) {
        _backKey = _key;
        _backBuilder = _builder;
      }
      _key = key;
      _builder = builder;
      _full = fullWindow;
      _gen++;
    });
  }

  void _closeFull() {
    if (!mounted || !_full) return;
    setState(() {
      _gen++;
      _full = false;
      _key = _backKey;
      _builder = _backBuilder;
      _backKey = null;
      _backBuilder = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final b = _builder ?? widget.initial;
    final key = _key ?? 'initial';
    final hidden = _full;
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
                  width: kDesktopListWidth,
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: ExcludeSemantics(
                      excluding: hidden,
                      child: IgnorePointer(ignoring: hidden, child: _Scope(state: this, inList: true, selected: _key, child: widget.list)),
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
                constraints: BoxConstraints(maxWidth: hidden ? double.infinity : kDesktopDetailMaxWidth),
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: _Scope(
                    state: this,
                    inList: false,
                    selected: _key,
                    child: HeroControllerScope.none(
                      child: Navigator(
                        key: ValueKey('$key/$hidden/$_gen'),
                        observers: [if (hidden) _watcher],
                        onGenerateInitialRoutes: (nav, name) => [
                          // A full-window page sits on an empty page, so it has a back arrow that leads out of the full window.
                          if (hidden) MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
                          MaterialPageRoute<void>(builder: b),
                        ],
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

/// Tells the frame when the full-window page was closed (its back arrow popped it onto the empty page under it).
class _FullWindowWatcher extends NavigatorObserver {
  _FullWindowWatcher(this.onClosed);

  final VoidCallback onClosed;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null && previousRoute.isFirst) WidgetsBinding.instance.addPostFrameCallback((_) => onClosed());
  }
}

class _Scope extends InheritedWidget {
  const _Scope({required this.state, required this.inList, required this.selected, required super.child});

  final DesktopFrameState state;
  final bool inList;
  final Object? selected;

  static _Scope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Scope>();

  @override
  bool updateShouldNotify(_Scope old) => selected != old.selected || inList != old.inList;
}

/// The desktop frame this widget is in, or null (a phone, a tablet, a test).
DesktopFrameState? desktopFrameOf(BuildContext context) => _Scope.of(context)?.state;

/// Opens [builder] as item [key] in the desktop frame's detail pane. False when there is no desktop frame (the caller opens it the
/// way it always did).
bool openInDesktopPane(BuildContext context, {required Object key, required WidgetBuilder builder, bool fullWindow = false}) {
  final f = desktopFrameOf(context);
  if (f == null) return false;
  f.open(key, builder, fullWindow: fullWindow);
  return true;
}

/// This context is a page in the desktop frame's detail pane (not its list): a page it opens is pushed there, with a back arrow.
bool isInDesktopDetail(BuildContext context) {
  final s = _Scope.of(context);
  return s != null && !s.inList;
}

/// Item [key] is the one in the desktop frame's detail pane (its row in the list is marked).
bool isDesktopSelected(BuildContext context, Object key) {
  final s = _Scope.of(context);
  return s != null && s.inList && s.selected == key;
}

/// "Add to Library" in the desktop frame's detail pane right now.
bool isDesktopInitial(BuildContext context) {
  final s = _Scope.of(context);
  return s != null && s.inList && s.selected == null;
}

/// The rail's width, for pages that lay themselves out against the window.
const double kDesktopRailWidth = kRailWidth;
