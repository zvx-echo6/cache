// The CarPlay harness's stand-in for the app's Dart side. The real one cannot run in the Simulator (its native cores are built
// for the device only). This one does what the product's does at start-up, in the same place (the root widget's start-up, which
// runs with no view when the car was the one to start the engine): it asks whether the build has the car screen
// (lib/car/car_support.dart), sets its side of the car channel and says hello (lib/car/car_bridge.dart). When a car is
// connected it pushes the first recorded trip of tools/carplay-harness/recorded (looking at the map), and it answers the
// car's questions from the recorded messages; the map style it answers with is the stand-in of stand_in_style.py in the
// phone's theme (Dark at start), and the trips carry that theme's palette, as the phone's do. The job on the Mac moves it on
// to the next trip (choosing a route, guiding, and round again), changes the phone's theme, and takes its saved places away
// and gives them back, through the harness's own plugin (steps_plugin).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'recorded.dart';

const MethodChannel _build = MethodChannel('cache/build');
const MethodChannel _car = MethodChannel('co.cache/car');
const MethodChannel _steps = MethodChannel('harness/steps');
const MethodChannel _link = MethodChannel('co.cache/link');
const MethodChannel _phoneWindow = MethodChannel('co.cache/phone_window');
const List<String> _phases = <String>['browsing', 'previewing', 'guiding'];
// The recorded drive, moved along by the job while guiding.
const List<String> _drive = <String>['trip_guiding', 'trip_guiding_near', 'trip_guiding_next', 'trip_rerouting', 'trip_arrived'];
// The phone's four themes; the job changes the chosen one (`theme_dark` and the others), or five times quickly (`themeburst`).
const List<String> _themes = <String>['dark', 'light', 'parchment', 'tactical'];
const List<String> _burst = <String>['light', 'parchment', 'dark', 'light', 'tactical'];

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
  bool _phoneDrive = false;
  String? _lastTrip;
  String? _lastRoute;
  int _frame = 0;
  bool _voiceOn = true;
  String _theme = 'dark';

  @override
  void initState() {
    super.initState();
    unawaited(_startLinks());
    unawaited(_startCarSide());
    unawaited(_startPhoneWindow());
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

  /// Whether the phone's own window is on the phone's screen, as lib/platform/phone_window.dart follows it: asked at start,
  /// then heard as it changes. Said in the app's log, where the job reads it.
  Future<void> _startPhoneWindow() async {
    _phoneWindow.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'changed') await _steps.invokeMethod<void>('say', 'phone window visible ${call.arguments}');
      return null;
    });
    try {
      final Object? now = await _phoneWindow.invokeMethod<Object?>('get');
      await _steps.invokeMethod<void>('say', 'phone window at start: visible $now');
    } on MissingPluginException {
      // No phone window channel on this side.
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
        case 'phoneon':
        case 'phoneoff':
          // The phone's drive screen comes up, or goes: the trip is pushed again with the word changed and nothing else.
          _phoneDrive = call.method == 'phoneon';
          final String? last = _lastTrip;
          final String? route = _lastRoute;
          if (_phase == 2 && last != null && route != null) await _pushRaw(last, route);
          await _steps.invokeMethod<void>('say', 'phone drive screen $_phoneDrive');
        case 'phoneflip':
          // The phone's drive screen comes up for one second and goes again, timed here: the job's notifications each take
          // a second or more to arrive on a busy runner, which made a flip from the job longer than the car's pause.
          for (final bool on in <bool>[true, false]) {
            _phoneDrive = on;
            final String? last = _lastTrip;
            final String? route = _lastRoute;
            if (_phase == 2 && last != null && route != null) await _pushRaw(last, route);
            await _steps.invokeMethod<void>('say', 'phone drive screen $_phoneDrive');
            if (on) await Future<void>.delayed(const Duration(seconds: 1));
          }
        case 'prompt':
          // As the phone's voice before each prompt (CarAwareSpeaker): how may it be given at this moment?
          final Object? how = await _car.invokeMethod<Object?>('prompt', <String, Object?>{'text': 'Turn left.'});
          await _steps.invokeMethod<void>('say', 'prompt answered $how');
        case 'theme_dark':
        case 'theme_light':
        case 'theme_parchment':
        case 'theme_tactical':
          await _setTheme(call.method.substring('theme_'.length));
        case 'themeburst':
          // Five theme changes a tenth of a second apart, timed here: the job's notifications each take a second or more.
          for (final String t in _burst) {
            await _setTheme(t);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await _steps.invokeMethod<void>('say', 'theme burst done, the last $_theme');
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
      case 'extras':
        // How the car screen carries the two extras, for the phone's drive screen (the phone's own side of this is not on
        // this branch): said in the app's log, where the job reads it.
        final Object? how = call.arguments;
        await _steps.invokeMethod<void>('say', 'the car carries the extras: ${how is Map ? how['carries'] : how}');
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
        // As car_bridge.dart answers: the style of the phone's theme as text, the theme's name, and the colours of what the car
        // draws on top. Whatever the car says of its day or night, the theme decides.
        return <String, Object?>{'style': recorded['style_$_theme'], 'theme': _theme, 'colors': jsonDecode(recorded['colors_$_theme']!)};
    }
    return null;
  }

  /// The phone's chosen theme changed, as car_bridge.dart does it: the car is told to load its style again (one word for each
  /// change), and the trip goes out again with the new theme's palette.
  Future<void> _setTheme(String theme) async {
    if (!_themes.contains(theme)) return;
    _theme = theme;
    await _steps.invokeMethod<void>('say', 'phone theme $theme');
    await _car.invokeMethod<void>('styleChanged');
    final String? last = _lastTrip;
    final String? route = _lastRoute;
    if (last != null && route != null) await _pushRaw(last, route);
  }

  Future<void> _pushRaw(String trip, String route) async {
    final Map<String, dynamic> message = jsonDecode(trip) as Map<String, dynamic>;
    message['voiceOn'] = _voiceOn;
    // The palette is the phone's chosen theme, as carOverlayPalette sends it (the recorded trips carry Dark's).
    if (message['palette'] != null) message['palette'] = jsonDecode(recorded['palette_$_theme']!);
    // The phone's one word about its own screen (`overlay.phoneDrive`: its drive screen is showing), as the phone will send
    // it with every trip while guiding. The recorded trips do not carry it yet; the job turns it on and off here.
    final Object? overlay = message['overlay'];
    if (overlay is Map<String, dynamic>) overlay['phoneDrive'] = _phoneDrive;
    _lastTrip = jsonEncode(message);
    _lastRoute = route;
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
    // As the phone: what it is doing goes on while the car is away, and the car is shown it again when it comes back.
    await _push();
    await _car.invokeMethod<void>('savedChanged');
    await _car.invokeMethod<void>('notice', <String, Object?>{'text': 'A recorded notice'});
    await _sendPins();
  }

  // Made-up pins around the recorded drive, sent as the phone sends its map's pins (lib/car/car_pins.dart, carPinsMessage): the
  // style's pin source, points that carry only their picture's name, the picture as PNG at 3 pixels per point, and reset.
  static const List<List<double>> _pinPlaces = <List<double>>[
    <double>[10.5015, 20.2315], <double>[10.5045, 20.2348], <double>[10.4985, 20.226], <double>[10.512, 20.2295], <double>[10.5075, 20.2410],
  ];

  Future<void> _sendPins() async {
    final List<Map<String, Object?>> features = <Map<String, Object?>>[
      for (final List<double> at in _pinPlaces)
        <String, Object?>{
          'type': 'Feature',
          'geometry': <String, Object?>{'type': 'Point', 'coordinates': <double>[at[1], at[0]]},
          'properties': <String, Object?>{'pin': 'harness-pin'},
        },
    ];
    final String geojson = jsonEncode(<String, Object?>{'type': 'FeatureCollection', 'features': features});
    await _car.invokeMethod<void>('pins', <String, Object?>{
      'source': 'cache-notebook',
      'geojson': geojson,
      'images': <String, Uint8List>{'harness-pin': await _pinPicture()},
      'ratio': 3.0,
      'reset': true,
    });
    await _steps.invokeMethod<void>('say', 'pins sent, ${features.length} pins');
  }

  // A round pin, 45 points square at 3 pixels per point (the phone's pictures are that size): a red disc with a white edge.
  static Future<Uint8List> _pinPicture() async {
    const double ratio = 3;
    const double box = 45;
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas c = Canvas(rec)..scale(ratio);
    const Offset mid = Offset(box / 2, box / 2);
    c.drawCircle(mid, 13, Paint()..color = const Color(0xFFC62E24));
    c.drawCircle(mid, 13, Paint()..color = const Color(0xFFFFFFFF)..style = PaintingStyle.stroke..strokeWidth = 3);
    c.drawCircle(mid, 4, Paint()..color = const Color(0xFFFFFFFF));
    final ui.Image img = await rec.endRecording().toImage((box * ratio).round(), (box * ratio).round());
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
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
