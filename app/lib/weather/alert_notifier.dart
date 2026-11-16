import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../platform.dart' as plat;
import '../settings/app_settings.dart';
import 'alert_watch.dart';
import 'browser_notification.dart';

/// Shows alert pop-ups (local notifications: nothing goes through a server) and reports which one was tapped.
abstract class AlertNotifier {
  /// Shows [a] the way [delivery] says (silent in quiet hours). Returns false when it could not be shown.
  Future<bool> show(NewAlert a, AlertDelivery delivery);
}

/// The phone's notifications. Two Android channels, so the person can tune each in system settings: "Alerts" (sound and vibration)
/// and "Alerts during quiet hours" (silent). On iPhone an extreme alert is Time Sensitive, so it can come through Focus.
class LocalAlertNotifier implements AlertNotifier {
  LocalAlertNotifier._();

  static final LocalAlertNotifier instance = LocalAlertNotifier._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  final StreamController<AlertFocus> _taps = StreamController<AlertFocus>.broadcast();

  /// A pop-up was tapped while the app was running.
  Stream<AlertFocus> get taps => _taps.stream;

  static const _loud = AndroidNotificationDetails(
    'cache-alerts',
    'Alerts',
    channelDescription: 'Warnings and fires near the places you watch',
    importance: Importance.high,
    priority: Priority.high,
    icon: 'ic_stat_cache',
    category: AndroidNotificationCategory.event,
  );

  static const _quiet = AndroidNotificationDetails(
    'cache-alerts-quiet',
    'Alerts during quiet hours',
    channelDescription: 'Alerts that arrive during your quiet hours, without sound',
    importance: Importance.low,
    priority: Priority.low,
    playSound: false,
    enableVibration: false,
    icon: 'ic_stat_cache',
  );

  /// Sets the plugin up (safe to call again). In the app, [onTap] gets taps while it runs; the tap that started the app is
  /// returned by [launchFocus].
  Future<void> init() async {
    if (_ready) return;
    // A browser shows its own notifications (browser_notification.dart); the phone's plugin has nothing to set up there.
    if (plat.isWeb) {
      _ready = true;
      return;
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_cache'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        final f = AlertFocus.fromPayload(r.payload);
        if (f != null) _taps.add(f);
      },
    );
    _ready = true;
  }

  /// The pop-up that opened the app, if one did.
  Future<AlertFocus?> launchFocus() async {
    if (plat.isWeb) return null;
    await init();
    final d = await _plugin.getNotificationAppLaunchDetails();
    if (d == null || !d.didNotificationLaunchApp) return null;
    return AlertFocus.fromPayload(d.notificationResponse?.payload);
  }

  @override
  Future<bool> show(NewAlert a, AlertDelivery delivery) async {
    if (delivery == AlertDelivery.none) return false;
    if (plat.isWeb) {
      final f = AlertFocus.fromPayload(a.payload);
      return showBrowserNotification(
        title: a.title,
        body: a.body,
        tag: a.item.address,
        quiet: delivery == AlertDelivery.silent,
        extreme: a.extreme,
        onTap: () {
          if (f != null) _taps.add(f);
        },
      );
    }
    try {
      await init();
      final quiet = delivery == AlertDelivery.silent;
      await _plugin.show(
        id: a.item.address.hashCode & 0x7fffffff,
        title: a.title,
        body: a.body.isEmpty ? null : a.body,
        payload: a.payload,
        notificationDetails: NotificationDetails(
          android: quiet ? _quiet : _loud,
          iOS: DarwinNotificationDetails(
            presentSound: !quiet,
            interruptionLevel: a.extreme && !quiet ? InterruptionLevel.timeSensitive : (quiet ? InterruptionLevel.passive : InterruptionLevel.active),
          ),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
