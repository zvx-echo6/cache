// The CarPlay harness's stand-in for the app's Dart side. The real one cannot run in the Simulator (its native cores are built
// for the device only); this one is just enough for the phone's window to show something when it joins the engine. Later
// pieces add the car channel's answers here (recorded trips and places), so the Swift car files can be seen with data.
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HarnessApp());
}

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'CarPlay harness\n\nThe phone window, built by the app\'s own scene delegate around the engine its app delegate made.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
