import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'notebook_model.dart';

/// The notebook templates that ship with the app (Journal, Log, Notes, Places): data, so a new kind of notebook is a new entry in
/// this file and no new code.
const String kTemplatesAsset = 'assets/notebook/templates.json';

/// The 16 starter logs (a copy of specs/notebook-starters.json; a test keeps them equal). A starter is not a notebook until the
/// user taps it; it is made as a notebook of the Log template.
const String kStartersAsset = 'assets/notebook/starters.json';

/// A template: the definition a notebook is made from, with its suggested private default.
class NotebookTemplate {
  const NotebookTemplate({
    required this.id,
    required this.version,
    required this.template,
    required this.def,
    this.group = '',
    this.description = '',
    this.icon = '',
    this.private = false,
    this.map = false,
    this.entryWords = const ('entry', 'entries'),
  });

  final String id;
  final int version;

  /// The template id the notebook keeps: its own for a notebook template, `log` for a starter log.
  final String template;
  final NotebookDef def;
  final String group;
  final String description;

  /// One of the shape names the app draws (circle, diamond, square, triangle); anything else gets the circle.
  final String icon;

  /// The suggested default (true for health logs); the user can switch it off.
  final bool private;

  /// Whether the notebook's entries start on the map (a new entry then starts at Here).
  final bool map;

  /// What one entry and several are called in the notebook's row ("6 notes", "218 places").
  final (String, String) entryWords;

  /// "1 note", "6 notes"
  String count(int n) => '$n ${n == 1 ? entryWords.$1 : entryWords.$2}';

  String get name => def.name;

  /// What a notebook keeps of where it came from.
  String get ref => '${template == id ? 'templates' : 'starters'}/$id@$version';
}

/// The templates of a `cache-notebook-templates` file, or (as Log notebooks with [logShape]) of a `cache-log-templates` file.
List<NotebookTemplate> parseTemplates(String text, {Map? logShape}) {
  final j = jsonDecode(text);
  if (j is! Map) return const [];
  final logs = j['format'] == 'cache-log-templates';
  if (!logs && j['format'] != 'cache-notebook-templates') return const [];
  return [
    for (final t in (j['templates'] as List? ?? const []))
      if (t is Map && t['id'] is String && t['name'] is String)
        NotebookTemplate(
          id: t['id'] as String,
          version: (t['version'] as num?)?.toInt() ?? 1,
          template: logs ? 'log' : t['id'] as String,
          def: NotebookDef.fromJson(t, shape: logs ? logShape : null),
          group: '${t['group'] ?? ''}',
          description: '${t['description'] ?? ''}',
          icon: '${t['icon'] ?? ''}',
          private: t['private'] == true,
          map: t['map'] == true,
          entryWords: t['entry_words'] is List && (t['entry_words'] as List).length == 2
              ? ('${(t['entry_words'] as List)[0]}', '${(t['entry_words'] as List)[1]}')
              : ('entry', 'entries'),
        ),
  ];
}

/// The templates and the starter logs, read once.
class Templates {
  const Templates(this.notebooks, this.starters);

  final List<NotebookTemplate> notebooks;
  final List<NotebookTemplate> starters;

  NotebookTemplate? byId(String id) {
    for (final t in notebooks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// [starters] by group, groups in the order they first appear.
  Map<String, List<NotebookTemplate>> get startersByGroup {
    final out = <String, List<NotebookTemplate>>{};
    for (final t in starters) {
      out.putIfAbsent(t.group, () => []).add(t);
    }
    return out;
  }

  static Templates parse(String templates, String starters) {
    final nbs = parseTemplates(templates);
    Map? logShape;
    for (final t in nbs) {
      if (t.id == 'log') logShape = {'sort': t.def.sort.name, 'quick_add': t.def.quickAdd};
    }
    return Templates(nbs, parseTemplates(starters, logShape: logShape ?? const {'sort': 'recent', 'quick_add': true}));
  }
}

Templates? _loaded;

Future<Templates> loadTemplates() async =>
    _loaded ??= Templates.parse(await rootBundle.loadString(kTemplatesAsset), await rootBundle.loadString(kStartersAsset));
