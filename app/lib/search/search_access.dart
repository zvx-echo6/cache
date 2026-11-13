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

/// What the search and read tools need from the search core, so they can be tested without it.
abstract class SearchAccess {
  /// Up to [k] results across all searchable sources, best first. Throws when the core is not available.
  Future<List<SourceResult>> search(String query, {int k = 5});

  /// The text for an address, cut at a paragraph end to [maxChars].
  Future<ReadPage> read(String address, {int maxChars = 6000});
}
