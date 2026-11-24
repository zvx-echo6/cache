import 'road_sources.dart';

/// A per-host rate limit for road sources: the limit belongs to the site (the host), not to a source, so a site's events and its winter
/// road conditions share one budget. Every 511 site documents "Ten calls every 60 seconds"; SF Bay MTC allows 60 requests an hour.
///
/// A sliding window: a call is allowed when fewer than `calls` were made in the last `window`. Time comes from the caller's clock, so
/// tests never wait.
class HostRateLimiter {
  HostRateLimiter({DateTime Function()? clock, this.fallback = const RateLimit(10, Duration(seconds: 60))}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  /// The limit for a host with none set: the 511 platform's, ten calls every 60 seconds.
  final RateLimit fallback;

  final Map<String, RateLimit> _limits = {};
  final Map<String, List<DateTime>> _calls = {};

  /// Sets the limit of [host] (a host name, lower-case).
  void setLimit(String host, RateLimit limit) => _limits[host.toLowerCase()] = limit;

  RateLimit limitOf(String host) => _limits[host.toLowerCase()] ?? fallback;

  /// Asks for a call to [host]. Returns null when it is allowed (and counts it), or how long to wait before it would be.
  Duration? tryAcquire(String host) {
    final h = host.toLowerCase();
    final lim = limitOf(h);
    final now = _now();
    final list = _calls.putIfAbsent(h, () => []);
    list.removeWhere((t) => now.difference(t) >= lim.window);
    if (list.length < lim.calls) {
      list.add(now);
      return null;
    }
    // The oldest call still in the window leaves it at oldest + window.
    return list.first.add(lim.window).difference(now);
  }

  /// Gives back the latest call to [host] (the core answered from its stored copy, so nothing was asked of the site).
  void release(String host) {
    final list = _calls[host.toLowerCase()];
    if (list != null && list.isNotEmpty) list.removeLast();
  }

  /// How many calls to [host] are inside the window now.
  int used(String host) {
    final h = host.toLowerCase();
    final lim = limitOf(h);
    final now = _now();
    return (_calls[h] ?? const <DateTime>[]).where((t) => now.difference(t) < lim.window).length;
  }
}
