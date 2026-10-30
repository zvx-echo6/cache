/// Notebooks as the core stores them (cs_notebook; cache_search.h documents the JSON): one kind of notebook, whose definition is
/// data (a name, a shape from its template, fields of six types), and one kind of entry (title, text, date, place, photos, files
/// and values by field id).
library;

/// The six field types (When, text, place, photos and files are on every entry and are not fields).
enum FieldType {
  text('Text'),
  number('Number'),
  yesNo('Yes/No'),
  choice('Choice'),
  place('Place'),
  photo('Photo');

  const FieldType(this.label);

  final String label;

  /// The name in the stored definition.
  String get wire => this == FieldType.yesNo ? 'yes_no' : name;

  static FieldType? byWire(Object? s) {
    for (final t in FieldType.values) {
      if (t.wire == s) return t;
    }
    return null;
  }
}

/// A place: a fix, a saved place (with its key) or a point picked on the map.
class NbPlace {
  const NbPlace({required this.lat, required this.lon, this.label, this.key});

  final double lat;
  final double lon;
  final String? label;

  /// The saved place's key, when it is one.
  final String? key;

  /// The coordinates as shown when there is no name.
  String get coords => '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
  String get display => (label != null && label!.trim().isNotEmpty) ? label! : coords;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, 'label': ?label, 'key': ?key};

  static NbPlace? fromJson(Object? j) {
    if (j is! Map || j['lat'] is! num || j['lon'] is! num) return null;
    return NbPlace(
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      label: j['label'] is String ? j['label'] as String : null,
      key: j['key'] is String ? j['key'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) => other is NbPlace && other.lat == lat && other.lon == lon && other.label == label && other.key == key;

  @override
  int get hashCode => Object.hash(lat, lon, label, key);
}

/// A photo the app wrote to the Notebook's photos folder.
class NbPhoto {
  const NbPhoto({required this.id, this.width, this.height, this.bytes});

  final String id;
  final int? width;
  final int? height;
  final int? bytes;

  Map<String, dynamic> toJson() => {'id': id, 'width': ?width, 'height': ?height, 'bytes': ?bytes};

  static NbPhoto fromJson(Map j) => NbPhoto(
        id: j['id'] as String,
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        bytes: (j['bytes'] as num?)?.toInt(),
      );
}

/// One field of a notebook. [fid] is the store's stable id (null for a field not saved yet).
class LogField {
  const LogField({this.fid, required this.label, required this.type, this.unit, this.choices, this.hidden = false});

  final String? fid;
  final String label;
  final FieldType type;
  final String? unit;
  final List<String>? choices;

  /// Taken out of the log while entries still hold its values.
  final bool hidden;

  LogField copyWith({String? label, FieldType? type, String? unit, List<String>? choices, bool clearUnit = false, bool clearChoices = false}) => LogField(
        fid: fid,
        label: label ?? this.label,
        type: type ?? this.type,
        unit: clearUnit ? null : (unit ?? this.unit),
        choices: clearChoices ? null : (choices ?? this.choices),
        hidden: hidden,
      );

  /// As the store takes it.
  Map<String, dynamic> toJson() => {
        'fid': ?fid,
        'label': label,
        'type': type.wire,
        if (type == FieldType.number && unit != null && unit!.trim().isNotEmpty) 'unit': unit,
        if (type == FieldType.choice) 'choices': choices ?? const <String>[],
        if (hidden) 'hidden': true,
      };

  /// As a template has it (no fid, never hidden fields): the action generator's input.
  Map<String, dynamic> toTemplate() => {
        'label': label,
        'type': type.wire,
        if (type == FieldType.number && unit != null && unit!.trim().isNotEmpty) 'unit': unit,
        if (type == FieldType.choice) 'choices': choices ?? const <String>[],
      };

  static LogField? fromJson(Object? j) {
    if (j is! Map) return null;
    final type = FieldType.byWire(j['type']);
    if (type == null || j['label'] is! String) return null;
    return LogField(
      fid: j['fid'] is String ? j['fid'] as String : null,
      label: j['label'] as String,
      type: type,
      unit: j['unit'] is String ? j['unit'] as String : null,
      choices: j['choices'] is List ? [for (final c in j['choices'] as List) '$c'] : null,
      hidden: j['hidden'] == true,
    );
  }
}

/// How a notebook's entries are listed.
enum NotebookSort { date, recent, distance }

/// A notebook's definition (made from a template, which is data): its name, fields, how often it is due and its shape.
class NotebookDef {
  const NotebookDef({required this.name, required this.fields, this.dueEvery, this.sort = NotebookSort.date, this.quickAdd = false, this.meta = const {}});

  final String name;
  final List<LogField> fields;

  /// `month`, `3 months`, ... or null.
  final String? dueEvery;

  /// The shape: how the entries are listed, and whether they are made from the fields in a short sheet (with "Last done" and
  /// "Due again"): a log.
  final NotebookSort sort;
  final bool quickAdd;

  /// The template's id, version, author and group, when the log came from one.
  final Map<String, dynamic> meta;

  List<LogField> get visible => [for (final f in fields) if (!f.hidden) f];

  LogField? field(String fid) {
    for (final f in fields) {
      if (f.fid == fid) return f;
    }
    return null;
  }

  NotebookDef copyWith({String? name, List<LogField>? fields, String? dueEvery, bool clearDue = false, NotebookSort? sort, bool? quickAdd}) => NotebookDef(
        name: name ?? this.name,
        fields: fields ?? this.fields,
        dueEvery: clearDue ? null : (dueEvery ?? this.dueEvery),
        sort: sort ?? this.sort,
        quickAdd: quickAdd ?? this.quickAdd,
        meta: meta,
      );

  Map<String, dynamic> toJson() => {
        ...meta,
        'name': name,
        'due_every': dueEvery,
        'shape': {'sort': sort.name, if (quickAdd) 'quick_add': true},
        'fields': [for (final f in fields) f.toJson()],
      };

  /// [j] is a stored definition or a template; [shape] stands in for a template without one (a starter log takes the Log
  /// template's).
  static NotebookDef fromJson(Map j, {Map? shape}) {
    final sh = j['shape'] is Map ? j['shape'] as Map : (shape ?? const {});
    return NotebookDef(
      name: '${j['name'] ?? ''}',
      dueEvery: j['due_every'] is String ? j['due_every'] as String : null,
      sort: NotebookSort.values.firstWhere((s) => s.name == sh['sort'], orElse: () => NotebookSort.date),
      quickAdd: sh['quick_add'] == true,
      fields: [for (final f in (j['fields'] as List? ?? const [])) ?LogField.fromJson(f)],
      meta: {for (final k in const ['id', 'version', 'author', 'group']) if (j[k] != null) k: j[k]},
    );
  }
}

/// An attached file (a scan, a PDF): `files/<id>` in the media folder, with its own name.
class NbFile {
  const NbFile({required this.id, required this.name, this.mime, this.bytes});

  final String id;
  final String name;
  final String? mime;
  final int? bytes;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'mime': ?mime, 'bytes': ?bytes};

  static NbFile fromJson(Map j) => NbFile(id: j['id'] as String, name: '${j['name'] ?? ''}', mime: j['mime'] as String?, bytes: (j['bytes'] as num?)?.toInt());
}

/// An entry of a notebook.
class NbEntry {
  const NbEntry({
    required this.id,
    required this.notebookId,
    required this.occurredAt,
    this.title,
    this.body,
    this.values = const {},
    this.place,
    this.photos = const [],
    this.files = const [],
    this.draft = false,
    this.private = false,
    this.created = 0,
    this.updated = 0,
    this.rev = 0,
  });

  final String id;
  final String notebookId;

  /// Local ISO 8601 with its offset, as the phone wrote it.
  final String occurredAt;
  final String? title;
  final String? body;

  /// The values of the notebook's fields, by field id.
  final Map<String, dynamic> values;
  final NbPlace? place;
  final List<NbPhoto> photos;
  final List<NbFile> files;
  final bool draft;
  final bool private;
  final int created;
  final int updated;
  final int rev;

  /// The wall-clock time the entry was written for, in the offset it was written in.
  DateTime get when => wallClock(occurredAt);

  static NbEntry fromJson(Map j) => NbEntry(
        id: j['id'] as String,
        notebookId: j['notebook_id'] as String,
        occurredAt: j['occurred_at'] as String,
        title: j['title'] as String?,
        body: j['body'] as String?,
        values: j['values'] is Map ? (j['values'] as Map).cast<String, dynamic>() : const {},
        place: NbPlace.fromJson(j['place']),
        photos: [for (final p in (j['photos'] as List? ?? const [])) NbPhoto.fromJson(p as Map)],
        files: [for (final f in (j['files'] as List? ?? const [])) NbFile.fromJson(f as Map)],
        draft: j['draft'] == true,
        private: j['private'] == true,
        created: (j['created'] as num?)?.toInt() ?? 0,
        updated: (j['updated'] as num?)?.toInt() ?? 0,
        rev: (j['rev'] as num?)?.toInt() ?? 0,
      );
}

/// A notebook with what its row shows: how many entries and the newest one.
class Notebook {
  const Notebook({
    required this.id,
    required this.template,
    required this.def,
    this.private = false,
    this.map = true,
    this.templateRef,
    this.created = 0,
    this.lastUsed,
    this.entryCount = 0,
    this.fileCount = 0,
    this.placeCount = 0,
    this.lastEntry,
  });

  final String id;

  /// The template it was made from (`journal`, `log`, `notes`, `places`, ...).
  final String template;
  final NotebookDef def;
  final bool private;

  /// Its entries with a place are drawn on the map, in Maps' "My layers".
  final bool map;

  /// `starters/<template id>@<version>` for a log made from a starter.
  final String? templateRef;
  final int created;

  /// When an entry was last saved to it (Unix ms).
  final int? lastUsed;
  final int entryCount;
  final int fileCount;

  /// Entries with a place: the map switch shows once there is one.
  final int placeCount;
  final NbEntry? lastEntry;

  String get name => def.name;

  /// A log: entries made from the fields with quick add, "Last done" and "Due again".
  bool get isLog => def.quickAdd;

  static Notebook fromJson(Map j) => Notebook(
        id: j['id'] as String,
        template: '${j['template'] ?? ''}',
        def: NotebookDef.fromJson(j['def'] as Map),
        private: j['private'] == true,
        map: j['map'] != false,
        templateRef: j['template_ref'] as String?,
        created: (j['created'] as num?)?.toInt() ?? 0,
        lastUsed: (j['last_used'] as num?)?.toInt(),
        entryCount: (j['entries'] as num?)?.toInt() ?? 0,
        fileCount: (j['files'] as num?)?.toInt() ?? 0,
        placeCount: (j['places'] as num?)?.toInt() ?? 0,
        lastEntry: j['last_entry'] is Map ? NbEntry.fromJson(j['last_entry'] as Map) : null,
      );
}

/// The local date and time written in [iso] (`2026-10-25T16:12:00-06:00`), ignoring the offset: the time as the user saw it.
DateTime wallClock(String iso) {
  int p(int a, int b) => iso.length >= b ? int.tryParse(iso.substring(a, b)) ?? 0 : 0;
  return DateTime(p(0, 4), p(5, 7), p(8, 10), p(11, 13), p(14, 16), iso.length >= 19 && iso[16] == ':' ? p(17, 19) : 0);
}

/// A number as typed: whole numbers without a fraction.
String numberText(Object? v) {
  if (v is int) return '$v';
  if (v is double) return v == v.truncateToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : '$v';
  return '$v';
}
