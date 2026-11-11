// CACHE PATCH (see PATCH.md): where there is no native PDFium (the browser) there is nothing to lock.

/// The process's one PDFium lock (native builds only; here it does nothing).
class PdfiumLock {
  static ({int lock, int unlock})? get functions => null;

  static set functions(({int lock, int unlock})? value) {}

  static T hold<T>(T Function() action) => action();
}
