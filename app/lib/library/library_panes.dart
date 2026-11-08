import 'package:flutter/material.dart';

import '../layout/adaptive.dart';
import '../theme.dart';

/// One page of the Library's depth (Bookshelves, a class, a division, a book...): a key that names it and how to build it.
/// [leaf]: nothing opens from it, so on the widest windows it takes the list and the detail together.
@immutable
class LibraryPageSpec {
  const LibraryPageSpec(this.key, this.builder, {this.leaf = false});

  final String key;
  final WidgetBuilder builder;
  final bool leaf;
}

/// From this width of page (the window less the rail) the Library shows three panes: the sections (the Library's four rows), the
/// list, and the detail (UX-library-11b section 9: 1180 landscape, 1440 desktop). Under it, two: the current list and its detail.
const double kLibraryThreePaneWidth = 1000;

/// The Library's panes, with the breadcrumb as the only depth cue (UX-library-11b section 9). A phone shows one page at a time
/// (each level a page of its own, with the back arrow). From [kRegularWidth] it shows the last two levels side by side (the
/// current list 340 wide and its detail, "Choose an item" while nothing is chosen); from [kLibraryThreePaneWidth] the Library's
/// own rows stay at the left (230, or 270 on a desktop window), then the current list (330, or 400) and the detail. Panes never
/// stack deeper: deeper levels are reached through the breadcrumb. Every list pane has "Hide list"; hidden, the detail takes the
/// width and shows "Show list".
class LibraryPanes extends StatefulWidget {
  const LibraryPanes({super.key, required this.root, this.placeholder = 'Choose an item', this.desktopInitial, this.id = 'library', this.prefs});

  final WidgetBuilder root;
  final String placeholder;

  /// What the detail shows on a desktop window while nothing is chosen (Add to Library).
  final WidgetBuilder? desktopInitial;

  /// For remembering a hidden list on this device.
  final String id;
  final PanePrefs? prefs;

  @override
  State<LibraryPanes> createState() => LibraryPanesState();
}

class LibraryPanesState extends State<LibraryPanes> {
  /// The levels above the root, in order.
  final List<LibraryPageSpec> _stack = [];

  /// On a phone: the keys of the pages pushed, in order.
  final List<String> _pushed = [];
  bool _hidden = false;
  late final PanePrefs _prefs = widget.prefs ?? PanePrefs();

  @override
  void initState() {
    super.initState();
    _prefs.hidden(widget.id).then((h) {
      if (mounted && h != _hidden) setState(() => _hidden = h);
    });
  }

  /// The keys of the open levels (tests).
  List<String> get openKeys => [for (final s in _stack) s.key];

  bool _compact(BuildContext context) => !isRegular(context);

  /// Opens [spec] as the child of level [level] (0 the root): on a phone a page of its own, else in the panes.
  void open(BuildContext context, int level, LibraryPageSpec spec) {
    if (_compact(context)) {
      _push(context, level + 1, spec);
      return;
    }
    setState(() {
      if (_stack.length > level) _stack.removeRange(level, _stack.length);
      _stack.add(spec);
    });
  }

  void _push(BuildContext context, int level, LibraryPageSpec spec) {
    final route = MaterialPageRoute<void>(
      settings: RouteSettings(name: 'library:${spec.key}'),
      builder: (ctx) => _LevelScope(state: this, level: level, spec: spec, compact: true, child: Builder(builder: spec.builder)),
    );
    _pushed.add(spec.key);
    route.popped.then((_) {
      final i = _pushed.lastIndexOf(spec.key);
      if (i >= 0) _pushed.removeRange(i, _pushed.length);
    });
    Navigator.of(context).push(route);
  }

  /// Goes to the level [path] names (the levels above the root; empty: the root): the breadcrumb's tap. Levels already open are
  /// kept; the rest are opened.
  void goTo(BuildContext context, List<LibraryPageSpec> path) {
    if (_compact(context)) {
      var same = 0;
      while (same < path.length && same < _pushed.length && _pushed[same] == path[same].key) {
        same++;
      }
      final nav = Navigator.of(context);
      if (same < _pushed.length) {
        final keep = same == 0 ? null : 'library:${_pushed[same - 1]}';
        nav.popUntil((r) => keep == null ? r.isFirst : r.settings.name == keep || r.isFirst);
        _pushed.removeRange(same, _pushed.length);
      }
      for (var i = same; i < path.length; i++) {
        _push(context, i + 1, path[i]);
      }
      return;
    }
    setState(() {
      _stack
        ..clear()
        ..addAll(path);
    });
  }

  /// Closes level [level] and everything above it (the back arrow of a page whose parent is not showing).
  void closeFrom(BuildContext context, int level) {
    if (_compact(context)) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      if (_stack.length >= level) _stack.removeRange(level - 1, _stack.length);
    });
  }

  void setHidden(bool hidden) {
    setState(() => _hidden = hidden);
    _prefs.setHidden(widget.id, hidden);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      if (!isRegular(context) || c.maxWidth < kTwoPaneMinWidth) {
        return _LevelScope(state: this, level: 0, spec: null, compact: true, child: Builder(builder: widget.root));
      }
      return _panes(context, c.maxWidth, c.maxHeight);
    },
  );

  Widget _panes(BuildContext context, double width, double height) {
    final k = context.t;
    final desktop = isDesktop(context);
    final three = width >= kLibraryThreePaneWidth;
    final pages = <LibraryPageSpec?>[null, ..._stack]; // null: the root
    final n = pages.length;
    // the levels that show, left to right (-1: the placeholder)
    final List<int> shown;
    if (three) {
      if (n == 1) {
        shown = [0, -1];
      } else if (n == 2) {
        shown = _stack.last.leaf ? [0, 1] : [0, 1, -1];
      } else {
        shown = [0, n - 2, n - 1];
      }
    } else {
      shown = n == 1 ? [0, -1] : [n - 2, n - 1];
    }
    final hidden = _hidden && n > 1;
    // hidden: only the page the person is on (never the placeholder)
    final visible = hidden ? [shown.last < 0 ? shown[shown.length - 2] : shown.last] : shown;
    final sections = desktop ? 270.0 : 230.0;
    final list = desktop ? 400.0 : 330.0;
    final widths = <double>[];
    if (visible.length == 1) {
      widths.add(width);
    } else if (visible.length == 2) {
      final first = three ? sections : (width >= 760 ? 340.0 : 300.0);
      widths.addAll([first, width - first - 1]);
    } else {
      widths.addAll([sections, list, width - sections - list - 2]);
    }
    final children = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      final level = visible[i];
      if (i > 0) children.add(VerticalDivider(width: 1, thickness: 1, color: k.secondary.withValues(alpha: 0.2)));
      final last = i == visible.length - 1;
      final Widget page;
      if (level < 0) {
        final initial = desktop && n == 1 ? widget.desktopInitial : null;
        page = initial != null
            ? _LevelScope(state: this, level: 1, spec: null, compact: false, child: _paneNavigator('initial', Builder(builder: initial)))
            : Scaffold(key: const ValueKey('pane-placeholder'), body: Center(child: Text(widget.placeholder, style: TextStyle(fontSize: 15, color: k.secondary))));
      } else {
        final spec = pages[level];
        final parentShows = level == 0 || visible.contains(level - 1);
        // The scope sits above the pane's Navigator, so the page sees where it stands now (its route is built once).
        page = _LevelScope(
          state: this,
          level: level,
          spec: spec,
          compact: false,
          showsParent: parentShows,
          last: last,
          canHide: i == visible.length - 2 && n > 1,
          child: _paneNavigator(spec?.key ?? 'root', Builder(builder: spec?.builder ?? widget.root)),
        );
      }
      children.add(
        KeyedSubtree(
          key: ValueKey('library-pane:${level < 0 ? 'placeholder' : (pages[level]?.key ?? 'root')}'),
          child: SizedBox(width: widths[i], height: height, child: ColoredBox(color: k.background, child: page)),
        ),
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  /// A pane's own Navigator, so what a page pushes (Credits from Credits and licences, a reader's next page) stays in its pane.
  Widget _paneNavigator(String key, Widget page) => HeroControllerScope.none(
    child: Navigator(key: ValueKey('library-nav:$key'), onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => page)),
  );
}

class _LevelScope extends InheritedWidget {
  const _LevelScope({
    required this.state,
    required this.level,
    required this.spec,
    required this.compact,
    required super.child,
    this.showsParent = true,
    this.last = true,
    this.canHide = false,
  });

  final LibraryPanesState state;
  final int level;
  final LibraryPageSpec? spec;
  final bool compact;

  /// The level under this one shows beside it (no back arrow needed).
  final bool showsParent;

  /// The rightmost pane (the detail).
  final bool last;

  /// A list pane with a page beside it: it offers "Hide list".
  final bool canHide;

  static _LevelScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_LevelScope>();

  @override
  bool updateShouldNotify(_LevelScope old) =>
      true; // the panes' stack (what is open beside a page) lives in the state, so every change tells the pages
}

/// How a Library page opens its children and climbs back. Every Library page reads it with [LibraryNav.of].
class LibraryNav {
  LibraryNav._(this._scope);

  final _LevelScope? _scope;

  static LibraryNav of(BuildContext context) => LibraryNav._(_LevelScope.of(context));

  /// The page's level (0: the Library's root).
  int get level => _scope?.level ?? 0;

  /// One page at a time (a phone), not the panes.
  bool get compact => _scope?.compact ?? true;

  /// Opens [spec] as this page's child.
  void open(BuildContext context, LibraryPageSpec spec) {
    final s = _scope;
    if (s == null) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: spec.builder));
      return;
    }
    s.state.open(context, s.level, spec);
  }

  /// Opens [spec] in this page's place (Move from a book page: the place page instead of the book).
  void replace(BuildContext context, LibraryPageSpec spec) {
    final s = _scope;
    if (s == null || s.compact || s.level == 0) {
      open(context, spec);
      return;
    }
    s.state.open(context, s.level - 1, spec);
  }

  /// Goes to the level [path] names (the breadcrumb).
  void goTo(BuildContext context, List<LibraryPageSpec> path) => _scope?.state.goTo(context, path);

  /// Something is open beside the Library's own rows (false on a phone, and while the detail shows its starting page).
  bool get isAnythingOpen {
    final s = _scope;
    return s != null && !s.compact && s.state._stack.isNotEmpty;
  }

  /// [key] is this page's child showing beside it (its row is marked).
  bool isOpen(Object key) {
    final s = _scope;
    if (s == null || s.compact) return false;
    final stack = s.state._stack;
    return stack.length > s.level && stack[s.level].key == key;
  }

  /// The top bar's leading: on a phone the usual back arrow (null: the route's own); in the panes a back arrow when the level under
  /// this one does not show, "Show list" when the list is hidden.
  Widget? leading(BuildContext context) {
    final s = _scope;
    if (s == null || s.compact) return null;
    if (s.last && s.state._hidden && s.state._stack.isNotEmpty) {
      return IconButton(
        key: const ValueKey('library-show-list'),
        tooltip: 'Show list',
        icon: const Icon(Icons.keyboard_double_arrow_right),
        onPressed: () => s.state.setHidden(false),
      );
    }
    if (!s.showsParent && s.level > 0) {
      return IconButton(
        key: const ValueKey('library-back'),
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => s.state.closeFrom(context, s.level),
      );
    }
    return null;
  }

  /// Whether the top bar should leave out the back arrow a route would add (the panes have none).
  bool get impliesBack => compact;

  /// "Hide list" for a list pane with a page beside it; null otherwise.
  Widget? hideButton(BuildContext context) {
    final s = _scope;
    if (s == null || s.compact || !s.canHide) return null;
    return IconButton(
      key: const ValueKey('library-hide-list'),
      tooltip: 'Hide list',
      icon: const Icon(Icons.keyboard_double_arrow_left),
      onPressed: () => s.state.setHidden(true),
    );
  }
}

/// A top bar for a Library page: the title (with an optional mono number above it, "CDS 200"), the panes' leading and Hide list.
PreferredSizeWidget libraryAppBar(BuildContext context, {required String title, String? number, Color? numberColor, List<Widget> actions = const [], Widget? titleWidget}) {
  final nav = LibraryNav.of(context);
  final k = context.t;
  return AppBar(
    automaticallyImplyLeading: nav.impliesBack,
    leading: nav.leading(context),
    toolbarHeight: number == null ? kToolbarHeight : 64,
    title: titleWidget ?? (number == null
        ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(number, style: TextStyle(fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w700, color: numberColor ?? k.accent)),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          )),
    actions: [...actions, ?nav.hideButton(context)],
  );
}

/// One part of a breadcrumb: its words and the level it climbs to (null: not tappable, the page itself).
class Crumb {
  const Crumb(this.label, [this.path]);

  final String label;

  /// The levels above the root it goes to; empty: the root.
  final List<LibraryPageSpec>? path;
}

/// The breadcrumb: "Library › Bookshelves › CDS 200 · Medicine and Health", each part but the last tappable, then [trail]
/// ("· 46 books"). It is the depth cue on every level.
class LibraryCrumbs extends StatelessWidget {
  const LibraryCrumbs({super.key, required this.crumbs, this.trail});

  final List<Crumb> crumbs;
  final String? trail;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final nav = LibraryNav.of(context);
    final parts = <Widget>[];
    for (var i = 0; i < crumbs.length; i++) {
      final c = crumbs[i];
      if (i > 0) parts.add(Text(' › ', style: TextStyle(fontSize: 13, color: k.secondary)));
      final path = c.path;
      final text = Text(c.label, style: TextStyle(fontSize: 13, color: path == null ? k.secondary : k.accent, fontWeight: path == null ? FontWeight.w400 : FontWeight.w500));
      parts.add(
        path == null
            ? text
            : Semantics(
                button: true,
                child: InkWell(
                  key: ValueKey('crumb-${c.label}'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => nav.goTo(context, path),
                  child: Padding(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2), child: text),
                ),
              ),
      );
    }
    if (trail != null) parts.add(Text(' · $trail', style: TextStyle(fontSize: 13, color: k.secondary)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: parts),
    );
  }
}
