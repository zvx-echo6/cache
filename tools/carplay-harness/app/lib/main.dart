// The CarPlay harness's stand-in for the app's Dart side. The real one cannot run in the Simulator (its native cores are built
// for the device only). This one does what the product's does at start-up, in the same place (the root widget's start-up, which
// runs with no view when the car was the one to start the engine): it asks whether the build has the car screen
// (lib/car/car_support.dart), sets its side of the car channel and says hello (lib/car/car_bridge.dart). When a car is
// connected it pushes the first recorded trip of tools/carplay-harness/recorded (looking at the map), and it answers the
// car's questions from the recorded messages; the map style it answers with is the stand-in of stand_in_style.py, light or
// dark as the car asks. The job on the Mac moves it on to the next trip (choosing a route, guiding, and round again), and
// takes its saved places away and gives them back, through the harness's own plugin (steps_plugin).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'recorded.dart';

const MethodChannel _build = MethodChannel('cache/build');
const MethodChannel _car = MethodChannel('co.cache/car');
const MethodChannel _steps = MethodChannel('harness/steps');
const List<String> _phases = <String>['browsing', 'previewing', 'guiding'];

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
  int _phase = 0;
  bool _noSaved = false;

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
    _steps.setMethodCallHandler((MethodCall call) async {
      if (!_connected) return null;
      switch (call.method) {
        case 'next':
          _phase = (_phase + 1) % _phases.length;
          await _push();
        case 'nosaved':
        case 'saved':
          // The phone's saved places changed: none are left, or the recorded ones are back.
          _noSaved = call.method == 'nosaved';
          await _car.invokeMethod<void>('savedChanged');
      }
      return null;
    });
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
        return _noSaved ? <Object?>[] : jsonDecode(recorded['saved']!);
      case 'search':
        // One typed character finds the recorded places; more find nothing (the job types one, then another).
        final Object? typed = call.arguments;
        final String query = typed is Map && typed['query'] is String ? typed['query'] as String : '';
        return query.trim().length == 1 ? jsonDecode(recorded['search']!) : <Object?>[];
      case 'snapshot':
        return jsonDecode(recorded['trip_${_phases[_phase]}']!);
      case 'style':
        // As car_bridge.dart answers: the style as text, and the colours of what the car draws on top.
        final Object? asked = call.arguments;
        final String look = asked is Map && asked['dark'] == true ? 'dark' : 'light';
        return <String, Object?>{'style': recorded['style_$look'], 'colors': jsonDecode(recorded['colors_$look']!)};
    }
    return null;
  }

  /// The trip of the phase and then its route line, in the order car_bridge.dart pushes them.
  Future<void> _push() async {
    final String phase = _phases[_phase];
    await _car.invokeMethod<void>('trip', jsonDecode(recorded['trip_$phase']!));
    _pushed++;
    await _car.invokeMethod<void>('route', jsonDecode(recorded[phase == 'browsing' ? 'route_none' : 'route_$phase']!));
    _say('A car is connected: $_pushed recorded trips pushed to it, the last one $phase.');
  }

  Future<void> _carConnected(bool on) async {
    if (_connected == on) return;
    _connected = on;
    if (!on) {
      _say('The car has gone.');
      return;
    }
    _phase = 0;
    await _push();
    await _car.invokeMethod<void>('savedChanged');
    await _car.invokeMethod<void>('notice', <String, Object?>{'text': 'A recorded notice'});
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
