import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform.dart' as plat;
import '../settings/app_settings.dart';
import 'car_support.dart' show readCarScreenSupport;

/// Where the iPhone's microphone and speech recognition permissions for voice search from the car stand, and the asking.
///
/// iPhone only, in a build made with the car screen (the iOS side is `CarListenPermissions` in
/// app/ios/Runner/CarPlay/CarListen.swift, on the `co.cache/car` channel: `voiceStatus` and `voiceRequest`, each answering
/// `{microphone, speech}` with `granted`, `denied` or `undetermined`). The car's own microphone button shows only when both are
/// granted; the iOS side tells the car to look again when the answer changes.
///
/// The one-time card on Home ([CarVoiceCard]) and the row in Settings both use this. Whether the car was ever connected, and
/// whether the card was answered, are kept in [AppSettings] (preferences.json).
class CarVoiceAccess extends ChangeNotifier with WidgetsBindingObserver {
  CarVoiceAccess({
    required this.settings,
    this.openSettings,
    Future<bool> Function()? supported,
    MethodChannel? channel,
    bool? ios,
  })  : _channel = channel ?? const MethodChannel('co.cache/car'),
        _supported = supported ?? readCarScreenSupport,
        _ios = ios ?? plat.isIOS;

  final AppSettings settings;

  /// Opens iOS's Settings page for Cache (LocationService.openAppSettings, the one the app already uses).
  final Future<void> Function()? openSettings;
  final MethodChannel _channel;
  final Future<bool> Function() _supported;
  final bool _ios;

  bool _available = false;
  bool _started = false;
  bool _carSeenEarly = false;
  String _microphone = 'undetermined';
  String _speech = 'undetermined';

  /// This is an iPhone with a build made with the car screen: the Settings row may show.
  bool get available => _ios && _available;

  /// Both permissions are granted.
  bool get granted => _microphone == 'granted' && _speech == 'granted';

  /// One was refused before: iOS will not ask again, so a tap opens iOS's Settings for Cache.
  bool get blocked => !granted && (_microphone == 'denied' || _speech == 'denied');

  /// The one-time card: after a car connected, until it is answered, while the two are not both granted.
  bool get showCard => available && settings.carSeen && !settings.carVoiceCardDone && !granted;

  /// Reads whether this build has the car screen, then the permissions, and reads them again whenever the app comes forward
  /// (they may have been changed in iOS's Settings). Call once.
  Future<void> start() async {
    if (!_ios || _started) return;
    _started = true;
    if (_carSeenEarly) settings.setCarSeen();
    settings.addListener(notifyListeners);
    WidgetsBinding.instance.addObserver(this);
    _available = await _supported();
    notifyListeners();
    if (_available) await refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && available) refresh();
  }

  /// A car screen connected: remembered, so the card can show the next time Cache is opened.
  void carConnected() {
    if (!_ios) return;
    // Before start() the preferences may not be read yet (reading them would drop this): kept until then.
    if (!_started) {
      _carSeenEarly = true;
      return;
    }
    settings.setCarSeen();
  }

  Future<void> refresh() async {
    _take(await _call('voiceStatus'));
  }

  /// Asks iOS for the microphone, then for speech recognition (what is already answered is not asked again).
  Future<void> request() async {
    _take(await _call('voiceRequest'));
  }

  /// The Settings row's tap: asks iOS; when a permission was refused before, opens iOS's Settings for Cache instead.
  Future<void> rowTapped() async {
    if (blocked) {
      await openSettings?.call();
      return;
    }
    await request();
  }

  /// "Allow" on the card: the card is put away for good, then iOS is asked.
  Future<void> allowFromCard() async {
    settings.setCarVoiceCardDone();
    await request();
  }

  /// "Not now" on the card: it never shows again.
  void dismissCard() => settings.setCarVoiceCardDone();

  Future<Object?> _call(String method) async {
    try {
      return await _channel.invokeMethod<Object?>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  void _take(Object? answer) {
    if (answer is! Map) return;
    final m = answer['microphone'];
    final s = answer['speech'];
    final mic = m is String ? m : _microphone;
    final spe = s is String ? s : _speech;
    if (mic == _microphone && spe == _speech) return;
    _microphone = mic;
    _speech = spe;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_started) {
      settings.removeListener(notifyListeners);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}

/// The app's voice search access (null on every platform but an iPhone with the car screen, and in tests that do not need it).
CarVoiceAccess? carVoiceShared;
