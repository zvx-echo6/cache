import 'dart:convert';
import 'dart:io';

/// The training harness's exact bytes (test/fixtures/parity, copied from the harness's parity folder with its MANIFEST.json): what
/// the model saw in the recordings, which the app must produce byte for byte.
String parityText(String name) => File('test/fixtures/parity/$name').readAsStringSync();

dynamic parityJson(String name) => jsonDecode(parityText(name));
