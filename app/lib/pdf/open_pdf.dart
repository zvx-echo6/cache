import 'dart:io';

import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter/material.dart';

import '../browse/zim_urls.dart' show zimIdOfAddress;
import '../sources/sources_state.dart';
import 'pdf_address.dart';
import 'pdf_reader_screen.dart';
import 'pdf_source.dart';

/// The PDF entry at [address] (a `zim:` address, any `#page=N` ignored) of a ZIM in [sources].
PdfZimSource zimPdfSource(SourcesState sources, String address) {
  final bare = withoutFragment(address);
  final id = zimIdOfAddress(bare);
  final path = id == null ? bare : bare.substring(bare.indexOf('/') + 1);
  return PdfZimSource(
    address: bare,
    title: pdfTitleOf(path),
    read: (a) async {
      try {
        return (await sources.zimGet(a)).bytes;
      } on CacheSearchException catch (e) {
        if (e.code == 'not_found') throw const PdfGone();
        rethrow;
      }
    },
  );
}

/// The reader for a PDF, taking the whole window (on a tablet or desktop too: the rail and lists are hidden behind it). The
/// arrow and Back return to where it was opened from.
Future<void> openPdfReader(BuildContext context, PdfSource source, {int? page, String? quote}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => PdfReaderScreen(source: source, initialPage: page, quote: quote)),
    );

/// The PDF page a ZIM address points at in the reader: [address] (`zim:<uuid>/<path>`, with `#page=N` for a page) in a ZIM of
/// [sources]. [page] and [quote] come from a citation when it has them; a page in the address wins over [page].
Future<void> openZimPdf(BuildContext context, SourcesState sources, String address, {int? page, String? quote}) =>
    openPdfReader(context, zimPdfSource(sources, address), page: pdfPageOfAddress(address) ?? page, quote: quote);

/// True when the file is a PDF: by its name or type when they say so, else by its first bytes.
Future<bool> isPdfFile(File file, {String? name, String? mime}) async {
  if ((mime ?? '').toLowerCase().startsWith('application/pdf')) return true;
  if ((name ?? file.path).toLowerCase().endsWith('.pdf')) return true;
  try {
    final raf = await file.open();
    try {
      return looksLikePdf(await raf.read(1024));
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}
