import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

/// In a browser there is no native PDFium to ask (and the browser does no indexing): no title, no page labels.
Future<({String? title, List<String?>? labels})> readPdfMeta(int handle, int pageCount) async => (title: null, labels: null);

/// In a browser: from the bytes ([openPdfForIndexing] on a device writes a file first).
Future<(PdfDocument, Future<void> Function())> openPdfForIndexing(Uint8List bytes, String name, {void Function(String step)? onStep}) async =>
    (await PdfDocument.openData(bytes, sourceName: 'pdfindex:$name', firstAttemptByEmptyPassword: true), () async {});
