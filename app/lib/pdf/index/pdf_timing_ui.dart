import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'pdf_index_state.dart';
import 'pdf_timing.dart';

/// Where the timing log goes: on Android the app's folder on shared storage (`adb pull /sdcard/Android/data/APP/files/pdf-timing`),
/// elsewhere the app's support folder.
Future<Directory> pdfTimingDir() async {
  Directory? base;
  if (Platform.isAndroid) {
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {}
  }
  base ??= await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}pdf-timing');
}

/// The debug timing switch (debug and developer builds only): choose a library, index its first 20 PDFs in a throwaway build,
/// and write pages/s and ms a PDF for extract, chunk and add to a log the developer pulls.
Future<void> runPdfTimingFromSettings(BuildContext context, PdfIndexState state) async {
  final zims = [for (final z in state.zims()) if (z.uuid != null) z];
  final messenger = ScaffoldMessenger.of(context);
  if (zims.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('No library to time.')));
    return;
  }
  final zim = await showDialog<PdfZimRef>(
    context: context,
    builder: (ctx) => SimpleDialog(
      key: const ValueKey('pdf-timing-pick'),
      title: const Text('Time PDF indexing'),
      children: [
        for (final z in zims) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, z), child: Text(z.title)),
      ],
    ),
  );
  if (zim == null) return;
  messenger.showSnackBar(SnackBar(content: Text('Timing the first $kPdfTimingCount PDFs of ${zim.title}…')));
  try {
    final list = await state.listOf(zim);
    if (list == null) throw StateError('The library could not be read.');
    final r = await runPdfTiming(
      core: state.core,
      paths: state.pathsOf(zim) ?? (throw StateError('The library is not ready yet.')),
      zimName: state.zimNameOf(zim, list),
      list: list,
      readPages: state.readPages,
      logDir: await pdfTimingDir(),
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 12),
        content: Text(
          '${r.pagesPerSecond.toStringAsFixed(1)} pages/s; a PDF: extract ${r.extractMsPerPdf.toStringAsFixed(0)} ms, '
          'chunk ${r.chunkMsPerPdf.toStringAsFixed(0)} ms, add ${r.staged ? '${r.addMsPerPdf.toStringAsFixed(0)} ms' : 'not timed'}. Log: ${r.log.path}',
        ),
      ));
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Timing stopped: $e')));
  }
}
