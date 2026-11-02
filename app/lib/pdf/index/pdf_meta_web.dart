/// In a browser there is no native PDFium to ask (and the browser does no indexing): no title, no page labels.
({String? title, List<String?>? labels}) readPdfMeta(int handle, int pageCount) => (title: null, labels: null);
