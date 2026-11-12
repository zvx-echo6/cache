// CarPlay spike: the Dart side of the scratch app. It says hello to the native side over one method channel as soon as it
// runs (the CarPlay scene shows the value on its bar buttons), answers when the native side asks, and reports every five
// seconds that it is still running. The widget is only seen when the phone window joins the same engine.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const MethodChannel _car = MethodChannel('spike/car');
final DateTime _started = DateTime.now();
final ValueNotifier<String> _status = ValueNotifier<String>('Dart is running; the native side has not answered yet');
int _asked = 0;
int _ticks = 0;

String get _dartVersion => Platform.version.split(' ').first;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _car.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'ask') {
      _asked++;
      return <String, Object?>{
        'answer': 'Dart $_dartVersion',
        'asked': _asked,
        'uptimeMs': DateTime.now().difference(_started).inMilliseconds,
        'lifecycle': '${WidgetsBinding.instance.lifecycleState}',
      };
    }
    throw MissingPluginException('spike/car has no ${call.method}');
  });
  runApp(const SpikeApp());
  // Worked out when this runs, not a constant: 1 + 2 + ... + 9.
  final int sum = List<int>.generate(9, (int i) => i + 1).reduce((int a, int b) => a + b);
  try {
    final Object? reply = await _car.invokeMethod<Object?>('hello', <String, Object?>{
      'value': 'Dart $_dartVersion',
      'sum': sum,
    });
    _status.value = 'Dart $_dartVersion said hello; the native side answered $reply';
  } catch (e) {
    _status.value = 'hello failed: $e';
  }
  Timer.periodic(const Duration(seconds: 5), (Timer timer) {
    _ticks++;
    final int up = DateTime.now().difference(_started).inSeconds;
    _car.invokeMethod<Object?>('log', 'tick $_ticks after $up s, lifecycle ${WidgetsBinding.instance.lifecycleState}');
  });
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder<String>(
              valueListenable: _status,
              builder: (BuildContext context, String value, Widget? child) {
                return Text(
                  'CarPlay spike: the phone window\n\n$value\n\nasked by the native side: $_asked times',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
