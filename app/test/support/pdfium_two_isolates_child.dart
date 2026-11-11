// Run as its own process by test/pdf/pdfium_font_mapper_test.dart (`dart --packages=... this.dart <mode> <pdfium> <fixture.pdf>`): two
// isolates of one process use PDFium, as the app's two Flutter engines do (the UI's, and the background run's). Prints `ok` and exits 0
// when every call came back; a PDFium font lookup that reaches into the wrong isolate aborts the whole process instead (the Dart VM:
// "Cannot invoke native callback from a different isolate"), which the test sees as a non-zero exit.
//
//   exited      the first isolate starts PDFium, a second starts it, reads a PDF and ends; the first then reads a PDF
//   alive       the second isolate starts PDFium and stays; the first reads a PDF meanwhile
//   interleaved the two isolates read the PDF in turn, one after the other, a dozen times each (never at the same moment: PDFium is not
//               thread-safe and the app never asks two of its threads at once)

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:pdfrx_engine/pdfrx_engine.dart';

/// The core's one native PDFium font mapper, as the app asks for it wherever it starts pdfrx (app/lib/pdf/pdfium_init.dart): the core
/// library is found by CACHE_CORE_LIB or its usual name on the library path.
void _nativeFonts(String pdfium) {
  final name = Platform.environment['CACHE_CORE_LIB'] ?? (Platform.isWindows ? 'cache_search.dll' : 'libcache_search.so');
  try {
    final core = DynamicLibrary.open(name);
    final probe = core.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('cs_ingest_probe');
    final free = core.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('cs_free_string');
    final arg = '{"engines":{"pdfium_lib":${_json(pdfium)}},"fonts":true,"fonts_only":true}'.toNativeUtf8();
    final out = probe(arg);
    calloc.free(arg);
    if (out != nullptr) free(out);
  } catch (e) {
    stderr.writeln('no native font mapper (the core is not here: $e)');
  }
}

String _json(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

Future<void> _init(String lib) async {
  Pdfrx.pdfiumModulePath = lib;
  await pdfrxInitialize(tmpPath: Directory.systemTemp.createTempSync('pdfrx-child').path);
  _nativeFonts(lib);
}

Future<String> _text(String pdf) async {
  final doc = await PdfDocument.openFile(pdf);
  try {
    final b = StringBuffer();
    for (final page in doc.pages) {
      b.write((await page.loadText())?.fullText);
    }
    return b.toString();
  } finally {
    doc.dispose();
  }
}

Future<void> _second(List<Object> a) async {
  final (lib, pdf, hold, rounds, port) = (a[0] as String, a[1] as String, a[2] as bool, a[3] as int, a[4] as SendPort);
  await _init(lib);
  final commands = ReceivePort();
  port.send(commands.sendPort);
  if (rounds > 0) {
    // interleaved: read when asked, and say so
    await for (final c in commands) {
      if (c == 'stop') break;
      port.send((await _text(pdf)).isEmpty ? 'empty' : 'read');
    }
    port.send('done');
    return;
  }
  if ((await _text(pdf)).isEmpty) {
    port.send('empty');
    return;
  }
  port.send('read');
  if (hold) {
    await for (final c in commands) {
      if (c == 'stop') break;
    }
  }
  port.send('done');
}

Future<void> main(List<String> args) async {
  final (mode, lib, pdf) = (args[0], args[1], args[2]);
  await _init(lib);
  final first = await _text(pdf);
  if (first.isEmpty) {
    stdout.writeln('empty text before the second isolate');
    exit(3);
  }
  final port = ReceivePort();
  final events = StreamIterator<Object?>(port);
  Future<Object?> next() async => await events.moveNext() ? events.current : null;
  final hold = mode == 'alive';
  final rounds = mode == 'interleaved' ? 12 : 0;
  await Isolate.spawn(_second, <Object>[lib, pdf, hold, rounds, port.sendPort]);
  final cmd = await next();
  if (cmd is! SendPort) exit(4);
  if (mode == 'interleaved') {
    for (var i = 0; i < rounds; i++) {
      if ((await _text(pdf)).isEmpty) exit(5);
      cmd.send('read');
      if (await next() != 'read') exit(6);
    }
    cmd.send('stop');
    if (await next() != 'done') exit(6);
  } else if (mode == 'exited') {
    if (await next() != 'read') exit(6);
    if (await next() != 'done') exit(6); // the second isolate has read its PDF and is ending
    await Future<void>.delayed(const Duration(milliseconds: 300));
  } else {
    if (await next() != 'read') exit(6);
    // the second isolate has read its PDF and is alive with PDFium started; the first reads meanwhile
    for (var i = 0; i < 3; i++) {
      if ((await _text(pdf)).isEmpty) exit(8);
    }
    cmd.send('stop');
    if (await next() != 'done') exit(9);
  }
  if ((await _text(pdf)).isEmpty) exit(10);
  stdout.writeln('ok');
  exit(0);
}
