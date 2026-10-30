import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../weather/place_alerts.dart';

/// The per-place alert sheet behind a place's gear: "Same as your alert setting" (the default), "Custom for this place" (which
/// unlocks how far out and which kinds) or "Off". Returns the chosen rule, or null when closed without a change.
Future<PlaceAlertRule?> showPlaceAlertSheet(
  BuildContext context, {
  required String placeName,
  required PlaceAlertRule rule,
  String? alertSetting,
  List<String> kinds = const ['alerts', 'fire'],
}) =>
    showModalBottomSheet<PlaceAlertRule>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _PlaceAlertSheet(placeName: placeName, rule: rule, alertSetting: alertSetting, kinds: kinds),
    );

class _PlaceAlertSheet extends StatefulWidget {
  const _PlaceAlertSheet({required this.placeName, required this.rule, required this.kinds, this.alertSetting});

  final String placeName;
  final PlaceAlertRule rule;
  final String? alertSetting;

  /// The kinds the sources that are on can give.
  final List<String> kinds;

  @override
  State<_PlaceAlertSheet> createState() => _PlaceAlertSheetState();
}

class _PlaceAlertSheetState extends State<_PlaceAlertSheet> {
  late PlaceAlertRule _rule = widget.rule;

  void _set(PlaceAlertRule r) => setState(() => _rule = r);

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    Widget choice(PlaceAlertMode m, String title, String? detail) {
      final on = _rule.mode == m;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: k.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: on ? k.accent : Colors.transparent)),
          child: RadioListTile<PlaceAlertMode>(
            key: ValueKey('alert-mode-${m.name}'),
            value: m,
            controlAffinity: ListTileControlAffinity.trailing,
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
            subtitle: detail == null ? null : Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
          ),
        ),
      );
    }

    final custom = _rule.mode == PlaceAlertMode.custom;
    final kinds = {...widget.kinds, ..._rule.kinds}.where(kAlertKinds.containsKey).toList()
      ..sort((a, b) => kAlertKinds.keys.toList().indexOf(a).compareTo(kAlertKinds.keys.toList().indexOf(b)));
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text('Alerts for ${widget.placeName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: k.text)),
          const SizedBox(height: 12),
          RadioGroup<PlaceAlertMode>(
            groupValue: _rule.mode,
            onChanged: (v) => _set(_rule.copyWith(mode: v)),
            child: Column(
              children: [
                choice(PlaceAlertMode.same, 'Same as your alert setting', widget.alertSetting),
                choice(PlaceAlertMode.custom, 'Custom for this place', null),
                choice(PlaceAlertMode.off, 'Off', 'No alerts for this place'),
              ],
            ),
          ),
          if (custom) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
              child: Text('CUSTOM', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1, color: k.secondary)),
            ),
            ListTile(
              key: const ValueKey('alert-miles'),
              minTileHeight: 52,
              leading: Icon(Icons.radar, color: k.secondary),
              title: const Text('How far out'),
              subtitle: Text('${_rule.miles} mi'),
              trailing: DropdownButton<int>(
                value: kAlertMiles.contains(_rule.miles) ? _rule.miles : 25,
                underline: const SizedBox.shrink(),
                items: [for (final m in kAlertMiles) DropdownMenuItem(value: m, child: Text('$m mi'))],
                onChanged: (m) => _set(_rule.copyWith(miles: m)),
              ),
            ),
            for (final kind in kinds)
              SwitchListTile(
                key: ValueKey('alert-kind-$kind'),
                title: Text(kAlertKinds[kind]!),
                value: _rule.kinds.contains(kind),
                onChanged: (on) => _set(_rule.copyWith(kinds: on ? {..._rule.kinds, kind} : ({..._rule.kinds}..remove(kind)))),
              ),
          ],
          const SizedBox(height: 8),
          FilledButton(key: const ValueKey('alert-done'), onPressed: () => Navigator.pop(context, _rule), child: const Text('Done')),
        ],
      ),
    );
  }
}

/// The weather row's detail: "Serious alerts · within 25 mi", "Alerts off", or the alert setting's own words.
String placeAlertLine(PlaceAlertRule r, String? alertSetting) => switch (r.mode) {
      PlaceAlertMode.off => 'Alerts off',
      PlaceAlertMode.custom => '${r.kinds.length == 1 ? kAlertKinds[r.kinds.first] : '${r.kinds.length} kinds'} · within ${r.miles} mi',
      PlaceAlertMode.same => alertSetting ?? 'Same as your alert setting',
    };
