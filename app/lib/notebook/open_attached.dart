import 'package:flutter/widgets.dart';

import '../platform.dart' as plat;
import '../pdf/open_pdf.dart';
import '../pdf/pdf_address.dart';
import '../pdf/pdf_source.dart';
import 'media.dart';
import 'notebook_model.dart';
import 'notebook_state.dart';

/// Opens an attached file: a PDF in the app's own PDF reader, anything else in another app ([openFile]). An entry's file is a
/// copy in the notebook's media folder (`files/<id>`), so a PDF that is missing there says "This file is no longer on this
/// device".
Future<void> openAttached(BuildContext context, NotebookState nb, NbFile f) async {
  if (plat.isWeb) return openFile(nb, f); // a download, or the browser's own PDF viewer in a new tab
  final file = await nb.attachedFile(f.id);
  final pdf = await isPdfFile(file, name: f.name, mime: f.mime);
  if (!context.mounted) return;
  if (pdf) {
    await openPdfReader(context, PdfFileSource(file.path, title: pdfTitleOf(f.name), from: PdfFrom.notebook));
    return;
  }
  await openFile(nb, f);
}
