import 'device_api.dart';

/// The browser's way to read a catalogue: through this device (Cache Server reads it and hands the answer on), because a page may not
/// read other sites itself. Set once at start in a browser; null everywhere else, where the app reads the network directly.
DeviceApi? deviceFetchApi;
