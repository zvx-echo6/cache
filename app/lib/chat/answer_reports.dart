import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Why someone reported an answer.
enum ReportReason {
  harmful('Offensive or harmful'),
  wrong('Wrong or made up'),
  other('Something else');

  const ReportReason(this.label);
  final String label;
}

/// One reported answer: what was asked, what the assistant said, which model said it, and why it was reported.
class AnswerReport {
  const AnswerReport({
    required this.at,
    required this.question,
    required this.answer,
    required this.model,
    required this.reason,
    this.note = '',
    this.sources = const [],
  });

  final DateTime at;
  final String question;
  final String answer;
  final String model;
  final ReportReason reason;
  final String note;

  /// The titles of the numbered sources the answer had.
  final List<String> sources;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'question': question,
    'answer': answer,
    'model': model,
    'reason': reason.name,
    'note': note,
    'sources': sources,
  };

  static AnswerReport? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    if (at == null) return null;
    return AnswerReport(
      at: at,
      question: '${j['question'] ?? ''}',
      answer: '${j['answer'] ?? ''}',
      model: '${j['model'] ?? ''}',
      reason: ReportReason.values.firstWhere((r) => r.name == j['reason'], orElse: () => ReportReason.other),
      note: '${j['note'] ?? ''}',
      sources: [for (final s in (j['sources'] as List? ?? const [])) '$s'],
    );
  }

  /// The report as Markdown, for the share sheet.
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('## Reported answer (${reason.label})')
      ..writeln()
      ..writeln('Model: $model  ')
      ..writeln('Reported: ${at.toLocal().toIso8601String().substring(0, 16).replaceFirst('T', ' ')}')
      ..writeln();
    if (note.isNotEmpty) b..writeln('Note: $note')..writeln();
    b
      ..writeln('**Question**')
      ..writeln()
      ..writeln(question)
      ..writeln()
      ..writeln('**Answer**')
      ..writeln()
      ..writeln(answer);
    if (sources.isNotEmpty) {
      b..writeln()..writeln('**Sources**')..writeln();
      for (var i = 0; i < sources.length; i++) {
        b.writeln('${i + 1}. ${sources[i]}');
      }
    }
    return b.toString();
  }
}

/// Reported answers, kept on this phone only (one JSON file). Nothing is sent anywhere; the person can share reports
/// themselves from Settings > Assistant > Reported answers.
class AnswerReports extends ChangeNotifier {
  AnswerReports({this.dirOverride});

  /// The app's store.
  static final AnswerReports shared = AnswerReports();

  /// Where the file is kept (tests); the app's support folder when null.
  final Directory? dirOverride;
  List<AnswerReport>? _items;

  Future<File> _file() async {
    final dir = dirOverride ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}reported_answers.json');
  }

  /// Newest first.
  Future<List<AnswerReport>> list() async {
    if (_items != null) return List.unmodifiable(_items!);
    final f = await _file();
    var items = <AnswerReport>[];
    if (await f.exists()) {
      try {
        final raw = jsonDecode(await f.readAsString());
        if (raw is List) items = [for (final j in raw) ?AnswerReport.fromJson(j)];
      } catch (e) {
        debugPrint('Reported answers could not be read: $e');
      }
    }
    items.sort((a, b) => b.at.compareTo(a.at));
    _items = items;
    return List.unmodifiable(items);
  }

  Future<int> count() async => (await list()).length;

  Future<void> add(AnswerReport r) async {
    final items = [...await list(), r]..sort((a, b) => b.at.compareTo(a.at));
    await _save(items);
  }

  Future<void> remove(AnswerReport r) async {
    final items = [...await list()]..remove(r);
    await _save(items);
  }

  Future<void> clear() => _save([]);

  Future<void> _save(List<AnswerReport> items) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final r in items) r.toJson()]), flush: true);
    await tmp.rename(f.path);
    _items = items;
    notifyListeners();
  }
}
