import 'package:flutter/widgets.dart';

/// Cache has no pages that open by an address, so an address the platform sends to be pushed as a route (an intent's data that
/// reached the phone's activity, such as a navigation request's "geo:" address) is taken here and nothing is opened. Left to
/// the app's navigator it is an unknown route, and that threw (a null check in the framework's unknown-route handling).
///
/// Add it to the widgets binding before the app's first build: the binding asks its observers in the order they were added and
/// stops at the first that takes the route.
class IgnoreRoutePushes with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async => true;
}
