import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// The guide's chapters as they ship in the app (assets/guide/chapters, copies of docs/guide that a test keeps equal): the same
/// text the guide's search library is built from, so what the reader shows and what the assistant cites never drift apart.
const String kGuideChaptersDir = 'assets/guide/chapters';
const int kGuideChapterCount = 7;

/// The library id the guide's search library has, and the namespace its entries' ids are made in (tools/guide/verify.py).
const String kGuideLibrary = 'cache-guide';
const String _idNamespace = 'c4b95b91-e641-5c16-91a0-13ba2f6f7970';

/// One `## ` section of the guide.
class GuideSection {
  const GuideSection({required this.chapter, required this.heading, required this.body});

  final GuideChapter chapter;
  final String heading;
  final String body;

  /// "Cache guide: 1. Getting started: Choose a model": the section's title in the guide's library (tools/guide/guide_titles.py).
  String get title => 'Cache guide: ${chapter.heading}: $heading';

  /// "getting-started--choose-a-model": the section's id in the library, and its anchor in the reader.
  String get slug => '${guideSlug(chapter.heading.replaceFirst(RegExp(r'^\d+\.\s*'), ''))}--${guideSlug(heading)}';

  /// The library address a citation of this section carries: `lib:cache-guide/<uuid5>`.
  String get address => 'lib:$kGuideLibrary/${uuid5(_idNamespace, '$slug:1:0')}';
}

/// One chapter (`# ` heading) and its sections.
class GuideChapter {
  GuideChapter(this.heading, this.intro);

  final String heading;

  /// What comes before the first section.
  final String intro;
  final List<GuideSection> sections = [];
}

/// The whole guide.
class GuideBook {
  GuideBook(this.chapters);

  final List<GuideChapter> chapters;

  List<GuideSection> get sections => [for (final c in chapters) ...c.sections];

  /// The section with [title] (`Cache guide: <chapter>: <section>`), or null.
  GuideSection? byTitle(String title) => sections.where((s) => s.title == title).firstOrNull;

  /// The section [slug] names, or null.
  GuideSection? bySlug(String slug) => sections.where((s) => s.slug == slug).firstOrNull;

  /// The section a library citation ([GuideSection.address]) points at, or null.
  GuideSection? byAddress(String address) {
    final a = address.split('#').first.toLowerCase();
    return sections.where((s) => s.address == a).firstOrNull;
  }

  /// Sections whose heading or text holds every word of [query], heading matches first.
  List<GuideSection> search(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    bool all(String s) => words.every(s.toLowerCase().contains);
    return [
      for (final s in sections) if (all(s.heading)) s,
      for (final s in sections) if (!all(s.heading) && all('${s.heading}\n${s.body}')) s,
    ];
  }

  /// Reads the chapters from the app's assets.
  static Future<GuideBook> load({AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    return parse([for (var i = 1; i <= kGuideChapterCount; i++) await b.loadString('$kGuideChaptersDir/ch$i.md')]);
  }

  /// The chapters' Markdown, in order. A heading inside a code block is text, as tools/guide/split.py reads it.
  static GuideBook parse(List<String> chapters) {
    final out = <GuideChapter>[];
    for (final text in chapters) {
      String? heading;
      final intro = <String>[];
      GuideChapter? chapter;
      String? section;
      var body = <String>[];
      var fence = false;
      void close() {
        if (chapter != null && section != null) {
          chapter.sections.add(GuideSection(chapter: chapter, heading: section, body: body.join('\n').trim()));
        }
      }

      for (final line in text.split('\n')) {
        final l = line.replaceAll('\r', '');
        if (l.startsWith('```')) fence = !fence;
        if (!fence && heading == null && l.startsWith('# ')) {
          heading = l.substring(2).trim();
          continue;
        }
        if (!fence && l.startsWith('## ')) {
          if (chapter == null) {
            chapter = GuideChapter(heading ?? '', intro.join('\n').trim());
            out.add(chapter);
          }
          close();
          section = l.substring(3).trim();
          body = [];
          continue;
        }
        if (section == null) {
          intro.add(l);
        } else {
          body.add(l);
        }
      }
      if (chapter == null && heading != null) {
        chapter = GuideChapter(heading, intro.join('\n').trim());
        out.add(chapter);
      }
      close();
    }
    return GuideBook(out);
  }

  /// [markdown] with every `the section <Heading>` that names a section of the guide made a link to it (`#<slug>`), the
  /// longest heading first. Code blocks are left as they are.
  String linkSections(String markdown) {
    final byHeading = <String, GuideSection>{};
    for (final s in sections) {
      byHeading.putIfAbsent(s.heading, () => s);
    }
    final headings = byHeading.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    const lead = 'the section ';
    final out = StringBuffer();
    var fence = false;
    final lines = markdown.split('\n');
    for (var n = 0; n < lines.length; n++) {
      final line = lines[n];
      if (line.startsWith('```')) fence = !fence;
      if (fence || !line.toLowerCase().contains(lead)) {
        out.write(line);
      } else {
        var i = 0;
        final lower = line.toLowerCase();
        while (true) {
          final at = lower.indexOf(lead, i);
          if (at < 0) {
            out.write(line.substring(i));
            break;
          }
          final start = at + lead.length;
          out.write(line.substring(i, start));
          final h = headings.where((h) => line.startsWith(h, start)).firstOrNull;
          if (h == null) {
            i = start;
            continue;
          }
          out.write('[$h](#${byHeading[h]!.slug})');
          i = start + h.length;
        }
      }
      if (n < lines.length - 1) out.write('\n');
    }
    return out.toString();
  }
}

/// As tools/guide/verify.py makes the ids: lower case, `'` dropped, every run of other characters one `-`.
String guideSlug(String s) =>
    s.toLowerCase().replaceAll("'", '').replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// A name-based UUID (RFC 4122 version 5, SHA-1), as Python's uuid.uuid5 makes it.
String uuid5(String namespace, String name) {
  final ns = namespace.replaceAll('-', '');
  final bytes = [for (var i = 0; i < 32; i += 2) int.parse(ns.substring(i, i + 2), radix: 16)];
  final h = sha1.convert([...bytes, ...utf8.encode(name)]).bytes.sublist(0, 16);
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  final hex = [for (final b in h) b.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
