import 'dart:convert';
import 'dart:typed_data';

// How core calls travel as JSON between the browser and Cache Server's helper. JSON has no byte arrays, so a Uint8List
// anywhere in an argument or a result becomes `{"$bytes": "<base64>"}` and is turned back into a Uint8List at the other end.
// The phone's isolate passes Dart objects directly and never uses this.

const _key = r'$bytes';

/// [v] with every Uint8List replaced by its `{"$bytes": ...}` form, ready for jsonEncode.
Object? wireEncode(Object? v) {
  if (v is Uint8List) return {_key: base64Encode(v)};
  if (v is Map) return {for (final e in v.entries) e.key as String: wireEncode(e.value)};
  if (v is List) return [for (final x in v) wireEncode(x)];
  return v;
}

/// [v] (from jsonDecode) with every `{"$bytes": ...}` turned back into a Uint8List.
Object? wireDecode(Object? v) {
  if (v is Map) {
    if (v.length == 1 && v[_key] is String) return base64Decode(v[_key] as String);
    return {for (final e in v.entries) e.key as String: wireDecode(e.value)};
  }
  if (v is List) return [for (final x in v) wireDecode(x)];
  return v;
}
