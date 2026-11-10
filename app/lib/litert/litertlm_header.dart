import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What Cache needs from a .litertlm file's header: the model's own Jinja chat template, and whether it carries prompt templates
/// (turn prefixes the engine adds around the text it is given), which Cache does not support.
///
/// The file layout: the 8 bytes "LITERTLM", three u32 (version), 4 bytes of padding, a u64 header end, then a FlatBuffer
/// (LiteRTLMMetaData, schema/core/litertlm_header_schema.fbs in LiteRT-LM) up to the header end. Its section list gives each
/// section's begin and end offset in the file and its type; type 5 is the LlmMetadata protobuf
/// (runtime/proto/llm_metadata.proto): field 3 prompt_templates, field 7 jinja_prompt_template.
class LiteRtLmHeader {
  const LiteRtLmHeader({required this.jinjaTemplate, required this.hasPromptTemplates});

  /// The chat template, or null when the file has none.
  final String? jinjaTemplate;

  /// The metadata has prompt_templates (field 3).
  final bool hasPromptTemplates;

  static const int _llmMetadataSection = 5;

  /// Reads the header through [read], which returns the bytes of the file from [start] up to [end] (fewer at the end of the file).
  /// Throws a [FormatException] when the file is not a LiteRT-LM file.
  static LiteRtLmHeader parse(Uint8List Function(int start, int end) read) {
    final head = read(0, 32);
    if (head.length < 32 || String.fromCharCodes(head.sublist(0, 8)) != 'LITERTLM') {
      throw const FormatException('Not a .litertlm file');
    }
    final headerEnd = ByteData.sublistView(head).getUint64(24, Endian.little);
    if (headerEnd <= 32 || headerEnd > 64 * 1024 * 1024) throw const FormatException('The .litertlm header size is not valid');
    final buf = read(32, headerEnd);
    if (buf.length != headerEnd - 32) throw const FormatException('The .litertlm header is cut off');
    final bd = ByteData.sublistView(buf);
    int u32(int o) => bd.getUint32(o, Endian.little);

    // A FlatBuffer table: its position and the offsets of its fields (0: not present).
    (int, List<int>) table(int o) {
      final vt = o - bd.getInt32(o, Endian.little);
      final vlen = bd.getUint16(vt, Endian.little);
      final n = (vlen - 4) ~/ 2;
      return (o, [for (var i = 0; i < n; i++) bd.getUint16(vt + 4 + 2 * i, Endian.little)]);
    }

    int? field((int, List<int>) t, int i) => i < t.$2.length && t.$2[i] != 0 ? t.$1 + t.$2[i] : null;
    int deref(int p) => p + u32(p);

    final root = table(u32(0));
    final sectionsAt = field(root, 1);
    if (sectionsAt == null) throw const FormatException('The .litertlm header has no section list');
    final sm = table(deref(sectionsAt));
    final listAt = field(sm, 0);
    if (listAt == null) throw const FormatException('The .litertlm header has no sections');
    final vec = deref(listAt);
    final count = u32(vec);
    for (var i = 0; i < count; i++) {
      final e = vec + 4 + 4 * i;
      final t = table(deref(e));
      final b = field(t, 1), en = field(t, 2), ty = field(t, 3);
      if (b == null || en == null || ty == null || buf[ty] != _llmMetadataSection) continue;
      final begin = bd.getUint64(b, Endian.little), end = bd.getUint64(en, Endian.little);
      return _parseMetadata(read(begin, end));
    }
    return const LiteRtLmHeader(jinjaTemplate: null, hasPromptTemplates: false);
  }

  /// Reads the header of the file at [path].
  static LiteRtLmHeader fromFile(String path) {
    final f = File(path).openSync();
    try {
      return parse((start, end) {
        f.setPositionSync(start);
        return f.readSync(end - start);
      });
    } finally {
      f.closeSync();
    }
  }

  // The top-level fields of the LlmMetadata protobuf: only 3 and 7 matter here.
  static LiteRtLmHeader _parseMetadata(Uint8List b) {
    var i = 0;
    int varint() {
      var r = 0, s = 0;
      while (true) {
        if (i >= b.length) throw const FormatException('The .litertlm metadata is cut off');
        final c = b[i++];
        r |= (c & 0x7f) << s;
        s += 7;
        if (c < 0x80) return r;
      }
    }

    String? jinja;
    var templates = false;
    while (i < b.length) {
      final key = varint();
      final field = key >> 3, wire = key & 7;
      switch (wire) {
        case 0:
          varint();
        case 1:
          i += 8;
        case 2:
          final n = varint();
          if (i + n > b.length) throw const FormatException('The .litertlm metadata is cut off');
          if (field == 7) jinja = const Utf8Decoder().convert(b, i, i + n);
          if (field == 3) templates = true;
          i += n;
        case 5:
          i += 4;
        default:
          throw FormatException('The .litertlm metadata has an unknown field type ($wire)');
      }
    }
    return LiteRtLmHeader(jinjaTemplate: jinja, hasPromptTemplates: templates);
  }
}
