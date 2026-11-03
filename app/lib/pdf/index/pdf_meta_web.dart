/// In a browser there is no native PDFium to ask (and the browser does no indexing): no title, no page labels.
Future<({String? title, List<String?>? labels})> readPdfMeta(int handle, int pageCount) async => (title: null, labels: null);
