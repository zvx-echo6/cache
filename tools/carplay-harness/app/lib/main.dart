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
const MethodChannel _link = MethodChannel('co.cache/link');
const List<String> _phases = <String>['browsing', 'previewing', 'guiding'];
// The recorded drive, moved along by the job while guiding.
const List<String> _drive = <String>['trip_guiding', 'trip_guiding_near', 'trip_guiding_next', 'trip_rerouting', 'trip_arrived'];

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
  int _frame = 0;
  bool _voiceOn = true;

  @override
  void initState() {
    super.initState();
    unawaited(_startLinks());
    unawaited(_startCarSide());
  }

  void _say(String text) {
    if (mounted) setState(() => _status = text);
  }

  /// A cachelink: link, as lib/sharing/link_inbox.dart takes it: listen for one opened while running, then take one the app
  /// was opened with. What came is said in the app's log (its length only), where the job reads it.
  Future<void> _startLinks() async {
    _link.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'opened' && call.arguments is String) {
        await _steps.invokeMethod<void>('say', 'link opened while running, ${(call.arguments as String).length} characters');
      }
      return null;
    });
    try {
      final String? first = await _link.invokeMethod<String>('take');
      if (first != null) await _steps.invokeMethod<void>('say', 'link taken at start, ${first.length} characters');
    } on MissingPluginException {
      // No link channel on this side.
    }
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
        case 'drive':
          if (_phase == 2) {
            _frame = (_frame + 1) % _drive.length;
            await _pushRaw(recorded[_drive[_frame]]!, recorded['route_guiding']!);
          }
        case 'climb':
          if (_phase == 2) await _pushRaw(recorded['trip_guiding_climb']!, recorded['route_guiding']!);
        case 'roll':
          // A moving vehicle: five positions a second apart along the road (about 80 km/h), the turn that much nearer.
          if (_phase == 2) {
            for (int i = 1; i <= 5; i++) {
              await Future<void>.delayed(const Duration(seconds: 1));
              final Map<String, dynamic> trip = jsonDecode(recorded['trip_guiding']!) as Map<String, dynamic>;
              (trip['position'] as Map<String, dynamic>)['lon'] = 20.23 + 0.0002 * i;
              (trip['step'] as Map<String, dynamic>)['distanceM'] = 320.4 - 22.0 * i;
              trip['remainingM'] = 22860.45 - 22.0 * i;
              await _pushRaw(jsonEncode(trip), recorded['route_guiding']!);
            }
          }
        case 'prompt':
          // As the phone's voice before each prompt (CarAwareSpeaker): how may it be given at this moment?
          final Object? how = await _car.invokeMethod<Object?>('prompt', <String, Object?>{'text': 'Turn left.'});
          await _steps.invokeMethod<void>('say', 'prompt answered $how');
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
      case 'directions':
        // As car_bridge.dart: true when the place is one the car was shown, and the routes to it follow in the trip. The
        // third saved place stands for one no route can be found to yet.
        final Object? to = call.arguments;
        final String id = to is Map && to['id'] is String ? to['id'] as String : '';
        final List<Object?> known = <Object?>[...jsonDecode(recorded['saved']!) as List, ...jsonDecode(recorded['search']!) as List];
        if (!known.any((Object? p) => p is Map && p['id'] == id)) return false;
        _phase = 1;
        if (id == (known[2] as Map)['id']) {
          unawaited(_pushRaw(recorded['trip_error']!, recorded['route_none']!));
        } else {
          unawaited(_push());
        }
        return true;
      case 'selectRoute':
        // The other route is the chosen one now: the trip says so and the line is drawn the other way round.
        final Object? which = call.arguments;
        final int index = which is Map && which['index'] is int ? which['index'] as int : 0;
        final Map<String, dynamic> trip = jsonDecode(recorded['trip_previewing']!) as Map<String, dynamic>;
        trip['routeIndex'] = index;
        trip['routeId'] = 'route-$index';
        unawaited(_pushRaw(jsonEncode(trip), recorded[index == 0 ? 'route_previewing' : 'route_previewing_alt']!));
        return null;
      case 'start':
        _phase = 2;
        _frame = 0;
        await _push();
        return true;
      case 'cancel':
      case 'stop':
        _phase = 0;
        await _push();
        return null;
      case 'voice':
        // The phone's voice switch: the trip says which way it is.
        final Object? wanted = call.arguments;
        _voiceOn = wanted is Map && wanted['on'] == true;
        if (_phase == 2) await _pushRaw(recorded[_drive[_frame]]!, recorded['route_guiding']!);
        return _voiceOn;
      case 'style':
        // As car_bridge.dart answers: the style as text, and the colours of what the car draws on top.
        final Object? asked = call.arguments;
        final String look = asked is Map && asked['dark'] == true ? 'dark' : 'light';
        return <String, Object?>{'style': recorded['style_$look'], 'colors': jsonDecode(recorded['colors_$look']!)};
    }
    return null;
  }

  Future<void> _pushRaw(String trip, String route) async {
    final Map<String, dynamic> message = jsonDecode(trip) as Map<String, dynamic>;
    message['voiceOn'] = _voiceOn;
    await _car.invokeMethod<void>('trip', message);
    _pushed++;
    await _car.invokeMethod<void>('route', jsonDecode(route));
  }

  /// The trip of the phase and then its route line, in the order car_bridge.dart pushes them.
  Future<void> _push() async {
    final String phase = _phases[_phase];
    if (phase == 'guiding') _frame = 0;
    await _pushRaw(recorded['trip_$phase']!, recorded[phase == 'browsing' ? 'route_none' : 'route_$phase']!);
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
