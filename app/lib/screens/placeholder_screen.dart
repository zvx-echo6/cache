import 'package:flutter/material.dart';

import '../theme.dart';

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Text(message, style: TextStyle(fontSize: 18, color: context.t.secondary)),
      ),
    );
  }
}
