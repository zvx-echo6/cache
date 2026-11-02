import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart';

pdfium_bindings.PDFium? _pdfium;

/// The PDFium pdfrx loaded (the same library: pdfrx's module path).
pdfium_bindings.PDFium get _lib => _pdfium ??= pdfium_bindings.getPdfium(modulePath: Pdfrx.pdfiumModulePath);

/// A PDFium call that fills a UTF-16LE buffer and answers its length in bytes with the closing 0 (asked first with no buffer).
String? _utf16(int Function(Pointer<Void> buffer, int length) call) {
  final n = call(nullptr, 0);
  if (n <= 2) return null;
  final buf = calloc<Uint8>(n);
  try {
    final got = call(buf.cast<Void>(), n);
    if (got <= 2) return null;
    final s = String.fromCharCodes(buf.cast<Uint16>().asTypedList((got < n ? got : n) ~/ 2 - 1));
    return s.trim().isEmpty ? null : s;
  } finally {
    calloc.free(buf);
  }
}

/// The metadata Title and each page's printed label of the document [handle] (an FPDF_DOCUMENT, from
/// PdfDocument.useNativeDocumentHandle), with [pageCount] pages.
({String? title, List<String?>? labels}) readPdfMeta(int handle, int pageCount) {
  final pdfium = _lib;
  final doc = Pointer<pdfium_bindings.fpdf_document_t__>.fromAddress(handle);
  final tag = 'Title'.toNativeUtf8();
  try {
    final title = _utf16((b, n) => pdfium.FPDF_GetMetaText(doc, tag.cast<Char>(), b, n));
    final labels = [for (var i = 0; i < pageCount; i++) _utf16((b, n) => pdfium.FPDF_GetPageLabel(doc, i, b, n))];
    return (title: title, labels: labels.any((l) => l != null) ? labels : null);
  } finally {
    calloc.free(tag);
  }
}
