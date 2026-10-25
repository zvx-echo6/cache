import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../location/coords.dart';
import '../location/location_service.dart';
import '../theme.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

/// The Maps tab. The map itself comes in step 8; until then it shows where the phone is.
class MapsScreen extends StatelessWidget {
  const MapsScreen({super.key, required this.location});

  final LocationService location;

  /// The polite ask shown before the system prompt (never on launch, only when the user taps for location).
  Future<bool> _explain(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use your location?'),
        content: const Text(
          'Cache uses your location to show where you are and to answer questions about places near you. '
          'It stays on this phone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    return yes == true;
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Maps')),
      body: ListenableBuilder(
        listenable: location,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.my_location, color: k.secondary),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Where you are', style: Theme.of(context).textTheme.titleMedium)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (location.fix != null) ..._fixLines(context, location) else _none(context),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use my location', style: TextStyle(fontSize: 17)),
                    value: location.enabled,
                    onChanged: (v) => location.setEnabled(v),
                  ),
                  if (location.enabled)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: location.busy ? null : () => location.request(explain: () => _explain(context)),
                        icon: location.busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.location_searching),
                        label: Text(location.fix == null ? 'Find my location' : 'Update'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Center(child: Text('The map comes in step 8', style: TextStyle(fontSize: 16, color: k.secondary))),
          ],
        ),
      ),
    );
  }

  Widget _none(BuildContext context) {
    final k = context.t;
    final String text;
    Widget? action;
    switch (location.problem) {
      case LocationProblem.off:
        text = 'Location is off.';
      case LocationProblem.permissionDenied:
        text = 'Cache was not allowed to read your location.';
      case LocationProblem.permissionBlocked:
        text = 'Location is blocked for Cache. You can allow it in the phone\'s settings.';
        action = TextButton(onPressed: location.openAppSettings, child: const Text('Open settings'));
      case LocationProblem.serviceOff:
        text = 'Your phone\'s location is switched off.';
        action = TextButton(onPressed: location.openLocationSettings, child: const Text('Open settings'));
      case LocationProblem.noFix:
        text = 'Could not get a position yet. Try again outdoors.';
      case null:
        text = location.enabled ? 'No position yet.' : 'Location is off.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: TextStyle(fontSize: 16, color: k.secondary)),
        ?action,
      ],
    );
  }

  List<Widget> _fixLines(BuildContext context, LocationService location) {
    final k = context.t;
    final f = location.fix!;
    final decimal = formatDecimal(f.lat, f.lon);
    final dms = formatDms(f.lat, f.lon);
    Widget line(String label, String value) => Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 14, color: k.secondary)),
                  SelectableText(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                ],
              ),
            ),
            IconButton(tooltip: 'Copy', icon: Icon(Icons.copy, color: k.secondary), onPressed: () => _copy(context, value)),
          ],
        );
    return [
      line('Decimal', decimal),
      line('Degrees, minutes, seconds', dms),
      Text('Within ${f.accuracyM.round()} m · fixed at ${_clock(f.time)}', style: TextStyle(fontSize: 15, color: k.secondary)),
    ];
  }
}
