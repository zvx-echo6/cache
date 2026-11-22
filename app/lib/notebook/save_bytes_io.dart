import 'dart:typed_data';

/// Only a browser saves bytes this way.
void saveBytesInBrowser(String name, String mime, Uint8List bytes, {bool inTab = false}) =>
    throw UnsupportedError('Saving a file this way needs a browser');
