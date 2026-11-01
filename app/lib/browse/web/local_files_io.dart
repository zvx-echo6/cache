import 'local_files_base.dart';

/// No file picker outside a browser.
Future<LocalFile?> pickLocalFile({List<String> accept = const []}) async => null;

/// No uploads outside a browser: the tests give their own [Uploader].
Uploader createBrowserUploader() => throw UnsupportedError('Uploads from this computer need a browser');

/// Listens for files dropped on the page; nothing is dropped outside a browser.
class DropListener {
  DropListener({required void Function(bool active) onActive, required void Function(LocalFile file) onDrop});

  void dispose() {}
}

/// Asks the browser to question leaving the page while [on]; nothing outside a browser.
void setLeaveWarning(bool on) {}
