// CACHE PATCH (see PATCH.md): where there is no native PDFium (the browser) there is nothing to lock.

typedef PdfiumLockFunctions = ({int acquire, int release, int dropOwner, int finalize});

/// The process's one PDFium lock (native builds only; here it does nothing).
class PdfiumLock {
  static PdfiumLockFunctions? get functions => null;

  static set functions(PdfiumLockFunctions? value) {}

  static int newOwnerId() => 0;

  static int become([int? owner]) => 0;

  static void dropOwner(int owner) {}

  static T hold<T>(T Function() action) => action();
}
