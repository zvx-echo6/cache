// The .litertlm header reader (lib/litert/litertlm_header.dart) against a small file in the same format, built here: the magic,
// the version, the header end, a FlatBuffer section list (as litert_header_schema.fbs lays it out) and the sections' bytes.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cache/litert/litertlm_header.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bytes {
  final List<int> b = [];
  int get pos => b.length;
  void u8(int v) => b.add(v & 0xff);
  void u16(int v) => b.addAll([v & 0xff, (v >> 8) & 0xff]);
  void u32(int v) => b.addAll([for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xff]);
  void i32(int v) => u32(v & 0xffffffff);
  void u64(int v) => b.addAll([for (var i = 0; i < 8; i++) (v >> (8 * i)) & 0xff]);
  void patch32(int at, int v) {
    for (var i = 0; i < 4; i++) {
      b[at + i] = (v >> (8 * i)) & 0xff;
    }
  }
}

List<int> _varint(int v) {
  final out = <int>[];
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

List<int> _field(int number, List<int> payload) => [..._varint(number << 3 | 2), ..._varint(payload.length), ...payload];

/// A LlmMetadata protobuf: field 1 (start token), field 2 (a stop token), the template (field 7) and, when asked, field 3.
List<int> _metadata({String? jinja, bool promptTemplates = false}) => [
      ..._field(1, [0x0a, 0x05, ...utf8.encode('<bos>')]),
      ..._field(2, [0x0a, 0x06, ...utf8.encode('<turn|>')]),
      ..._varint(5 << 3), ..._varint(300), // an unrelated varint field
      if (promptTemplates) ..._field(3, [0x0a, 0x02, 0x41, 0x42]),
      if (jinja != null) ..._field(7, utf8.encode(jinja)),
    ];

/// A file with the given sections, each (type, bytes), in the layout the reader expects.
Uint8List _litertlm(List<(int, List<int>)> sections) {
  final fb = _Bytes();
  fb.u32(0); // root offset, patched below
  // root: vtable (2 fields; field 1 at +4), then the table
  fb.u16(8); fb.u16(8); fb.u16(0); fb.u16(4);
  final root = fb.pos;
  fb.i32(root - 4); // soffset to the vtable at 4
  final rootField1 = fb.pos;
  fb.u32(0); // offset to the section list table, patched below
  fb.patch32(0, root);
  // section list: vtable (1 field at +4), table, vector
  final smVt = fb.pos;
  fb.u16(6); fb.u16(8); fb.u16(4);
  final sm = fb.pos;
  fb.i32(sm - smVt);
  final smField0 = fb.pos;
  fb.u32(0);
  fb.patch32(rootField1, sm - rootField1);
  final vec = fb.pos;
  fb.patch32(smField0, vec - smField0);
  fb.u32(sections.length);
  final elems = fb.pos;
  for (var i = 0; i < sections.length; i++) {
    fb.u32(0);
  }
  // section entries: a shared vtable (4 fields: begin +4, end +12, type +20), one table each
  final entVt = fb.pos;
  fb.u16(12); fb.u16(21); fb.u16(0); fb.u16(4); fb.u16(12); fb.u16(20);
  final begins = <int>[];
  for (var i = 0; i < sections.length; i++) {
    final t = fb.pos;
    fb.patch32(elems + 4 * i, t - (elems + 4 * i));
    fb.i32(t - entVt);
    begins.add(fb.pos);
    fb.u64(0);
    fb.u64(0);
    fb.u8(sections[i].$1);
  }
  final headerEnd = 32 + fb.pos;
  var at = headerEnd;
  final body = <int>[];
  for (var i = 0; i < sections.length; i++) {
    final data = sections[i].$2;
    final p = begins[i];
    for (var k = 0; k < 8; k++) {
      fb.b[p + k] = (at >> (8 * k)) & 0xff;
      fb.b[p + 8 + k] = ((at + data.length) >> (8 * k)) & 0xff;
    }
    body.addAll(data);
    at += data.length;
  }
  final head = _Bytes();
  head.b.addAll(utf8.encode('LITERTLM'));
  head.u32(1); head.u32(0); head.u32(0);
  head.u32(0); // padding
  head.u64(headerEnd);
  return Uint8List.fromList([...head.b, ...fb.b, ...body]);
}

LiteRtLmHeader _read(Uint8List file) => LiteRtLmHeader.parse((s, e) => Uint8List.sublistView(file, s, e > file.length ? file.length : e));

void main() {
  const template = "{{ bos_token }}{%- for m in messages -%}<|turn>{{ m['role'] }}\n{{ m['content'] }}<turn|>\n{%- endfor -%}";

  test('reads the Jinja template (field 7) from the LlmMetadata section among others', () {
    final file = _litertlm([(4, [1, 2, 3]), (5, _metadata(jinja: template)), (7, [9, 9])]);
    final h = _read(file);
    expect(h.jinjaTemplate, template);
    expect(h.hasPromptTemplates, isFalse);
  });

  test('a multi-byte template survives', () {
    final h = _read(_litertlm([(5, _metadata(jinja: 'café — \u{1F600}'))]));
    expect(h.jinjaTemplate, 'café — \u{1F600}');
  });

  test('reports prompt templates (field 3), which Cache refuses', () {
    final h = _read(_litertlm([(5, _metadata(jinja: template, promptTemplates: true))]));
    expect(h.hasPromptTemplates, isTrue);
    expect(h.jinjaTemplate, template);
  });

  test('a file without a template or without the metadata section has none', () {
    expect(_read(_litertlm([(5, _metadata())])).jinjaTemplate, isNull);
    expect(_read(_litertlm([(4, [1])])).jinjaTemplate, isNull);
  });

  test('refuses a file that is not LiteRT-LM', () {
    expect(() => _read(Uint8List.fromList(utf8.encode('GGUF${' ' * 60}'))), throwsFormatException);
  });
}
