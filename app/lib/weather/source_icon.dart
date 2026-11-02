import 'package:flutter/material.dart';

import 'connector.dart';

/// The icon of a live source, by what it gives (its catalogue category; built-in sources have none, so their ids decide). Weather
/// alerts and emergency alerts have different icons.
IconData sourceIcon(Connector c) {
  final cat = c.category == 'other' ? (c.id == 'weather' ? 'weather' : c.id == 'alerts' ? 'alerts' : 'other') : c.category;
  return switch (cat) {
    'weather' => Icons.wb_cloudy_outlined,
    'alerts' => Icons.warning_amber_rounded,
    'emergency' => Icons.campaign_outlined,
    'fire' => Icons.local_fire_department_outlined,
    'earthquakes' => Icons.vibration,
    'hydrology' => Icons.water_outlined,
    'avalanche' => Icons.ac_unit,
    'roads' => Icons.add_road,
    'traffic' => Icons.traffic_outlined,
    'space-weather' => Icons.wb_sunny_outlined,
    _ => Icons.sensors,
  };
}
