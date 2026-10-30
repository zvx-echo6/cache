/// The Notebook's actions for the act tool, made from the user's logs: a port of the training harness's notebook_actions.py, rule
/// for rule, so the app and the captures publish the same bytes from the same logs. The Notebook module is not built yet, so
/// nothing publishes these until it is.
///
/// Input: the logs in the order the app wants them listed (most recently used first), each a template object as the app stores it
/// (`{"name", "fields":[{"label","type","unit"?,"choices"?}], "private", "last_entry"?}`) plus `"locked": true` for a private log
/// that is locked right now (left out). The journal is always first; at most 8 logs follow, the first 8 unlocked ones.
///
/// Lengths and cuts count Unicode code points, as Python does.
library;

const int _maxId = 48;
const int _maxTitle = 40;
const int _maxDescription = 120;
const int _maxFieldName = 32;
const int _maxFields = 10;
const int _maxLogs = 8;
const int _textMax = 500;
const String _prefix = 'notebook.log_';

const Map<String, dynamic> kJournalAction = {
  'id': 'notebook.add_journal_entry',
  'module': 'notebook',
  'title': 'Add a journal entry',
  'description': "Write an entry in the user's Notebook journal.",
  'effect': 'change',
  'fields': {
    'text': {'type': 'string', 'maxLength': 4000},
    'title': {'type': 'string', 'maxLength': 80},
    'place': {'type': 'place'},
  },
  'required': ['text'],
};

const List<(String, Map<String, dynamic>)> _extras = [
  ('place', {'type': 'place'}),
  ('date', {'type': 'date'}),
  ('time', {'type': 'time'}),
  ('notes', {'type': 'string', 'maxLength': _textMax}),
];

int _len(String s) => s.runes.length;

/// The first [n] code points of [s] (Python's s[:n]).
String _cut(String s, int n) => n <= 0 ? '' : String.fromCharCodes(s.runes.take(n));

// Python's str.isspace() characters, for split() and rstrip().
final _space = RegExp('[\t\n\x0b\x0c\r\x1c-\x1f \x85\xa0  -     　]');
final _spaces = RegExp('${_space.pattern}+');

String _rstrip(String s) {
  var end = s.length;
  while (end > 0 && _space.hasMatch(s[end - 1])) {
    end--;
  }
  return s.substring(0, end);
}

String _stripUnderscores(String s) {
  var a = 0, b = s.length;
  while (a < b && s[a] == '_') {
    a++;
  }
  while (b > a && s[b - 1] == '_') {
    b--;
  }
  return s.substring(a, b);
}

final _notSlug = RegExp('[^a-z0-9]+');

/// Lowercase; every run outside a-z 0-9 becomes "_"; "_" trimmed; cut to [limit] and trimmed again; [empty] when nothing is left.
String notebookSlug(String s, int limit, String empty) {
  final t = _stripUnderscores(_cut(_stripUnderscores(s.toLowerCase().replaceAll(_notSlug, '_')), limit));
  return t.isEmpty ? empty : t;
}

String _unique(String name, Set<String> taken, int limit) {
  if (!taken.contains(name)) return name;
  for (var i = 2;; i++) {
    final suffix = '_$i';
    var head = _cut(name, limit - _len(suffix));
    while (head.endsWith('_')) {
      head = head.substring(0, head.length - 1);
    }
    final candidate = head + suffix;
    if (!taken.contains(candidate)) return candidate;
  }
}

bool _enumOk(Object? choices) {
  if (choices is! List || choices.isEmpty) return false;
  final seen = <String>{};
  for (final c in choices) {
    if (c is! String || c.isEmpty || c.contains('|') || c.contains('\n') || c.contains('\r') || _len(c) > _textMax || !seen.add(c)) return false;
  }
  return true;
}

Map<String, dynamic>? _fieldSpec(Map f) => switch (f['type']) {
      'text' => {'type': 'string', 'maxLength': _textMax},
      'number' => {'type': 'number'},
      'yes_no' => {'type': 'boolean'},
      'choice' => _enumOk(f['choices'])
          ? {'type': 'string', 'maxLength': _textMax, 'enum': List<String>.from(f['choices'] as List)}
          : {'type': 'string', 'maxLength': _textMax},
      'place' => {'type': 'place'},
      _ => null, // photo, or a type this version does not know
    };

/// A number as Python writes it: whole numbers without a fraction, others in their shortest round-trip form (repr).
String? notebookNumber(Object? v) {
  if (v is int) return '$v';
  if (v is! double) return null;
  if (v.isFinite && v == v.truncateToDouble()) return BigInt.from(v).toString();
  if (!v.isFinite) return v.isNaN ? 'nan' : (v > 0 ? 'inf' : '-inf');
  // Dart's shortest digits, laid out with Python's rule: exponent form below 1e-4 or from 1e16.
  final sign = v < 0 ? '-' : '';
  final s = v.abs().toString();
  final e = s.indexOf('e');
  final mantissa = e < 0 ? s : s.substring(0, e);
  var exp = e < 0 ? 0 : int.parse(s.substring(e + 1));
  final dot = mantissa.indexOf('.');
  final intPart = dot < 0 ? mantissa : mantissa.substring(0, dot);
  final fracPart = dot < 0 ? '' : mantissa.substring(dot + 1);
  var digits = intPart + fracPart;
  exp += intPart.length - 1; // value = d.ddd x 10^exp, before leading zeros are dropped
  final lead = digits.length - digits.replaceFirst(RegExp('^0+'), '').length;
  digits = digits.substring(lead);
  exp -= lead;
  digits = digits.replaceFirst(RegExp(r'0+$'), '');
  if (digits.isEmpty) digits = '0';
  if (exp < -4 || exp >= 16) {
    final m = digits.length > 1 ? '${digits[0]}.${digits.substring(1)}' : digits;
    final x = exp.abs().toString().padLeft(2, '0');
    return '$sign${m}e${exp < 0 ? '-' : '+'}$x';
  }
  if (exp < 0) return '${sign}0.${'0' * (-exp - 1)}$digits';
  final whole = digits.length > exp + 1 ? digits.substring(0, exp + 1) : digits.padRight(exp + 1, '0');
  final frac = digits.length > exp + 1 ? digits.substring(exp + 1) : '0';
  return '$sign$whole.$frac';
}

String? _mainValue(Map log, Map entry) {
  final values = entry['values'] is Map ? entry['values'] as Map : const {};
  final fields = log['fields'] is List ? log['fields'] as List : const [];
  for (final f in fields) {
    if (f is Map && f['type'] == 'number') {
      final n = notebookNumber(values[f['label']]);
      if (n != null) {
        final unit = f['unit'];
        return '${f['label']} $n${unit is String && unit.isNotEmpty ? ' $unit' : ''}';
      }
    }
  }
  for (final f in fields) {
    if (f is Map && f['type'] == 'text') {
      final v = values[f['label']];
      if (v is String) {
        final t = v.split(_spaces).where((w) => w.isNotEmpty).join(' ');
        if (t.isNotEmpty) return '${f['label']} $t';
      }
    }
  }
  return null;
}

String _description(Map log) {
  var name = log['name'] as String;
  final entry = log['last_entry'];
  String? main;
  String tail;
  final has = entry is Map && entry.isNotEmpty;
  if (!has) {
    tail = ' No entries yet.';
  } else {
    main = _mainValue(log, entry);
    tail = ' Last: ${entry['date']} ${entry['time']}';
  }
  String base(String n) => "Add an entry to the user's $n log.";
  if (main != null) {
    final room = _maxDescription - _len(base(name)) - _len(tail) - _len(', .');
    main = room > 0 ? _rstrip(_cut(main, room)) : '';
    tail = tail + (main.isNotEmpty ? ', $main.' : '.');
  } else if (has) {
    tail = '$tail.';
  }
  final over = _len(base(name)) + _len(tail) - _maxDescription;
  if (over > 0) {
    final keep = _len(name) - over;
    name = _rstrip(_cut(name, keep < 0 ? 0 : keep));
  }
  return _cut(base(name) + tail, _maxDescription);
}

Map<String, dynamic> _logAction(Map log, Set<String> takenIds) {
  final name = log['name'] as String;
  final id = _unique(_prefix + notebookSlug(name, _maxId - _len(_prefix), 'log'), takenIds, _maxId);
  takenIds.add(id);

  final own = <(String, Map<String, dynamic>)>[];
  final names = <String>{};
  for (final f in log['fields'] is List ? log['fields'] as List : const []) {
    if (f is! Map) continue;
    final spec = _fieldSpec(f);
    if (spec == null) continue;
    var fname = notebookSlug(f['label'] is String ? f['label'] as String : '', _maxFieldName, 'field');
    final unit = f['unit'];
    final unitSlug = notebookSlug(unit is String ? unit : '', _maxFieldName, '');
    // The unit is left off when the label's last word already starts with it ("Gallons", unit gal).
    if (f['type'] == 'number' && unitSlug.isNotEmpty && !fname.split('_').last.startsWith(unitSlug)) {
      fname = notebookSlug('${fname}_$unitSlug', _maxFieldName, 'field');
    }
    fname = _unique(fname, names, _maxFieldName);
    names.add(fname);
    own.add((fname, spec));
  }
  final extras = [for (final e in _extras) if (!names.contains(e.$1)) e];
  final kept = own.take(_maxFields - extras.length);
  return {
    'id': id,
    'module': 'notebook',
    'title': _cut('Add to $name', _maxTitle),
    'description': _description(log),
    'effect': 'change',
    'fields': {for (final (n, s) in [...kept, ...extras]) n: s},
    'required': <String>[],
  };
}

/// The Notebook's definitions for [logs]: the journal, then one action per unlocked log, at most 8.
List<Map<String, dynamic>> notebookActions(List<Map<String, dynamic>> logs) {
  final out = <Map<String, dynamic>>[kJournalAction];
  final taken = {kJournalAction['id'] as String};
  for (final log in logs) {
    if (log['locked'] == true) continue;
    if (out.length - 1 == _maxLogs) break;
    out.add(_logAction(log, taken));
  }
  return out;
}
