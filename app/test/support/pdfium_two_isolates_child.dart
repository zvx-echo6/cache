// Run as its own process by test/pdf/pdfium_font_mapper_test.dart (`dart --packages=... this.dart <mode> <pdfium> <fixture.pdf>`): two
// isolates of one process use PDFium, as the app's two Flutter engines do (the UI's, and the background run's). Prints `ok` and exits 0
// when every call came back; a PDFium font lookup that reaches into the wrong isolate aborts the whole process instead (the Dart VM:
// "Cannot invoke native callback from a different isolate"), which the test sees as a non-zero exit.
//
//   exited      the first isolate starts PDFium, a second starts it, reads a PDF and ends; the first then reads a PDF
//   alive       the second isolate starts PDFium and stays; the first reads a PDF meanwhile
//   interleaved the two isolates read the PDF in turn, one after the other, a dozen times each (the lock test, pdfium_lock_test.dart, has them
//               read at the same moment)

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'pdfium_child_support.dart';

Future<void> _second(List<Object> a) async {
  final (lib, pdf, hold, rounds, port) = (a[0] as String, a[1] as String, a[2] as bool, a[3] as int, a[4] as SendPort);
  await initChildPdfium(lib);
  final commands = ReceivePort();
  port.send(commands.sendPort);
  if (rounds > 0) {
    // interleaved: read when asked, and say so
    await for (final c in commands) {
      if (c == 'stop') break;
      port.send((await text(pdf)).isEmpty ? 'empty' : 'read');
    }
    port.send('done');
    return;
  }
  if ((await text(pdf)).isEmpty) {
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
  await initChildPdfium(lib);
  final first = await text(pdf);
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
      if ((await text(pdf)).isEmpty) exit(5);
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
      if ((await text(pdf)).isEmpty) exit(8);
    }
    cmd.send('stop');
    if (await next() != 'done') exit(9);
  }
  if ((await text(pdf)).isEmpty) exit(10);
  stdout.writeln('ok');
  exit(0);
}
