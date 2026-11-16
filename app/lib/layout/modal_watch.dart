import 'package:flutter/widgets.dart';

/// Which sheets, dialogs and pop-up menus are open over the app, in any of its Navigators.
///
/// In a browser the reader shows a ZIM page in an iframe, and an iframe takes every pointer event that lands in its area: a sheet,
/// dialog or menu drawn over it gets no clicks and cannot be closed. The reader listens here and tells its frame to let pointer
/// events through while anything is open (and takes them back after). Only [PopupRoute]s count: sheets, dialogs and menus. A page
/// is not one.
class ModalWatch extends ChangeNotifier {
  final Set<Route<dynamic>> _open = {};

  /// True while any sheet, dialog or menu is open.
  bool get isOpen => _open.isNotEmpty;

  void pushed(Route<dynamic> route) {
    if (route is PopupRoute && _open.add(route)) notifyListeners();
  }

  void gone(Route<dynamic> route) {
    if (_open.remove(route)) notifyListeners();
  }

  /// Tests: nothing is open.
  void reset() {
    _open.clear();
  }

  /// A Navigator left with [routes] still open (it was taken out of the tree).
  void goneAll(Iterable<Route<dynamic>> routes) {
    final before = _open.length;
    _open.removeAll(routes);
    if (_open.length != before) notifyListeners();
  }
}

/// The app's watch.
final ModalWatch modalWatch = ModalWatch();

/// The app's root Navigator's observer (it is never taken out of the tree).
final ModalWatchObserver rootModalObserver = ModalWatchObserver();

/// Reports one Navigator's sheets, dialogs and menus to [watch]. A NavigatorObserver belongs to one Navigator.
class ModalWatchObserver extends NavigatorObserver {
  ModalWatchObserver([ModalWatch? watch]) : watch = watch ?? modalWatch;

  final ModalWatch watch;
  final Set<Route<dynamic>> _mine = {};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _mine.add(route);
    watch.pushed(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _mine.remove(route);
    watch.gone(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _mine.remove(route);
    watch.gone(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      _mine.remove(oldRoute);
      watch.gone(oldRoute);
    }
    if (newRoute != null) {
      if (newRoute is PopupRoute) _mine.add(newRoute);
      watch.pushed(newRoute);
    }
  }

  /// The Navigator is gone: whatever it had open is not open any more.
  void release() {
    watch.goneAll(_mine);
    _mine.clear();
  }
}

/// A Navigator that reports its sheets, dialogs and menus to [modalWatch] (a pane's own Navigator).
class ModalWatchedNavigator extends StatefulWidget {
  const ModalWatchedNavigator({super.key, required this.onGenerateRoute});

  final RouteFactory onGenerateRoute;

  @override
  State<ModalWatchedNavigator> createState() => _ModalWatchedNavigatorState();
}

class _ModalWatchedNavigatorState extends State<ModalWatchedNavigator> {
  final ModalWatchObserver _observer = ModalWatchObserver();

  @override
  void dispose() {
    _observer.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Navigator(observers: [_observer], onGenerateRoute: widget.onGenerateRoute);
}
