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

/// A download was not started because the phone is on mobile data and "Mobile data downloads" (Settings > Storage) is off. The
/// download pop-up offers "Wait for Wi-Fi" or "Download now", which repeats the call with `anyway: true`.
class MobileDataBlocked implements Exception {
  const MobileDataBlocked();

  String get message => 'Waiting for Wi-Fi: mobile data downloads are off.';

  @override
  String toString() => message;
}

/// The one place that decides whether a big download may start on the current connection, from the "Mobile data downloads" switch.
/// Every download path in the app asks it before it starts or continues a transfer. Updates (weather, alerts, catalogues) always
/// use any connection.
class DataPolicy {
  DataPolicy({required this.settings, ConnectionProbe? probe}) : probe = probe ?? ConnectivityProbe();

  final AppSettings settings;
  final ConnectionProbe probe;

  /// True when the phone is on mobile data (and not Wi-Fi).
  Future<bool> onMobile() async => await probe.current() == ConnectionKind.mobile;

  /// A large download (map area, ZIM, model, video) is blocked right now.
  Future<bool> blocksDownload() async => !settings.mobileForDownloads && await onMobile();

  /// Throws [MobileDataBlocked] when a download may not start. [anyway] is the person's "Download now".
  Future<void> checkDownload({bool anyway = false}) async {
    if (!anyway && await blocksDownload()) throw const MobileDataBlocked();
  }
}
