// The CarPlay harness's stand-in for the app's Dart side. The real one cannot run in the Simulator (its native cores are built
// for the device only). This one does what the product's does at start-up, in the same place (the root widget's start-up, which
// runs with no view when the car was the one to start the engine): it asks whether the build has the car screen
// (lib/car/car_support.dart), sets its side of the car channel and says hello (lib/car/car_bridge.dart). When a car is
// connected it pushes the recorded messages of tools/carplay-harness/recorded, and it answers the car's questions from them.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'recorded.dart';

const MethodChannel _build = MethodChannel('cache/build');
const MethodChannel _car = MethodChannel('co.cache/car');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HarnessApp());
}

class HarnessApp extends StatefulWidget {
  const HarnessApp({super.key});

  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<HarnessApp> {
  String _status = 'The car side has not been asked yet.';
  bool _connected = false;
  int _pushed = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_startCarSide());
  }

  void _say(String text) {
    if (mounted) setState(() => _status = text);
  }

  Future<void> _startCarSide() async {
    Object? build;
    try {
      build = await _build.invokeMethod<Object?>('get');
    } catch (_) {
      build = null;
    }
    if (build is! Map || build['carPlay'] != true) {
      _say('This build has no car screen.');
      return;
    }
    _car.setMethodCallHandler(_onCall);
    try {
      final Object? reply = await _car.invokeMethod<Object?>('hello');
      _say('Said hello to the car side.');
      if (reply is Map && reply['connected'] == true) await _carConnected(true);
    } on MissingPluginException {
      _say('No car side answered hello.');
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'connected':
        final Object? a = call.arguments;
        await _carConnected(a is Map && a['on'] == true);
        return null;
      case 'saved':
        return jsonDecode(recorded['saved']!);
      case 'snapshot':
        return jsonDecode(recorded['trip_guiding']!);
    }
    return null;
  }

  Future<void> _carConnected(bool on) async {
    if (_connected == on) return;
    _connected = on;
    if (!on) {
      _say('The car has gone.');
      return;
    }
    for (final String name in const <String>['trip_browsing', 'trip_previewing', 'trip_guiding']) {
      await _car.invokeMethod<void>('trip', jsonDecode(recorded[name]!));
      _pushed++;
    }
    await _car.invokeMethod<void>('route', jsonDecode(recorded['route']!));
    await _car.invokeMethod<void>('savedChanged');
    await _car.invokeMethod<void>('notice', <String, Object?>{'text': 'A recorded notice'});
    _say('A car is connected: $_pushed recorded trips pushed to it.');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'CarPlay harness\n\nThe phone window, built by the app\'s own scene delegate around the engine its app delegate made.\n\n$_status',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
