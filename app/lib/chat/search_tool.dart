import '../search/search_access.dart';
import 'tool.dart';

/// The search tool: the search core over the ZIMs the user added (docs/TOOLS.md, "search").
class SearchTool extends Tool {
  SearchTool(this.search);

  final SearchAccess search;

  @override
  String get name => 'search';

  @override
  String get description =>
      'Search the offline library and reference articles (encyclopedias, manuals, medical and how-to guides) on this phone. '
      'Returns up to 5 numbered results. Use it before answering any question about facts or how to do something.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
            'description': 'What to search for, in plain words.',
          },
        },
        'required': ['query'],
        'additionalProperties': false,
      };

  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async {
    final q = (args['query'] ?? '').toString().trim();
    if (q.isEmpty) throw StateError('the query is empty');
    return search.search(q, k: 5);
  }
}
