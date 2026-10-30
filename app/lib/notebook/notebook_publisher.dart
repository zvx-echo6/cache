import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../actions/action_registry.dart';
import '../actions/notebook_actions.dart';
import 'notebook_model.dart';
import 'notebook_state.dart';
import 'notebook_text.dart';

/// The generator's input for [log] (notebook_actions.py): the template object (visible fields only) with the last entry in local
/// time, `{"date","time","values":{label: value}}`, or null. Private logs are passed like the rest: the app never marks a log
/// locked (build note, 2026-10-30).
Map<String, dynamic> generatorInput(Notebook log) {
  final fields = log.def.visible;
  final e = log.lastEntry;
  return {
    'name': log.name,
    'fields': [for (final f in fields) f.toTemplate()],
    'private': log.private,
    'last_entry': e == null
        ? null
        : {
            'date': e.occurredAt.substring(0, 10),
            'time': e.occurredAt.substring(11, 16),
            'values': {for (final f in fields) if (f.fid != null && e.values[f.fid] != null) f.label: e.values[f.fid]},
          },
  };
}

/// Publishes the Notebooks' act actions (`notebook.add_journal_entry`, which writes to the Journal notebook, and one
/// `notebook.log_<slug>` per Log notebook, most recently used first, at most 8) whenever what the generator would make changes.
/// A chat installs the set when its conversation starts and keeps it through it, so a change shows up in the next conversation;
/// a tap always writes to the log as it is then.
class NotebookPublisher {
  NotebookPublisher({required this.registry, required this.notebook, DateTime Function()? now}) : now = now ?? DateTime.now;

  final ActionRegistry registry;
  final NotebookState notebook;
  final DateTime Function() now;

  String? _published;

  /// Publishes now and again whenever the logs change.
  void start() {
    notebook.addListener(publish);
    publish();
  }

  void dispose() => notebook.removeListener(publish);

  void publish() {
    if (notebook.loading || notebook.error != null) return;
    final logs = notebook.logs;

    final inputs = [for (final l in logs) generatorInput(l)];
    final defs = notebookActions(inputs);
    final text = jsonEncode(defs);
    if (text == _published) return;
    _published = text;
    final handlers = <String, ActionHandler>{'notebook.add_journal_entry': _addJournal};
    final lines = <String, CardLines>{'notebook.add_journal_entry': _journalLines};
    // defs[1..] are the first logs in order (none is left out: the app never marks one locked).
    for (var i = 1; i < defs.length; i++) {
      final log = logs[i - 1];
      final snapshot = _Snapshot(log, inputs[i - 1]);
      handlers[defs[i]['id'] as String] = (f) => _addToLog(snapshot, f);
      lines[defs[i]['id'] as String] = (f, summary) => _logLines(snapshot, f, summary);
    }
    final rejected = registry.publish('notebook', defs, handlers, cardLines: lines);
    if (rejected.isNotEmpty) debugPrint('cache notebook: actions rejected $rejected');
  }

  // ---- notebook.add_journal_entry ----

  Future<Map<String, dynamic>> _addJournal(Map<String, dynamic> f) async {
    final text = f['text'] is String ? (f['text'] as String).trim() : '';
    if (text.isEmpty) throw const ActionFailure('bad_fields', 'The entry has no text.');
    final title = f['title'] is String && (f['title'] as String).trim().isNotEmpty ? (f['title'] as String).trim() : null;
    try {
      // The Journal: the most recently used notebook of that template; made again when the user deleted it.
      final journal = notebook.journal ??
          await notebook.saveNotebook(
            template: 'journal',
            def: const NotebookDef(name: 'Journal', fields: [], sort: NotebookSort.date),
          );
      await notebook.saveEntry(notebookId: journal.id, occurredAt: isoLocal(now()), title: title, body: text, place: _place(f['place']));
    } catch (e) {
      throw ActionFailure('failed', 'Not saved: $e');
    }
    return {'saved': true, 'title': title};
  }

  List<MapEntry<String, String>> _journalLines(Map<String, dynamic> f, List<MapEntry<String, String>> summary) {
    final text = f['text'] is String ? (f['text'] as String).trim() : '';
    return [
      if (f['title'] is String && (f['title'] as String).trim().isNotEmpty) MapEntry('Title', (f['title'] as String).trim()),
      MapEntry('Text', text.length > 120 ? '${text.substring(0, 120)}…' : text),
      if (_summary(summary, 'place') case final p?) MapEntry('Place', p),
    ];
  }

  // ---- notebook.log_<slug> ----

  Future<Map<String, dynamic>> _addToLog(_Snapshot s, Map<String, dynamic> f) async {
    final log = notebook.notebook(s.logId);
    if (log == null) throw const ActionFailure('not_found', 'That log is no longer in Notebooks.');
    final values = <String, dynamic>{};
    final shown = <String, String>{};
    for (final (fid, name) in s.fields) {
      final field = fid == null ? null : log.def.field(fid);
      if (field == null || field.hidden || !f.containsKey(name)) continue;
      final v = _value(field, f[name]);
      if (v == null) continue;
      values[fid!] = v;
      shown[field.label] = valueText(field, v);
    }
    final when = _when(f['date'], f['time']);
    final notes = f['notes'] is String && (f['notes'] as String).trim().isNotEmpty ? (f['notes'] as String).trim() : null;
    try {
      await notebook.saveEntry(
        notebookId: log.id,
        occurredAt: isoLocal(when),
        values: values,
        body: notes,
        place: s.placeExtra ? _place(f['place']) : null,
      );
    } catch (e) {
      throw ActionFailure('failed', 'Not saved: $e');
    }
    String two(int n) => n.toString().padLeft(2, '0');
    return {
      'saved': true,
      'log': log.name,
      'when': '${when.year}-${two(when.month)}-${two(when.day)}T${two(when.hour)}:${two(when.minute)}',
      'values': shown,
    };
  }

  List<MapEntry<String, String>> _logLines(_Snapshot s, Map<String, dynamic> f, List<MapEntry<String, String>> summary) {
    final log = notebook.notebook(s.logId);
    final out = <MapEntry<String, String>>[];
    for (final (fid, name) in s.fields) {
      final field = fid == null ? null : log?.def.field(fid);
      if (field == null || !f.containsKey(name)) continue;
      final v = field.type == FieldType.place ? _summary(summary, name) : valueText(field, _value(field, f[name]));
      if (v != null && v.isNotEmpty) out.add(MapEntry(field.label, v));
    }
    final given = f['date'] != null || f['time'] != null;
    final when = _when(f['date'], f['time']);
    out.add(MapEntry('When', given ? dayTimeText(when, now: now()) : 'Now · ${dayTimeText(when, now: now())}'));
    if (s.placeExtra) {
      if (_summary(summary, 'place') case final p?) out.add(MapEntry('Place', p));
    }
    if (f['notes'] is String && (f['notes'] as String).trim().isNotEmpty) out.add(MapEntry('Notes', (f['notes'] as String).trim()));
    return out;
  }

  // ---- values ----

  static String? _summary(List<MapEntry<String, String>> summary, String key) {
    for (final e in summary) {
      if (e.key == key && e.value.trim().isNotEmpty) return e.value;
    }
    return null;
  }

  static NbPlace? _place(Object? v) {
    if (v is! Map || v['lat'] is! num || v['lon'] is! num) return null;
    final name = v['name'] is String ? v['name'] as String : (v['label'] is String ? v['label'] as String : null);
    return NbPlace(lat: (v['lat'] as num).toDouble(), lon: (v['lon'] as num).toDouble(), label: name);
  }

  /// A value as the action carries it, as the log field stores it; null when it does not fit.
  static Object? _value(LogField f, Object? v) => switch (f.type) {
        FieldType.number => v is num ? (v is double && v == v.truncateToDouble() && v.abs() < 1e15 ? v.toInt() : v) : null,
        FieldType.yesNo => v is bool ? v : null,
        FieldType.text || FieldType.choice => v is String && v.trim().isNotEmpty ? v.trim() : null,
        FieldType.place => _place(v)?.toJson(),
        FieldType.photo => null,
      };

  /// When = `date` + `time` (local), each defaulting to now's.
  DateTime _when(Object? date, Object? time) {
    final n = now();
    var t = DateTime(n.year, n.month, n.day, n.hour, n.minute);
    if (date is String && date.length == 10) {
      final d = DateTime.tryParse(date);
      if (d != null) t = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    }
    if (time is String && time.length >= 5) {
      final h = int.tryParse(time.substring(0, 2)), m = int.tryParse(time.substring(3, 5));
      if (h != null && m != null) t = DateTime(t.year, t.month, t.day, h, m);
    }
    return t;
  }
}

/// What the model was shown of a log when its conversation started: the log's id, each action field name with the field id it
/// stands for, and whether the action has its own place.
class _Snapshot {
  _Snapshot(Notebook log, Map<String, dynamic> input)
      : logId = log.id,
        placeExtra = notebookHasPlaceExtra(input),
        fields = _names(log, input);

  static List<(String?, String)> _names(Notebook log, Map<String, dynamic> input) {
    final names = notebookFieldNames(input);
    final visible = log.def.visible;
    return [for (var i = 0; i < names.length; i++) if (names[i] != null) (visible[i].fid, names[i]!)];
  }

  final String logId;
  final bool placeExtra;
  final List<(String?, String)> fields;
}
