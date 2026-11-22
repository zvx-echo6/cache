import '../chat/tool.dart';

/// A page of text from the core.
class ReadPage {
  const ReadPage({required this.title, required this.text, required this.truncated, this.page, this.pageLabel});

  final String title;
  final String text;
  final bool truncated;

  /// The page when it is a number.
  final int? page;

  /// The page as printed, which may be text ("iv", "A-3"); null when only [page] is known or there is no page.
  final String? pageLabel;
}

/// One page of a [ReadDocument]: its text (the passages on it, blank-line separated) and their addresses.
class DocumentPageText {
  const DocumentPageText({required this.text, this.pageLabel, this.addresses = const []});

  final String text;

  /// The page as printed ("47", "iv"); null when the passage has no page.
  final String? pageLabel;
  final List<String> addresses;
}

/// A window of a library document: its pages in order, the index of the page holding the passage that was opened, and whether the
/// document goes on before and after them (it is too long to show whole).
class ReadDocument {
  const ReadDocument({required this.title, required this.pages, this.atPage = 0, this.moreBefore = false, this.moreAfter = false});

  final String title;
  final List<DocumentPageText> pages;
  final int atPage;
  final bool moreBefore;
  final bool moreAfter;
}

/// What the search and read tools need from the search core, so they can be tested without it.
abstract class SearchAccess {
  /// Up to [k] results across all searchable sources, best first. Throws when the core is not available.
  Future<List<SourceResult>> search(String query, {int k = 5});

  /// The text for an address, cut at a paragraph end to [maxChars].
  Future<ReadPage> read(String address, {int maxChars = 6000});

  /// The whole library document the passage at [address] belongs to, page by page.
  Future<ReadDocument> readDocument(String address);
}
