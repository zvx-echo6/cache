import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show TextEditingValue, TextSelection;

import '../net/fetch.dart' as net;
import 'catalogue.dart' show isAllowedAddress;

/// A source of your own (Settings > Weather and alerts > More sources > Add your own source): a web service that answers with
/// JSON, plugged in by the person. What the form makes is a normal source definition (the same format as every published source,
/// see packages/cache_search/DESIGN.md "Live sources"), kept in the "Your own" collection on the phone. Nothing here is a format
/// of its own: the form is read back from the definition it wrote.

/// How often a source of your own is checked, in minutes: the choices of the form.
const List<int> kOwnRefreshChoices = [15, 30, 60, 360];

/// The default choice.
const int kOwnRefreshDefault = 30;

/// "15 minutes", "1 hour": a choice of [kOwnRefreshChoices] as the form says it.
String ownRefreshWords(int minutes) => switch (minutes) {
  60 => '1 hour',
  final m when m % 60 == 0 => '${m ~/ 60} hours',
  final m => '$m minutes',
};

/// The place's latitude and longitude, as the Latitude and Longitude buttons put them in the address (the core fills them in for
/// each place weather watches).
const String kLatPlaceholder = '{lat}';
const String kLonPlaceholder = '{lon}';

/// Where the key goes in the address that is kept: the key itself never is.
const String kKeyPlaceholder = '{api_key}';

/// Ids of the sources the form makes start with this.
const String kOwnIdPrefix = 'own-';

final RegExp _hole = RegExp(r'\{([^{}]*)\}');
final RegExp _placeHole = RegExp(r'^(lat|lon)(?::([0-8]))?$');

/// Inserts [placeholder] into the address being typed, where the cursor is (over the selected text, if any; at the end when the
/// field has no cursor yet), and leaves the cursor after it.
TextEditingValue insertPlaceholder(TextEditingValue v, String placeholder) {
  final text = v.text;
  final sel = v.selection;
  final start = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
  final end = sel.isValid ? sel.end.clamp(start, text.length) : text.length;
  final out = text.replaceRange(start, end, placeholder);
  return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: start + placeholder.length));
}

/// What the form holds: the name, the address (with `{lat}`, `{lon}` and, once kept, `{api_key}`), the key as typed and how often
/// to check. [id] is set when an existing source is edited; [savedKey] says a key is kept for it already.
class OwnDraft {
  const OwnDraft({this.name = '', this.address = '', this.key = '', this.refreshMinutes = kOwnRefreshDefault, this.id, this.savedKey = false});

  final String name;
  final String address;
  final String key;
  final int refreshMinutes;
  final String? id;
  final bool savedKey;

  /// The address as it is kept: the key, where it was typed into the address, becomes `{api_key}`.
  String get keptAddress {
    var a = address.trim();
    final k = key.trim();
    if (k.isNotEmpty && a.contains(k)) a = a.replaceAll(k, kKeyPlaceholder);
    return a;
  }

  /// The address takes the key.
  bool get needsKey => keptAddress.contains(kKeyPlaceholder);

  /// The address has the place in it: it is fetched for every place weather watches.
  bool get usesPlace => _hole.allMatches(keptAddress).any((m) => _placeHole.hasMatch(m.group(1)!));

  /// Why the form cannot be tried yet, in words, or null.
  String? problem() {
    if (name.trim().isEmpty) return 'Give the source a name.';
    final a = keptAddress;
    if (a.isEmpty) return 'Enter the web address of the service.';
    final rest = a.replaceAll(_hole, '');
    if (rest.contains('{') || rest.contains('}')) return _unknownHole;
    for (final m in _hole.allMatches(a)) {
      final h = m.group(1)!;
      if (h != 'api_key' && !_placeHole.hasMatch(h)) return _unknownHole;
    }
    final u = Uri.tryParse(fillAddress(a, lat: 0, lon: 0, key: 'k'));
    if (u == null || !isAllowedAddress(u)) return 'Enter an address that starts with https://';
    if (key.trim().isNotEmpty && !needsKey) return 'Put your key in the web address where the service asks for it.';
    if (needsKey && key.trim().isEmpty && !savedKey) return 'This address needs your key. Type it under Key.';
    return null;
  }

  static const String _unknownHole = "The address has { } in it that Cache doesn't fill in. Use the Latitude and Longitude buttons for the place.";
}

/// [address] with the place and the key filled in, as the core fills them (`{lat}` and `{lon}` with 4 decimals, `{lat:2}` with 2;
/// the key percent-encoded).
String fillAddress(String address, {required double lat, required double lon, String? key}) => address.replaceAllMapped(_hole, (m) {
  final h = m.group(1)!;
  if (h == 'api_key') return Uri.encodeComponent(key ?? '');
  final p = _placeHole.firstMatch(h);
  if (p == null) return m.group(0)!;
  final digits = p.group(2) == null ? 4 : int.parse(p.group(2)!);
  return (p.group(1) == 'lat' ? lat : lon).toStringAsFixed(digits);
});

// ------------------------------------------------------------------------------------------------ the values in an answer

/// One value found in the answer: where it is (a path the definition format reads: `water.level`, `[0].flux`), a name for people
/// made from its key, and the value as text.
class OwnValue {
  const OwnValue({required this.path, required this.label, required this.value});

  final String path;
  final String label;
  final String value;
}

/// Every value in [json], in the order of the answer: objects are walked into, a list gives its first element (`[0]`), empty values
/// are left out. A key the definition format cannot address (with a dot or a bracket in it, or starting with `^` or `@`) is left
/// out with what is under it. At most [max] values.
List<OwnValue> flattenJson(Object? json, {int max = 200}) {
  final out = <OwnValue>[];
  void walk(Object? v, String at, String? name) {
    if (out.length >= max) return;
    if (v is Map) {
      for (final e in v.entries) {
        final k = '${e.key}';
        if (!_addressable(k)) continue;
        walk(e.value, at.isEmpty ? k : '$at.$k', k);
      }
    } else if (v is List) {
      if (v.isNotEmpty) walk(v.first, '$at[0]', name);
    } else if (v != null) {
      final text = valueText(v);
      if (text.isEmpty) return;
      out.add(OwnValue(path: at.isEmpty ? '^' : at, label: labelFromKey(name ?? ''), value: text));
    }
  }

  walk(json, '', null);
  return out;
}

bool _addressable(String k) => k.isNotEmpty && !k.contains('.') && !k.contains('[') && !k.contains(']') && !k.startsWith('^') && !k.startsWith('@');

/// A value as the core writes it: text on one line (cut at 80 characters here), a whole number without ".0", true or false.
String valueText(Object v) {
  if (v is num) return v == v.truncate() && v.abs() < 1e15 ? '${v.truncate()}' : '$v';
  final s = '$v'.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

/// A readable name from a key: `waterLevel`, `water_level` and `water-level` give "Water level"; a word in capitals stays so
/// (`pm25_AQI` gives "Pm25 AQI").
String labelFromKey(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_\-\s]+'), ' ')
      .trim();
  if (spaced.isEmpty) return 'Value';
  final words = [for (final w in spaced.split(' ')) w.length > 1 && w == w.toUpperCase() && w.contains(RegExp('[A-Z]')) ? w : w.toLowerCase()];
  final first = words.first;
  words[0] = '${first[0].toUpperCase()}${first.substring(1)}';
  return words.join(' ');
}

/// Where the answer says where it is: a latitude and a longitude next to each other (`lat`/`latitude` and `lon`/`lng`/`long`/
/// `longitude` under the same parent), as numbers in range. The definition then gives its item that point.
({String lat, String lon})? findPoint(List<OwnValue> values) {
  String parent(String p) => p.contains('.') ? p.substring(0, p.lastIndexOf('.')) : '';
  String last(String p) => (p.contains('.') ? p.substring(p.lastIndexOf('.') + 1) : p).replaceAll(RegExp(r'\[\d+\]$'), '').toLowerCase();
  double? n(String v) => double.tryParse(v);
  for (final a in values) {
    if (!const {'lat', 'latitude'}.contains(last(a.path))) continue;
    final la = n(a.value);
    if (la == null || la.abs() > 90) continue;
    for (final b in values) {
      if (parent(b.path) != parent(a.path) || !const {'lon', 'lng', 'long', 'longitude'}.contains(last(b.path))) continue;
      final lo = n(b.value);
      if (lo != null && lo.abs() <= 180) return (lat: a.path, lon: b.path);
    }
  }
  return null;
}

// ------------------------------------------------------------------------------------------------ trying the address

/// Why trying the address did not give values.
enum OwnTryFailure { offline, status, notJson, timedOut, unreachable, insecure, tooLarge, notAllowed, empty, unreadable }

/// What one try of the address gave: the values found, or why there are none.
class OwnTry {
  const OwnTry.ok(this.host, this.values) : failure = null, status = null;
  const OwnTry.failed(this.host, OwnTryFailure this.failure, {this.status}) : values = const [];

  final String host;
  final List<OwnValue> values;
  final OwnTryFailure? failure;

  /// The HTTP status of [OwnTryFailure.status].
  final int? status;

  bool get ok => failure == null;

  /// Why it failed, in one plain sentence.
  String get words => switch (failure) {
    null => 'It answered. Here is what came back.',
    OwnTryFailure.offline => 'No connection. Connect to the internet and try again.',
    OwnTryFailure.status => '$host answered with an error (HTTP $status).',
    OwnTryFailure.notJson => '$host answered, but not with JSON. This version of Cache only reads JSON.',
    OwnTryFailure.timedOut => "$host didn't answer in time.",
    OwnTryFailure.unreachable => "Couldn't reach $host. Check the address and your connection.",
    OwnTryFailure.insecure => "Couldn't make a secure connection to $host.",
    OwnTryFailure.tooLarge => 'The answer is too large for Cache to read.',
    OwnTryFailure.notAllowed => 'Enter an address that starts with https://',
    OwnTryFailure.empty => '$host answered, but there are no values in it.',
    OwnTryFailure.unreadable => "Couldn't read the answer from $host.",
  };
}

/// Reads an address for a try: the body, or a [net.FetchException].
typedef OwnFetch = Future<List<int>> Function(Uri url, Duration timeout);

/// The real read (net/fetch.dart: https or this phone, the app's User-Agent, at most 4 MB).
Future<List<int>> fetchOwnAddress(Uri url, Duration timeout) => net.fetchBytes(url, timeout: timeout);

/// Fetches [url] once and finds the values in its JSON answer. Nothing is kept.
Future<OwnTry> tryOwnAddress(Uri url, {OwnFetch fetch = fetchOwnAddress, Duration timeout = const Duration(seconds: 20)}) async {
  final host = url.host;
  final List<int> bytes;
  try {
    bytes = await fetch(url, timeout);
  } on net.FetchException catch (e) {
    return OwnTry.failed(host, switch (e.failure) {
      net.FetchFailure.notAllowed => OwnTryFailure.notAllowed,
      net.FetchFailure.unreachable => OwnTryFailure.unreachable,
      net.FetchFailure.timedOut => OwnTryFailure.timedOut,
      net.FetchFailure.insecure => OwnTryFailure.insecure,
      net.FetchFailure.status => OwnTryFailure.status,
      net.FetchFailure.tooLarge => OwnTryFailure.tooLarge,
      net.FetchFailure.unreadable => OwnTryFailure.unreadable,
    }, status: e.status);
  } on TimeoutException {
    return OwnTry.failed(host, OwnTryFailure.timedOut);
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes, allowMalformed: true).replaceFirst('\u{feff}', ''));
  } on FormatException {
    return OwnTry.failed(host, OwnTryFailure.notJson);
  }
  final values = flattenJson(json);
  if (values.isEmpty) return OwnTry.failed(host, OwnTryFailure.empty);
  return OwnTry.ok(host, values);
}

// ------------------------------------------------------------------------------------------------ the definition

/// One ticked value: where it is and the name it is shown with.
class OwnPick {
  const OwnPick(this.path, this.label);

  final String path;
  final String label;
}

/// The names [picks] are shown with, each once: braces are taken out (the definition's template uses them) and a name used twice
/// gets " 2", " 3".
List<OwnPick> tidyPicks(List<OwnPick> picks) {
  final seen = <String>{};
  return [
    for (final p in picks)
      () {
        var base = p.label.replaceAll(RegExp(r'[{}]'), '').trim();
        if (base.isEmpty) base = 'Value';
        var name = base;
        for (var n = 2; !seen.add(name.toLowerCase()); n++) {
          name = '$base $n';
        }
        return OwnPick(p.path, name);
      }(),
  ];
}

/// The host of [address] (the provider of a source of your own).
String ownHost(String address) => Uri.tryParse(fillAddress(address, lat: 0, lon: 0, key: 'k'))?.host ?? '';

/// The id for a new source called [name]: `own-` and the name in lower case, made unique against [taken].
String ownIdFor(String name, Set<String> taken) {
  var slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) slug = 'source';
  if (slug.length > 50) slug = slug.substring(0, 50).replaceAll(RegExp(r'-+$'), '');
  var id = '$kOwnIdPrefix$slug';
  for (var n = 2; taken.contains(id); n++) {
    id = '$kOwnIdPrefix$slug-$n';
  }
  return id;
}

/// The definition the form saves, in the format of every other source (format 2): one item from the answer's root whose label is
/// the first ticked value ("Water level 1.42", the source's name when that value is missing) and whose fields are the others; the
/// key, when the address takes one, referenced by its alias as published keyed sources do (`api_key`), never written in; the item
/// placed where the answer says, when it gives a latitude and longitude ([point]).
String buildOwnDefinition({required String id, required OwnDraft draft, required List<OwnPick> picks, ({String lat, String lon})? point}) {
  final ticked = tidyPicks(picks);
  if (ticked.isEmpty) throw ArgumentError('nothing ticked');
  final host = ownHost(draft.keptAddress);
  final name = draft.name.trim();
  final labels = [for (final p in ticked) p.label];
  final listed = labels.length <= 4 ? labels : [...labels.take(3), 'more'];
  final what = listed.length == 1 ? listed.single : '${listed.sublist(0, listed.length - 1).join(', ')} and ${listed.last}';
  final refresh = draft.refreshMinutes;
  final hours = refresh * 3 / 60;
  final first = ticked.first;
  final def = <String, Object?>{
    'format': 2,
    'id': id,
    'title': name,
    'provider': host,
    'description': '$what from $host (a source added on this device)',
    'attribution': 'Data from $host',
    'request': {'url': draft.keptAddress},
    if (draft.needsKey) 'api_key': {'alias': id, 'required': true},
    'refresh_minutes': refresh,
    'quota': {'per_minute': 10, 'per_day': 2000},
    'validity': {'fixed_hours': hours < 1 ? 1.0 : hours},
    'require': [first.path],
    'items': [
      {
        'key': {'const': 'now'},
        'label': {
          'first_of': [
            {
              'template': '${first.label} {v}',
              'vars': {
                'v': {'path': first.path},
              },
            },
            {'const': name},
          ],
        },
        if (point != null)
          'point': {
            'lat': {'path': point.lat},
            'lon': {'path': point.lon},
          },
        'fields': [
          for (final p in ticked.skip(1)) {'label': p.label, 'path': p.path},
        ],
      },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(def);
}

/// The form and the ticked values back from a definition [buildOwnDefinition] wrote, to edit it; null for any other definition
/// (an imported one), which can be switched and removed but not edited here.
({OwnDraft draft, List<OwnPick> picks})? readOwnDefinition(Map<String, dynamic> def) {
  try {
    final id = def['id'] as String;
    if (!id.startsWith(kOwnIdPrefix)) return null;
    final url = (def['request'] as Map)['url'] as String;
    final items = def['items'] as List;
    if (items.length != 1) return null;
    final item = items.single as Map;
    final firstOf = (item['label'] as Map)['first_of'] as List;
    final tpl = firstOf.first as Map;
    final template = tpl['template'] as String;
    if (!template.endsWith(' {v}')) return null;
    final picks = [
      OwnPick(((tpl['vars'] as Map)['v'] as Map)['path'] as String, template.substring(0, template.length - 4)),
      for (final f in item['fields'] as List) OwnPick((f as Map)['path'] as String, f['label'] as String),
    ];
    return (
      draft: OwnDraft(name: def['title'] as String, address: url, refreshMinutes: (def['refresh_minutes'] as num).toInt(), id: id, savedKey: def['api_key'] != null),
      picks: picks,
    );
  } catch (_) {
    return null;
  }
}
