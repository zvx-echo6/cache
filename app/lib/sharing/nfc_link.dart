import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the iPhone's "Read by NFC" button is offered. True together with the NFC Tag Reading capability on the App ID and
/// `com.apple.developer.nfc.readersession.formats` = [NDEF] in ios/Runner/Runner.entitlements; the two go on and off together.
const kIosNfcEnabled = true;

/// What the phone's NFC can do right now.
class NfcStatus {
  const NfcStatus({this.available = false, this.enabled = false, this.hce = false});

  /// The phone has NFC (iPhone: reading is available).
  final bool available;

  /// NFC is switched on (Android).
  final bool enabled;

  /// The phone can act as a tag (Android host card emulation).
  final bool hce;

  static const none = NfcStatus();
}

/// Linking two devices by NFC, over the channel `co.cache/nfc` (Android `MainActivity`, iPhone `AppDelegate`).
///
/// Android gives a link by acting as a read-only tag while the link-code sheet is open ([serve]), and takes one from another phone
/// or a tag while the link entry is open ([startReader], links arrive on [onTag]). The iPhone only reads ([readOnce]), a session
/// the person starts with a button. What is read is the link text; the caller takes it the way a pasted or camera link is taken.
class NfcLink {
  NfcLink({MethodChannel? channel, this.iosEnabled, this.platform}) : _channel = channel ?? const MethodChannel('co.cache/nfc');

  final MethodChannel _channel;

  /// Whether the iPhone button is offered; [kIosNfcEnabled] unless a test says otherwise.
  final bool? iosEnabled;

  /// The platform; the running one unless a test says otherwise.
  final TargetPlatform? platform;

  TargetPlatform get _platform => platform ?? defaultTargetPlatform;
  bool get _android => _platform == TargetPlatform.android;
  bool get _ios => _platform == TargetPlatform.iOS;

  Future<NfcStatus> status() async {
    if (!_android && !_ios) return NfcStatus.none;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('status');
      if (m == null) return NfcStatus.none;
      return NfcStatus(available: m['available'] == true, enabled: m['enabled'] != false && m['available'] == true, hce: m['hce'] == true);
    } on MissingPluginException {
      return NfcStatus.none;
    } on PlatformException {
      return NfcStatus.none;
    }
  }

  /// Whether the link-code sheet can say the phone can be held to another (Android with NFC on and card emulation).
  Future<bool> canGive() async {
    if (!_android) return false;
    final s = await status();
    return s.available && s.enabled && s.hce;
  }

  /// Whether the link entry can read by holding phones back to back (Android with NFC on).
  Future<bool> canReceive() async {
    if (!_android) return false;
    final s = await status();
    return s.available && s.enabled;
  }

  /// Whether the iPhone's "Read by NFC" button shows: the build has the entitlement and this iPhone can read.
  Future<bool> canReadIos() async {
    if (!_ios || !(iosEnabled ?? kIosNfcEnabled)) return false;
    return (await status()).available;
  }

  /// Hands this phone's link out as a tag (Android), or stops with null. The sheet sets it on open and clears it on close.
  Future<void> serve(String? link) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('serve', {'link': link});
    } on MissingPluginException {
      // no NFC here
    } on PlatformException {
      // nothing to serve with
    }
  }

  void Function(String link)? _onTag;

  /// Starts reading tags (Android); each link read goes to [onTag] until [stopReader].
  Future<void> startReader(void Function(String link) onTag) async {
    if (!_android) return;
    _onTag = onTag;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'tag' && call.arguments is String) _onTag?.call(call.arguments as String);
      return null;
    });
    try {
      await _channel.invokeMethod<void>('startReader');
    } on MissingPluginException {
      // no NFC here
    } on PlatformException {
      // cannot start
    }
  }

  Future<void> stopReader() async {
    _onTag = null;
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('stopReader');
    } on MissingPluginException {
      // no NFC here
    } on PlatformException {
      // already stopped
    }
  }

  /// One reading session (iPhone): the first link read, or null when the person cancelled or it could not read.
  Future<String?> readOnce() async {
    if (!_ios) return null;
    try {
      return await _channel.invokeMethod<String>('read');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// The app's NFC link.
final NfcLink nfcLink = NfcLink();
