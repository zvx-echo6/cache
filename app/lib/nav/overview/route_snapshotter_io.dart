import 'route_overview.dart';

/// The whole-route picture's maker on a phone or the desktop app: the app's native snapshotter.
RouteSnapshotter platformRouteSnapshotter() => const ChannelRouteSnapshotter();
