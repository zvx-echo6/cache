// Run as its own process by test/pdf/pdfium_lock_death_test.dart: what happens to the PDFium lock (the core's, taken through its exported
// functions as pdfrx's worker takes it) when the isolate holding it is KILLED.
//
//   dart ... this.dart <mode> <mechanism> <where> <pdfium>
//
//   mode       native | dart | await        what the holder does while it holds the lock (one long native call, a Dart loop, an await)
//   mechanism  none | listener | finalizer  what tells the core the holder is gone: nothing; the spawner's exit listener (`onExit`), which
//                                           calls drop_owner; or a NativeFinalizer attached to an object of the holder's
//   where      same | group                 the holder is an isolate of this isolate group, or of a group of its own (as a Flutter
//                                           engine's isolates are)
//
// The main isolate kills the holder 300 ms in; another isolate then tries to take the lock: `RESULT ... probe acquired N ms after the
// kill`, or `probe TIMEOUT` when the lock was left held. Lines with the time say what the holder got to do.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'pdfium_child_support.dart';

int _now() => DateTime.now().microsecondsSinceEpoch ~/ 1000 % 1000000;

void _log(String s) => stdout.writeln('${_now()} $s');

void _nativeSleep(int ms) {
  if (Platform.isWindows) {
    DynamicLibrary.open('kernel32.dll').lookupFunction<Void Function(Uint32), void Function(int)>('Sleep')(ms);
  } else {
    DynamicLibrary.process().lookupFunction<Int32 Function(Uint32), int Function(int)>('usleep')(ms * 1000);
  }
}

PdfiumLockFunctions _fns(List<Object?> a) => (acquire: a[0] as int, release: a[1] as int, dropOwner: a[2] as int, finalize: a[3] as int);

Future<void> _holder(List<Object?> a) async {
  final fns = _fns(a);
  final (mode, mechanism, owner, ms, port) = (a[4] as String, a[5] as String, a[6] as int, a[7] as int, a[8] as SendPort);
  PdfiumLock.functions = fns;
  if (mechanism == 'finalizer') PdfiumLock.become(owner);
  final acquire = Pointer<NativeFunction<Uint64 Function(Uint64)>>.fromAddress(fns.acquire).asFunction<int Function(int)>();
  final release = Pointer<NativeFunction<Void Function(Uint64)>>.fromAddress(fns.release).asFunction<void Function(int)>();
  final token = acquire(owner);
  _log('holder: took the lock');
  port.send('locked');
  try {
    switch (mode) {
      case 'dart':
        final end = DateTime.now().add(Duration(milliseconds: ms));
        while (DateTime.now().isBefore(end)) {}
        _log('holder: the busy loop ended');
      case 'await':
        await Future<void>.delayed(Duration(milliseconds: ms));
        _log('holder: the await returned');
      default:
        _nativeSleep(ms);
        _log('holder: the native call returned');
    }
  } finally {
    _log('holder: finally ran');
    release(token);
  }
}

void _probe(List<Object?> a) {
  final fns = _fns(a);
  final acquire = Pointer<NativeFunction<Uint64 Function(Uint64)>>.fromAddress(fns.acquire).asFunction<int Function(int)>();
  final release = Pointer<NativeFunction<Void Function(Uint64)>>.fromAddress(fns.release).asFunction<void Function(int)>();
  final token = acquire(7);
  _log('probe: took the lock');
  (a[4] as SendPort).send('acquired');
  release(token);
}

Future<void> main(List<String> args, [Object? message]) async {
  if (message is List && message.isNotEmpty && message[0] == 'holder') {
    await _holder(message.skip(1).toList());
    return;
  }
  final (mode, mechanism, where, lib) = (args[0], args[1], args[2], args[3]);
  final fns = lockFunctionsOf(core(lib));
  if (fns == null) {
    stdout.writeln('no core');
    exit(2);
  }
  PdfiumLock.functions = fns;
  const owner = 4242424242;
  const ms = 2000;
  final ports = ReceivePort();
  final events = StreamIterator<Object?>(ports);
  final exits = ReceivePort();
  final exited = Completer<void>();
  exits.listen((_) {
    _log('main: the holder is gone');
    if (mechanism == 'listener') PdfiumLock.dropOwner(owner);
    exited.complete();
  });
  final data = <Object?>[fns.acquire, fns.release, fns.dropOwner, fns.finalize, mode, mechanism, owner, ms, ports.sendPort];
  final Isolate holder;
  if (where == 'group') {
    holder = await Isolate.spawnUri(Platform.script, const [], ['holder', ...data], onExit: exits.sendPort);
  } else {
    holder = await Isolate.spawn(_holder, data, onExit: exits.sendPort);
  }
  if (!await events.moveNext() || events.current != 'locked') exit(3);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  _log('main: killing the holder (immediate)');
  holder.kill(priority: Isolate.immediate);
  final killedAt = DateTime.now();
  await Isolate.spawn(_probe, <Object?>[fns.acquire, fns.release, fns.dropOwner, fns.finalize, ports.sendPort]);
  final got = await Future.any([events.moveNext().then((_) => true), Future<bool>.delayed(const Duration(seconds: 8), () => false)]);
  final label = '$mode/$mechanism/$where';
  if (got) {
    stdout.writeln('RESULT $label: probe acquired ${DateTime.now().difference(killedAt).inMilliseconds} ms after the kill');
  } else {
    stdout.writeln('RESULT $label: probe TIMEOUT, the lock was left held');
  }
  exit(0);
}
