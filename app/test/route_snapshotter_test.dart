import 'package:cache/nav/overview/route_overview.dart';
import 'package:cache/nav/overview/route_snapshotter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('off the web the whole-route picture is the native snapshotter\'s, as before', () {
    expect(platformRouteSnapshotter(), isA<ChannelRouteSnapshotter>());
  });
}
