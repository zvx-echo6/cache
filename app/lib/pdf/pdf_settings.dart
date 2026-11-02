import 'package:flutter/widgets.dart';

/// Settings > Appearance > "Dark pages": in a dark theme, PDF pages are drawn light on dark (for text-only PDFs). Off by default;
/// AppState keeps it and sets it here.
final ValueNotifier<bool> pdfDarkPages = ValueNotifier<bool>(false);

/// Where the reader's "Open Library" button goes; set by the app's shell (the button is left out while it is not set). "Open
/// Storage" goes where the download pop-ups' "Free up space" goes (openStorageForSpace).
class PdfReaderLinks {
  static void Function(BuildContext context)? openLibrary;
}
