import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../notebook_model.dart';
import 'formats.dart';

/// Notebook fields between linked devices. A record's `fields` list says what every device agrees a notebook's fields are; this file
/// is the pure part: the ids, merging two copies of the list, how a device's own fields are matched to it the first time (the
/// migration), and what a sync changes on either side (the reconcile). The engine (sync_engine.dart) reads and writes the stores.
///
/// A record field is a map: `gid`, `pname` (the key its values have in a `.cnote`, fixed at creation), and per-property values with
/// their times: `name`/`name_at`, `type`/`type_at`, `unit`/`unit_at`, `choices`/`choices_at`, `removed`/`removed_at` (and
/// `inferred`, see below), `ord`/`ord_at`. Each property goes the way of the later time, on its own.

/// The ids a field gets by rule when two devices have to come to the same one before they have talked (see [gidOfSnapshotField],
/// [gidOfLocalField]): 32 hex characters, like the ones the store makes at random, so nothing tells them apart.
String _gid(String text) => sha256.convert(utf8.encode(text)).toString().substring(0, 32);

/// A label as it is compared: trimmed, whitespace collapsed, lower case.
String normLabel(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// The id of a field of the snapshot a record was first written with (`record.def.fields`, hidden fields counted), from what the
/// record says alone: the notebook's id, the field's place in that list and its label.
String gidOfSnapshotField(String notebookId, int index, String label) => _gid('cache-field-v1\u0000snap\u0000$notebookId\u0000$index\u0000${normLabel(label)}');

/// The id of a field a device added before it migrated (it is in no snapshot): from the notebook, the label and the type, so two
/// devices that each added "Elevation" (number) come to one field. Not from the device's own field id (`f4` here is unrelated to `f4`
/// there).
///
/// Two different fields of one device never share one: a field the person took out ([hidden]) and a visible one with the same label
/// and type differ, and so do two taken out ([ordinal] counts the ones alike, in the order the device has them). A field that is
/// visible and the first of its kind (the usual one) keeps the plain form, so devices that each added it still come to one id.
String gidOfLocalField(String notebookId, String label, String type, {bool hidden = false, int ordinal = 0}) =>
    _gid('cache-field-v1\u0000local\u0000$notebookId\u0000${normLabel(label)}\u0000$type${hidden ? '\u0000hidden' : ''}${ordinal > 0 ? '\u0000$ordinal' : ''}');

/// How a notebook's field order is kept: spaced keys, sorted by `(ord, gid)`.
const double kOrdStep = 1000;

int _at(Map<String, dynamic> f, String p) => (f['${p}_at'] as num?)?.toInt() ?? 0;

String _canon(Object? v) => v == null ? '' : (v is String ? v : jsonEncode(_sorted(v)));

Object? _sorted(Object? v) => v is Map ? {for (final k in (v.keys.map((k) => '$k').toList()..sort())) k: _sorted(v[k])} : (v is List ? [for (final x in v) _sorted(x)] : v);

/// The properties of a field that have a time each.
const List<String> kFieldProps = ['name', 'type', 'unit', 'choices', 'removed', 'ord'];

/// The latest time in a list of record fields (what a build without the fix sees as the time of the whole `fields` value).
int fieldsAt(Iterable<Map<String, dynamic>> fields) {
  var m = 0;
  for (final f in fields) {
    for (final e in f.entries) {
      if (e.key.endsWith('_at') && e.value is num) m = m > (e.value as num).toInt() ? m : (e.value as num).toInt();
    }
  }
  return m;
}

List<Map<String, dynamic>> _copyFields(Object? raw) => [
      for (final f in (raw is List ? raw : const [])) if (f is Map && f['gid'] is String) {for (final e in f.entries) '${e.key}': e.value},
    ];

/// The list a record's several copies come to: fields are grouped by gid, and each property is the later writer's (a tie goes to the
/// greater value, null least), so every device picks the same. What a copy has that the others do not is kept: a field, a key. The
/// result is sorted by `(ord, gid)`.
List<Map<String, dynamic>> mergeFieldLists(Iterable<Object?> lists) {
  final byGid = <String, List<Map<String, dynamic>>>{};
  for (final l in lists) {
    for (final f in _copyFields(l)) {
      byGid.putIfAbsent(f['gid'] as String, () => []).add(f);
    }
  }
  final out = <Map<String, dynamic>>[];
  for (final e in byGid.entries) {
    final copies = e.value;
    final m = <String, dynamic>{'gid': e.key};
    for (final p in kFieldProps) {
      Map<String, dynamic>? w;
      for (final c in copies) {
        if (!c.containsKey(p) && !c.containsKey('${p}_at')) continue;
        if (w == null) {
          w = c;
          continue;
        }
        final cmp = _at(c, p).compareTo(_at(w, p));
        if (cmp > 0 || (cmp == 0 && _canon(c[p]).compareTo(_canon(w[p])) > 0)) w = c;
      }
      if (w == null) continue;
      if (w.containsKey(p)) m[p] = w[p];
      if (w.containsKey('${p}_at')) m['${p}_at'] = w['${p}_at'];
      // A removal says whether it was inferred at a migration; that goes with the removal.
      if (p == 'removed' && w.containsKey('inferred')) m['inferred'] = w['inferred'];
    }
    // what no property decides (`pname`, and keys a newer build added): the greatest value, so every device picks the same
    final known = {...kFieldProps, for (final p in kFieldProps) '${p}_at', 'gid', 'inferred'};
    for (final c in copies) {
      for (final k in c.entries) {
        if (known.contains(k.key)) continue;
        if (!m.containsKey(k.key) || _canon(k.value).compareTo(_canon(m[k.key])) > 0) m[k.key] = k.value;
      }
    }
    out.add(m);
  }
  out.sort(_byOrd);
  return out;
}

int _byOrd(Map<String, dynamic> a, Map<String, dynamic> b) {
  final c = ((a['ord'] as num?)?.toDouble() ?? 0).compareTo((b['ord'] as num?)?.toDouble() ?? 0);
  return c != 0 ? c : (a['gid'] as String).compareTo(b['gid'] as String);
}

/// What a device last applied for one field (so a change since is a change made here): its label as shown, type, unit, choices, whether
/// it was removed, and where it was.
class FieldState {
  const FieldState({required this.name, required this.type, this.unit, this.choices, this.removed = false});

  final String name;
  final String type;
  final String? unit;
  final List<String>? choices;
  final bool removed;

  Map<String, dynamic> toJson() => {'name': name, 'type': type, 'unit': ?unit, 'choices': ?choices, if (removed) 'removed': true};

  static FieldState fromJson(Map j) => FieldState(
        name: '${j['name']}',
        type: '${j['type']}',
        unit: j['unit'] as String?,
        choices: j['choices'] is List ? [for (final c in j['choices'] as List) '$c'] : null,
        removed: j['removed'] == true,
      );

  static FieldState ofLocal(LogField f) => FieldState(name: f.label, type: f.type.wire, unit: f.type == FieldType.number ? f.unit : null, choices: f.type == FieldType.choice ? f.choices : null, removed: f.hidden);

  @override
  bool operator ==(Object other) => other is FieldState && other.name == name && other.type == type && other.unit == unit && other.removed == removed && _canon(other.choices) == _canon(choices);

  @override
  int get hashCode => Object.hash(name, type, unit, removed);
}

/// What a device remembers about a notebook's fields between syncs: [state] by gid, and the order the gids were in.
///
/// [derived] are the ids this device gave its fields by rule (see [gidOfSnapshotField]); they depend on the notebook's id, so when the
/// notebook's id changes ([forId] is no longer its id) they are dropped and the fields are matched to the record again. [pending]: the
/// migration wrote the record and was setting the ids when the run stopped (or still is); the next run does it again from the start.
class FieldSnap {
  FieldSnap({Map<String, FieldState>? state, List<String>? order, this.pnames = const {}, Set<String>? derived, this.forId = '', this.pending = false})
      : state = state ?? {},
        order = order ?? [],
        derived = derived ?? {};

  final Map<String, FieldState> state;
  final List<String> order;
  final Set<String> derived;
  final String forId;
  final bool pending;

  /// The device's own property names (`.cnote` keys) from before it took the record's, by that name to the field's local id: files
  /// that still use one are read as that field.
  final Map<String, String> pnames;

  Map<String, dynamic> toJson() => {
        'state': {for (final e in state.entries) e.key: e.value.toJson()},
        'order': order,
        if (pnames.isNotEmpty) 'aliases': pnames,
        if (derived.isNotEmpty) 'derived': derived.toList()..sort(),
        if (forId.isNotEmpty) 'for': forId,
        if (pending) 'pending': true,
      };

  static FieldSnap fromJson(Map j) => FieldSnap(
        state: {for (final e in (j['state'] as Map? ?? const {}).entries) '${e.key}': FieldState.fromJson(e.value as Map)},
        order: [for (final x in (j['order'] as List? ?? const [])) '$x'],
        pnames: {for (final e in (j['aliases'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
        derived: {for (final x in (j['derived'] as List? ?? const [])) '$x'},
        forId: '${j['for'] ?? ''}',
        pending: j['pending'] == true,
      );
}

/// The record's fields made from the first-share snapshot (`record.def.fields`, with `record.props` the snapshot's property names):
/// ids by [gidOfSnapshotField], every property at time 0, so any later change wins.
///
/// A snapshot field that carries its own `gid` (one made after the field sync) keeps it; the others get the one by rule, and are
/// added to [derived] (they depend on the notebook's id).
List<Map<String, dynamic>> fieldsOfSnapshot(String notebookId, List<dynamic> snapshot, Map<dynamic, dynamic> props, {Set<String>? derived}) {
  final out = <Map<String, dynamic>>[];
  final used = <String>{};
  for (var i = 0; i < snapshot.length; i++) {
    final sf = snapshot[i];
    if (sf is! Map || sf['label'] is! String) continue;
    final label = sf['label'] as String;
    var pname = props['${sf['fid']}'] is String ? props['${sf['fid']}'] as String : propName(label, taken: used);
    if (!used.add(pname)) pname = propName(label, taken: used);
    used.add(pname);
    final own = sf['gid'];
    final ruled = gidOfSnapshotField(notebookId, i, label);
    final given = own is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(own);
    if (!given) derived?.add(ruled);
    out.add({
      'gid': given ? own : ruled,
      'pname': pname,
      'name': label,
      'type': '${sf['type']}',
      if (sf['unit'] is String) 'unit': sf['unit'],
      if (sf['choices'] is List) 'choices': sf['choices'],
      if (sf['hidden'] == true) 'removed': true,
      'ord': (i + 1) * kOrdStep,
    });
  }
  return out;
}

/// What a migration worked out for one notebook.
class FieldMigration {
  FieldMigration(this.fields);

  /// The record's fields after it: the snapshot's (or the ones already there), the device's additions, removals the device knows.
  final List<Map<String, dynamic>> fields;

  /// The gid each of the device's field ids gets (the ones that had none).
  final Map<String, String> gids = {};

  /// Property names the device wrote before (by field id) that differ from the record's: read as that field from now on.
  final Map<String, String> aliases = {};

  /// What the snapshot said about the fields that were matched, by gid: the baseline the device's own differences count against.
  final Map<String, FieldState> baseline = {};

  /// The snapshot's order, by gid, for the matched fields.
  final List<String> baselineOrder = [];

  /// The ids given by rule here (they depend on the notebook's id; see [FieldSnap.derived]).
  final Set<String> derived = {};

  final List<String> log = [];
}

/// The first time a device meets a record's fields. [snapshot] and [snapProps] are the record's first-share definition and property
/// names; [existing] the record's `fields` when another device already migrated; [local] the device's fields (hidden included);
/// [localProps] the device's property name for each of its field ids (what its files already use). Matches in this order: the
/// property name (and type), then the label (and type) when it is unique on both sides; a field that matches nothing is the device's
/// own addition. Where it cannot tell, it keeps both and says so in [FieldMigration.log].
FieldMigration migrateFields({
  required String notebookId,
  required List<dynamic> snapshot,
  required Map<dynamic, dynamic> snapProps,
  required List<Map<String, dynamic>>? existing,
  required List<LogField> local,
  required Map<String, String> localProps,
  required int now,
}) {
  final snapDerived = <String>{};
  final snapD = fieldsOfSnapshot(notebookId, snapshot, snapProps, derived: snapDerived);
  final base = existing != null ? [for (final f in existing) {...f}] : [for (final f in snapD) {...f}];
  final m = FieldMigration(base);
  final byGid = {for (final f in base) f['gid'] as String: f};
  final claimed = <String>{};
  // fields that already have an id (made after the upgrade, or migrated before) are matched by it
  final needs = [for (final f in local) if (f.gid == null || f.gid!.isEmpty) f];
  for (final f in local) {
    if (f.gid != null && f.gid!.isNotEmpty) claimed.add(f.gid!);
  }
  final matched = <String, Map<String, dynamic>>{};
  // 1. the property name bridge
  for (final lf in needs) {
    final p = localProps[lf.fid];
    if (p == null) continue;
    for (final sf in snapD) {
      final g = sf['gid'] as String;
      if (claimed.contains(g)) continue;
      if (sf['pname'] == p && sf['type'] == lf.type.wire) {
        matched[lf.fid!] = sf;
        claimed.add(g);
        break;
      }
    }
  }
  // 2. the label bridge, where the label is unique among what is left on both sides
  final leftLocal = [for (final lf in needs) if (!matched.containsKey(lf.fid)) lf];
  final leftSnap = [for (final sf in snapD) if (!claimed.contains(sf['gid'])) sf];
  for (final lf in leftLocal) {
    final k = '${normLabel(lf.label)}\u0000${lf.type.wire}';
    final ls = [for (final x in leftLocal) if ('${normLabel(x.label)}\u0000${x.type.wire}' == k) x];
    final ss = [for (final x in leftSnap) if ('${normLabel('${x['name']}')}\u0000${x['type']}' == k) x];
    if (ls.length == 1 && ss.length == 1 && !claimed.contains(ss.first['gid'])) {
      matched[lf.fid!] = ss.first;
      claimed.add(ss.first['gid'] as String);
    } else if (ls.length > 1 || ss.length > 1) {
      m.log.add('Notebook fields: "${lf.label}" is more than one field here or there; kept apart, not guessed');
    }
  }
  // what the matches say
  for (final e in matched.entries) {
    final sf = e.value;
    final g = sf['gid'] as String;
    m.gids[e.key] = g;
    if (snapDerived.contains(g)) m.derived.add(g);
    final lp = localProps[e.key];
    if (lp != null && lp != sf['pname']) m.aliases[e.key] = lp;
    m.baseline[g] = FieldState(
      name: '${sf['name']}',
      type: '${sf['type']}',
      unit: sf['unit'] as String?,
      choices: sf['choices'] is List ? [for (final c in sf['choices'] as List) '$c'] : null,
      removed: sf['removed'] == true,
    );
  }
  m.baselineOrder.addAll([for (final sf in snapD) if (m.baseline.containsKey(sf['gid'])) sf['gid'] as String]);
  // the device's own additions (in no snapshot): one id by rule, in the record
  final taken = {for (final f in base) '${f['pname']}'};
  var last = base.fold<double>(0, (a, f) => a > ((f['ord'] as num?)?.toDouble() ?? 0) ? a : ((f['ord'] as num?)?.toDouble() ?? 0));
  final alike = <String, int>{};
  for (final lf in needs) {
    if (matched.containsKey(lf.fid)) continue;
    final kind = '${normLabel(lf.label)}\u0000${lf.type.wire}\u0000${lf.hidden}';
    final ordinal = alike[kind] = (alike[kind] ?? -1) + 1;
    final g = gidOfLocalField(notebookId, lf.label, lf.type.wire, hidden: lf.hidden, ordinal: ordinal);
    m.gids[lf.fid!] = g;
    m.derived.add(g);
    if (byGid.containsKey(g)) continue;
    var pname = localProps[lf.fid] ?? propName(lf.label, taken: taken);
    // a name another field already uses: both would write one key; neither is guessed at
    if (taken.contains(pname)) {
      m.log.add('Notebook fields: "${lf.label}" shares the file key "$pname" with another field; kept apart, old values stay as they are');
      pname = '${pname}_${g.substring(0, 6)}';
    }
    taken.add(pname);
    last += kOrdStep;
    // a field taken out here is a removal that was made on purpose (the store keeps only fields with values hidden): not inferred
    final f = <String, dynamic>{
      'gid': g,
      'pname': pname,
      'name': lf.label,
      'name_at': now,
      'type': lf.type.wire,
      'type_at': now,
      if (lf.type == FieldType.number && lf.unit != null && lf.unit!.trim().isNotEmpty) ...{'unit': lf.unit, 'unit_at': now},
      if (lf.type == FieldType.choice) ...{'choices': lf.choices ?? const <String>[], 'choices_at': now},
      if (lf.hidden) ...{'removed': true, 'removed_at': now},
      'ord': last,
      'ord_at': now,
    };
    base.add(f);
    byGid[g] = f;
  }
  // a snapshot field this device never matched, and whose file key it still remembers but has no field for: it removed the field
  // before the migration; that is inferred, and carries the migration's time (not the person's)
  final localFids = {for (final f in local) f.fid};
  for (final sf in snapD) {
    final g = sf['gid'] as String;
    if (claimed.contains(g)) continue;
    final removedHere = localProps.entries.any((e) => e.value == sf['pname'] && !localFids.contains(e.key));
    final rec = byGid[g];
    if (removedHere && rec != null && rec['removed'] != true) {
      rec['removed'] = true;
      rec['removed_at'] = now;
      rec['inferred'] = true;
      m.log.add('Notebook fields: "${sf['name']}" was removed here before the migration; its removal is marked as inferred');
    }
  }
  base.sort(_byOrd);
  return m;
}

/// What a reconcile worked out.
class FieldPlan {
  FieldPlan(this.record, this.local);

  /// The record's fields after this device's changes are in (and re-assertions).
  final List<Map<String, dynamic>> record;

  /// The device's fields as they are to be: in order, hidden ones last. `fid` null for a field to be made.
  final List<LogField> local;

  /// Whether the record changed (what this device did, or a re-assertion).
  bool recordChanged = false;

  final List<String> log = [];

  /// The file key (`.cnote`) each field uses, by gid.
  final Map<String, String> pnames = {};
}

/// One sync of a notebook's fields. [record] is the merged `fields` of the record; [local] the device's fields as the store has them;
/// [snap] what the device last applied. In this order: what changed here since [snap] goes into the record (later than what it
/// says); then the record's fields go into the local list, except where the device's own values or entries decide (a removal of a
/// field that has values is not applied if it was only inferred: the field stays and the record is corrected; a type is not changed
/// under values). A removal made on this device is always a real one; only the migration infers one (a snapshot field this device
/// never had a trace of), and an inferred removal never beats values.
FieldPlan reconcileFields({
  required String notebookId,
  required List<Map<String, dynamic>> record,
  required List<LogField> local,
  required FieldSnap snap,
  required bool Function(String fid) hasValues,
  required int now,
  Map<String, String> props = const {},
}) {
  final rec = <String, Map<String, dynamic>>{for (final f in record) f['gid'] as String: {...f}};
  final plan = FieldPlan([], []);
  int bump(Map<String, dynamic> f, String p) => [now, _at(f, p) + 1].reduce((a, b) => a > b ? a : b);
  void set(Map<String, dynamic> f, String p, Object? v) {
    f[p] = v;
    f['${p}_at'] = bump(f, p);
    plan.recordChanged = true;
  }

  final localBy = {for (final f in local) if (f.gid != null && f.gid!.isNotEmpty) f.gid!: f};
  final taken = {for (final f in rec.values) '${f['pname']}'};
  // A. what changed here
  var lastOrd = rec.values.fold<double>(0, (a, f) => a > ((f['ord'] as num?)?.toDouble() ?? 0) ? a : ((f['ord'] as num?)?.toDouble() ?? 0));
  final newHere = <String>[];
  for (final lf in local) {
    final g = lf.gid;
    if (g == null || g.isEmpty) continue;
    final r = rec[g];
    final s = snap.state[g];
    if (r == null) {
      // a field made here that the record does not have yet
      var pname = props[lf.fid] ?? propName(lf.label, taken: taken);
      if (taken.contains(pname)) pname = '${propName(lf.label)}_${g.substring(0, 6)}';
      taken.add(pname);
      lastOrd += kOrdStep;
      rec[g] = {
        'gid': g,
        'pname': pname,
        'name': lf.label,
        'name_at': now,
        'type': lf.type.wire,
        'type_at': now,
        if (lf.type == FieldType.number && lf.unit != null && lf.unit!.trim().isNotEmpty) ...{'unit': lf.unit, 'unit_at': now},
        if (lf.type == FieldType.choice) ...{'choices': lf.choices ?? const <String>[], 'choices_at': now},
        if (lf.hidden) ...{'removed': true, 'removed_at': now},
        'ord': lastOrd,
        'ord_at': now,
      };
      plan.recordChanged = true;
      newHere.add(g);
      continue;
    }
    if (s == null) continue; // never applied here yet: nothing it did can be told from what it was given
    final cur = FieldState.ofLocal(lf);
    if (cur == s) continue;
    if (lf.hidden && !s.removed) {
      set(r, 'removed', true);
      r.remove('inferred');
      continue;
    }
    if (lf.hidden) continue;
    if (cur.name != s.name) set(r, 'name', cur.name);
    if (cur.type != s.type) set(r, 'type', cur.type);
    if (cur.unit != s.unit) set(r, 'unit', cur.unit);
    if (_canon(cur.choices) != _canon(s.choices)) set(r, 'choices', cur.choices);
  }
  // a field the device had and no longer has: removed here
  for (final e in snap.state.entries) {
    if (e.value.removed || localBy.containsKey(e.key)) continue;
    final r = rec[e.key];
    if (r != null && r['removed'] != true) {
      set(r, 'removed', true);
      r.remove('inferred');
    }
  }
  // order changed here: only the fields that moved get a new key
  final visibleLocal = [for (final f in local) if (!f.hidden && f.gid != null && rec[f.gid!] != null && rec[f.gid!]!['removed'] != true) f.gid!];
  final snapOrder = [for (final g in snap.order) if (visibleLocal.contains(g)) g];
  final localOrder = [for (final g in visibleLocal) if (snapOrder.contains(g)) g];
  final reordered = snapOrder.length > 1 && !_same(snapOrder, localOrder);
  if (reordered || newHere.isNotEmpty) {
    _renumber(rec, visibleLocal, newHere, reordered, now, plan);
  }
  // B. the record into the local list
  final recSorted = rec.values.toList()..sort(_byOrd);
  final desired = <LogField>[];
  final hiddenOnes = <LogField>[];
  for (final r in recSorted) {
    final g = r['gid'] as String;
    final lf = localBy[g];
    final removed = r['removed'] == true;
    if (removed) {
      if (lf == null) continue;
      if (hasValues(lf.fid!)) {
        if (r['inferred'] == true) {
          // values beat a shape that was only inferred: the field stays, and the record is told
          set(r, 'removed', false);
          r.remove('inferred');
          plan.log.add('Notebook fields: "${lf.label}" was removed on another device before the migration, but this one has values in it; it stays');
          desired.add(lf.copyWith(hidden: false));
        } else {
          hiddenOnes.add(lf.copyWith(hidden: true));
        }
      }
      continue;
    }
    var type = FieldType.byWire(r['type']) ?? lf?.type ?? FieldType.text;
    var unit = r['unit'] as String?;
    var choices = r['choices'] is List ? [for (final c in r['choices'] as List) '$c'] : null;
    if (lf != null && lf.type != type && hasValues(lf.fid!)) {
      // values beat shape: this device keeps its type and the record is corrected
      type = lf.type;
      unit = lf.type == FieldType.number ? lf.unit : null;
      choices = lf.type == FieldType.choice ? lf.choices : null;
      set(r, 'type', lf.type.wire);
      plan.log.add('Notebook fields: the type of "${lf.label}" changed on another device, but this one has values in it; it keeps its type');
    }
    desired.add(LogField(
      fid: lf?.fid,
      gid: g,
      label: '${r['name']}',
      type: type,
      unit: type == FieldType.number ? unit : null,
      choices: type == FieldType.choice ? (choices ?? const <String>[]) : null,
    ));
    plan.pnames[g] = '${r['pname']}';
  }
  // two fields with one label (added on two devices): the second, by id, shows " (2)" here and on every device; the record keeps the
  // label it has
  final seen = <String, int>{};
  final byGidOrder = [...desired]..sort((a, b) => a.gid!.compareTo(b.gid!));
  final shown = <String, String>{};
  for (final f in byGidOrder) {
    final k = normLabel(f.label);
    final n = (seen[k] = (seen[k] ?? 0) + 1);
    shown[f.gid!] = n == 1 ? f.label : '${f.label} ($n)';
  }
  plan.local.addAll([for (final f in desired) shown[f.gid!] == f.label ? f : LogField(fid: f.fid, gid: f.gid, label: shown[f.gid!]!, type: f.type, unit: f.unit, choices: f.choices)]);
  plan.local.addAll(hiddenOnes);
  // local fields the record has never heard of and that have no gid yet stay as they are (hidden last)
  for (final f in local) {
    if (f.gid == null || f.gid!.isEmpty) plan.local.add(f);
  }
  plan.record.addAll(rec.values.toList()..sort(_byOrd));
  return plan;
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Gives the fields that moved (and the ones made here) a key between their neighbours' in the order the person left them in; when
/// the gaps are too small, every key is renumbered.
void _renumber(Map<String, Map<String, dynamic>> rec, List<String> order, List<String> newHere, bool reordered, int now, FieldPlan plan) {
  double ord(String g) => (rec[g]!['ord'] as num?)?.toDouble() ?? 0;
  // the longest run that is already in order keeps its keys
  final keep = <String>{};
  if (reordered) {
    final seq = [for (final g in order) if (!newHere.contains(g)) g];
    final best = List<int>.filled(seq.length, 1);
    final prev = List<int>.filled(seq.length, -1);
    var end = -1;
    for (var i = 0; i < seq.length; i++) {
      for (var j = 0; j < i; j++) {
        final lt = ord(seq[j]) < ord(seq[i]) || (ord(seq[j]) == ord(seq[i]) && seq[j].compareTo(seq[i]) < 0);
        if (lt && best[j] + 1 > best[i]) {
          best[i] = best[j] + 1;
          prev[i] = j;
        }
      }
      if (end < 0 || best[i] > best[end]) end = i;
    }
    for (var i = end; i >= 0; i = prev[i]) {
      keep.add(seq[i]);
    }
  } else {
    keep.addAll([for (final g in order) if (!newHere.contains(g)) g]);
  }
  final moving = [for (final g in order) if (!keep.contains(g)) g];
  if (moving.isEmpty) return;
  var tooClose = false;
  final newOrd = <String, double>{};
  var i = 0;
  while (i < order.length) {
    if (keep.contains(order[i])) {
      i++;
      continue;
    }
    var j = i;
    while (j < order.length && !keep.contains(order[j])) {
      j++;
    }
    final lo = i == 0 ? null : ord(order[i - 1]);
    final hi = j == order.length ? null : ord(order[j]);
    final n = j - i;
    final from = lo ?? (hi == null ? 0.0 : hi - (n + 1) * kOrdStep);
    final to = hi ?? (lo ?? 0) + (n + 1) * kOrdStep;
    for (var k = 0; k < n; k++) {
      final v = from + (to - from) * (k + 1) / (n + 1);
      newOrd[order[i + k]] = v;
      if ((to - from) / (n + 1) < 1e-6) tooClose = true;
    }
    i = j;
  }
  if (tooClose) {
    for (var k = 0; k < order.length; k++) {
      rec[order[k]]!['ord'] = (k + 1) * kOrdStep;
      rec[order[k]]!['ord_at'] = [now, ((rec[order[k]]!['ord_at'] as num?)?.toInt() ?? 0) + 1].reduce((a, b) => a > b ? a : b);
    }
  } else {
    for (final e in newOrd.entries) {
      rec[e.key]!['ord'] = e.value;
      rec[e.key]!['ord_at'] = [now, ((rec[e.key]!['ord_at'] as num?)?.toInt() ?? 0) + 1].reduce((a, b) => a > b ? a : b);
    }
  }
  plan.recordChanged = true;
}
