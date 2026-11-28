import 'dart:async';

// CameraException (its `CameraAccess…` codes say the permission was refused). `camera` comes in through flutter_zxing, which does not
// re-export it, so it is not listed in pubspec.yaml.
// ignore: depend_on_referenced_packages
import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:geolocator/geolocator.dart';

import 'link_scan.dart';

/// The camera scanner on flutter_zxing (zxing-cpp), QR codes only, and only the square the guide shows is read. It reads on the phone with no network. flutter_zxing's own
/// widget opens the camera (the `camera` plugin, which asks for the permission then and not before) and has the torch button;
/// its gallery and switch-camera buttons are off.
class ZxingLinkScanner implements LinkScanner {
  @override
  Widget view({required void Function(String text) onText, required void Function(ScanProblem problem) onProblem}) => ReaderWidget(
    codeFormat: Format.qrCode,
    showGallery: false,
    showToggleCamera: false,
    isMultiScan: false,
    cropPercent: 0.8,
    onScan: (code) {
      final t = code.text;
      if (t != null && t.isNotEmpty) onText(t);
    },
    onControllerCreated: (controller, error) {
      if (error == null) return;
      onProblem(error is CameraException && error.code.startsWith('CameraAccess') ? ScanProblem.denied : ScanProblem.unavailable);
    },
  );

  /// The app's existing route to Cache's page in the phone's settings (as for location).
  @override
  Future<void> openSettings() => Geolocator.openAppSettings();
}
