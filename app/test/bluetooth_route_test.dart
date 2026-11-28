import 'package:cache/screens/settings/sharing_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> peer() => {
    'via': 'bluetooth',
    'speed': 'medium',
    'live': true,
    'last_seen': DateTime.now().millisecondsSinceEpoch,
  };

  test('a known Bluetooth route is not described as Wi-Fi or direct IP', () {
    final p = peer();
    expect(peerRoute(p).kind, RouteKind.bluetooth);
    expect(peerStatus(p).first.text, 'Bluetooth');
  });

  test('a past Bluetooth connection is reported as past, with its actual carrier', () {
    final p = peer()..['live'] = false;
    expect(peerStatus(p).single.text, endsWith('via Bluetooth'));
  });

  test('slow Bluetooth keeps its carrier name rather than becoming an unknown slow route', () {
    final p = peer()..['speed'] = 'slow';
    expect(peerRoute(p).kind, RouteKind.bluetooth);
    expect(peerStatus(p).first.text, 'Bluetooth');
  });
}
