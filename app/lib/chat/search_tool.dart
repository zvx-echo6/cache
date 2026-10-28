import 'tool.dart';

/// The shipped search tool. No sources exist yet (they arrive in steps 2-4), so it finds nothing.
class SearchTool extends Tool {
  @override
  String get name => 'search';

  @override
  String get description => "Search the user's offline library and reference articles";

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'What to look for'},
        },
        'required': ['query'],
      };

  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async => const [];
}
