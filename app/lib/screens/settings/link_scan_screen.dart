import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../sharing/link_scan.dart';

/// "Scan a code": the camera, full screen, reading the QR code another device shows for linking. Pops with the link code it read
/// (from a `cachelink://link/<code>` link or a bare code), or with nothing when the person cancels. A QR code that is not a Cache
/// link code is said and scanning goes on. A refused camera is said, and typing or pasting the code stays available behind it.
class LinkScanScreen extends StatefulWidget {
  const LinkScanScreen({super.key, required this.scanner});
  final LinkScanner scanner;

  @override
  State<LinkScanScreen> createState() => _LinkScanScreenState();
}

class _LinkScanScreenState extends State<LinkScanScreen> {
  ScanProblem? _problem;
  bool _notCode = false;
  bool _read = false;
  int _attempt = 0;

  void _onText(String text) {
    if (_read || !mounted) return;
    final code = scannedLinkCode(text);
    if (code == null) {
      if (!_notCode) setState(() => _notCode = true);
      return;
    }
    setState(() {
      _read = true;
      _notCode = false;
    });
    HapticFeedback.mediumImpact();
    // "Code read" stays on screen a moment so the person sees it was taken.
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (mounted) Navigator.pop(context, code);
    });
  }

  void _onProblem(ScanProblem p) {
    if (mounted && _problem != p) setState(() => _problem = p);
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return Scaffold(
      key: const ValueKey('scan-screen'),
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (problem == null) KeyedSubtree(key: ValueKey(_attempt), child: widget.scanner.view(onText: _onText, onProblem: _onProblem)),
          if (problem != null) _Refused(problem: problem, scanner: widget.scanner, onRetry: () => setState(() {
            _problem = null;
            _attempt++;
          })),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton.icon(
                  key: const ValueKey('scan-cancel'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.black54),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Cancel'),
                ),
              ),
            ),
          ),
          if (problem == null)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 96),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_read) const _Line('Code read', key: ValueKey('scan-read'), good: true),
                      if (_notCode && !_read) const _Line("That isn't a Cache link code", key: ValueKey('scan-not-code')),
                      const SizedBox(height: 8),
                      const _Line('Point the camera at the code on the other device', key: ValueKey('scan-hint')),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text, {super.key, this.good = false});
  final String text;
  final bool good;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: good ? const Color(0xFF1B5E20) : Colors.black87, borderRadius: BorderRadius.circular(8)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
    ),
  );
}

class _Refused extends StatelessWidget {
  const _Refused({required this.problem, required this.scanner, required this.onRetry});
  final ScanProblem problem;
  final LinkScanner scanner;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final denied = problem == ScanProblem.denied;
    return ColoredBox(
      color: const Color(0xFF121212),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 48),
              const SizedBox(height: 16),
              Text(
                key: const ValueKey('scan-refused'),
                denied ? 'Cache cannot use the camera, so it cannot read the code.' : "The camera could not be opened, so Cache cannot read the code.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 17),
              ),
              const SizedBox(height: 8),
              const Text(
                'You can still type or paste the code instead.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton(key: const ValueKey('scan-retry'), onPressed: onRetry, child: const Text('Try again')),
                  if (denied) OutlinedButton(key: const ValueKey('scan-settings'), style: OutlinedButton.styleFrom(foregroundColor: Colors.white), onPressed: scanner.openSettings, child: const Text('Open settings')),
                  OutlinedButton(key: const ValueKey('scan-type'), style: OutlinedButton.styleFrom(foregroundColor: Colors.white), onPressed: () => Navigator.pop(context), child: const Text('Type the code')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
