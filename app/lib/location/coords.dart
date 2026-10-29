// Latitude and longitude as plain text: decimal and degrees-minutes-seconds (docs/PLAN.md, Coordinates).

/// "42.53612, -113.79245" (five decimals is about a metre).
String formatDecimal(double lat, double lon) => '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';

/// "Pin 42.54, -113.79": the name of a dropped pin, which reads as one place in a list of names.
String pinName(double lat, double lon) => 'Pin ${lat.toStringAsFixed(2)}, ${lon.toStringAsFixed(2)}';

String _dms(double value, String positive, String negative) {
  final hemisphere = value < 0 ? negative : positive;
  final a = value.abs();
  // Work in whole tenths of a second so rounding carries into minutes and degrees (59.96" must not print 60.0").
  var tenths = (a * 3600 * 10).round();
  final deg = tenths ~/ 36000;
  tenths -= deg * 36000;
  final min = tenths ~/ 600;
  tenths -= min * 600;
  final sec = tenths / 10;
  return '$deg°$min\'${sec.toStringAsFixed(1)}"$hemisphere';
}

/// `42°32'10.0"N 113°47'33.0"W`
String formatDms(double lat, double lon) => '${_dms(lat, 'N', 'S')} ${_dms(lon, 'E', 'W')}';
