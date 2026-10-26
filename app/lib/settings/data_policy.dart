import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'app_settings.dart';

/// How the phone is connected right now.
enum ConnectionKind {
  /// No connection.
  none,

  /// Wi-Fi or Ethernet: not charged by the megabyte.
  wifi,

  /// A mobile (cellular) connection.
  mobile,

  /// Something else (a VPN, Bluetooth, ...): not treated as mobile.
  other,
}

/// The connection type, behind a seam so it can be tested. The real one is connectivity_plus.
abstract class ConnectionProbe {
  Future<ConnectionKind> current();

  /// The type again whenever it changes.
  Stream<ConnectionKind> get changes;
}

class ConnectivityProbe implements ConnectionProbe {
  static ConnectionKind kindOf(List<ConnectivityResult> r) {
    if (r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet)) return ConnectionKind.wifi;
    if (r.contains(ConnectivityResult.mobile)) return ConnectionKind.mobile;
    if (r.isEmpty || r.every((c) => c == ConnectivityResult.none)) return ConnectionKind.none;
    return ConnectionKind.other;
  }

  @override
  Future<ConnectionKind> current() async {
    try {
      return kindOf(await Connectivity().checkConnectivity());
    } catch (_) {
      // If the system cannot say, do not block the person.
      return ConnectionKind.other;
    }
  }

  @override
  Stream<ConnectionKind> get changes => Connectivity().onConnectivityChanged.map(kindOf);
}

/// A transfer was stopped because the phone is on mobile data and the matching switch in Settings (Storage and data) is off.
/// The screen says [message] and offers "Download anyway", which repeats the call with `anyway: true`.
class MobileDataBlocked implements Exception {
  const MobileDataBlocked({this.updates = false});

  /// True for a small update, false for a large download.
  final bool updates;

  String get message => updates
      ? 'Paused: mobile data is switched off for updates. Connect to Wi-Fi, or check anyway.'
      : 'Paused: mobile data is switched off for downloads. Connect to Wi-Fi, or download anyway.';

  @override
  String toString() => message;
}

/// The one place that decides whether a transfer may start on the current connection, from the two mobile-data switches.
/// Every download path in the app asks it before it starts or continues a transfer.
class DataPolicy {
  DataPolicy({required this.settings, ConnectionProbe? probe}) : probe = probe ?? ConnectivityProbe();

  final AppSettings settings;
  final ConnectionProbe probe;

  /// True when the phone is on mobile data (and not Wi-Fi).
  Future<bool> onMobile() async => await probe.current() == ConnectionKind.mobile;

  /// A large download (map area, ZIM, video) is blocked right now.
  Future<bool> blocksDownload() async => !settings.mobileForDownloads && await onMobile();

  /// A small update (catalogue, weather, alerts) is blocked right now.
  Future<bool> blocksUpdate() async => !settings.mobileForUpdates && await onMobile();

  /// Throws [MobileDataBlocked] when a download may not start. [anyway] is the person's "Download anyway".
  Future<void> checkDownload({bool anyway = false}) async {
    if (!anyway && await blocksDownload()) throw const MobileDataBlocked();
  }

  /// Throws [MobileDataBlocked] (for updates) when an update may not start.
  Future<void> checkUpdate({bool anyway = false}) async {
    if (!anyway && await blocksUpdate()) throw const MobileDataBlocked(updates: true);
  }
}
