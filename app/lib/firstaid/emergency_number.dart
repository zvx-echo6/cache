// "Call emergency services": the phone's dialer opens with the local emergency number filled in. The number is chosen from the
// device's region (its locale), because neither Android nor iOS offers an intent that opens an emergency dial screen to an app: the
// number goes to the ordinary dialer (`tel:`) and the person presses call there. It is never dialled by Cache.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../net/web_link.dart';

/// The emergency number for a region ([countryCode], two letters): 911 in the US and Canada, 999 in the UK, 000 in Australia,
/// 111 in New Zealand; 112 elsewhere (it is the number of the EU and of most countries, and a GSM phone takes it anywhere).
String emergencyNumberFor(String? countryCode) {
  switch (countryCode?.toUpperCase()) {
    case 'US':
    case 'CA':
    case 'PR':
    case 'GU':
    case 'VI':
    case 'AS':
    case 'MP':
      return '911';
    case 'GB':
    case 'GG':
    case 'JE':
    case 'IM':
      return '999';
    case 'AU':
      return '000';
    case 'NZ':
      return '111';
    default:
      return '112';
  }
}

/// Whether the platform has a phone dialer to open (a phone; not a computer or a browser).
bool get emergencyDialerAvailable => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// The region of the device: its locale's country.
String? deviceRegion() => WidgetsBinding.instance.platformDispatcher.locale.countryCode;

/// Opens the dialer with [number] filled in; [open] is how (a test gives its own). Never places the call.
Future<bool> openEmergencyDialer({String? number, Future<void> Function(String uri)? open}) async {
  final n = number ?? emergencyNumberFor(deviceRegion());
  try {
    await (open ?? WebLinks.open)('tel:$n');
    return true;
  } catch (_) {
    return false;
  }
}
