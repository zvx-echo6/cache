// Run as its own process by test/pdf/pdfium_font_mapper_test.dart (`dart --packages=... this.dart <mode> <pdfium> <fixture.pdf>`): two
// isolates of one process use PDFium, as the app's two Flutter engines do (the UI's, and the background run's). Prints `ok` and exits 0
// when every call came back; a PDFium font lookup that reaches into the wrong isolate aborts the whole process instead (the Dart VM:
// "Cannot invoke native callback from a different isolate"), which the test sees as a non-zero exit.
//
//   exited      the first isolate starts PDFium, a second starts it, reads a PDF and ends; the first then reads a PDF
//   alive       the second isolate starts PDFium and stays; the first reads a PDF meanwhile
//   concurrent  both read the PDF over and over while the second starts PDFium part way

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:pdfrx_engine/pdfrx_engine.dart';

Future<void> _init(String lib) async {
  Pdfrx.pdfiumModulePath = lib;
  await pdfrxInitialize(tmpPath: Directory.systemTemp.createTempSync('pdfrx-child').path);
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
  port.send('started');
  for (var i = 0; i < rounds; i++) {
    if ((await _text(pdf)).isEmpty) {
      port.send('empty');
      return;
    }
  }
  if (hold) {
    final done = ReceivePort();
    port.send(done.sendPort);
    await done.first;
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
  final rounds = mode == 'concurrent' ? 25 : 1;
  await Isolate.spawn(_second, <Object>[lib, pdf, hold, rounds, port.sendPort]);
  if (await next() != 'started') exit(4);
  if (mode == 'concurrent') {
    for (var i = 0; i < 25; i++) {
      if ((await _text(pdf)).isEmpty) exit(5);
    }
    if (await next() != 'done') exit(6);
  } else if (mode == 'exited') {
    if (await next() != 'done') exit(6); // the second isolate has read its PDF and is ending
    await Future<void>.delayed(const Duration(milliseconds: 300));
  } else {
    final done = await next();
    if (done is! SendPort) exit(7);
    // the second isolate is alive and has PDFium started; the first reads meanwhile
    for (var i = 0; i < 3; i++) {
      if ((await _text(pdf)).isEmpty) exit(8);
    }
    done.send('stop');
    if (await next() != 'done') exit(9);
  }
  if ((await _text(pdf)).isEmpty) exit(10);
  stdout.writeln('ok');
  exit(0);
}
