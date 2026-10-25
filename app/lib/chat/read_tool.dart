import 'dart:convert';

import '../search/search_access.dart';
import 'tool.dart';

/// Roughly 1,500 tokens (docs/TOOLS.md): the core has no tokenizer, so the app sizes the text.
const int kReadMaxChars = 6000;

/// The read tool: the full text of one numbered result (docs/TOOLS.md, "read").
class ReadTool extends TextTool {
  ReadTool(this.search);

  final SearchAccess search;

  @override
  String get name => 'read';

  @override
  String get description => 'Open the full text of one numbered result when its snippet is not enough.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'n': {
            'type': 'integer',
            'minimum': 1,
            'description': 'The number of a result shown earlier in this conversation, e.g. 2 for [2].',
          },
        },
        'required': ['n'],
        'additionalProperties': false,
      };

  @override
  Future<String> runText(Map<String, dynamic> args, NumberedResult? Function(int n) lookup) async {
    final n = args['n'] is num ? (args['n'] as num).toInt() : int.tryParse('${args['n']}');
    final found = n == null ? null : lookup(n);
    if (n == null || found == null) {
      return jsonEncode({
        'ok': false,
        'error': {'type': 'not_found', 'detail': 'no result [${args['n']}] in this conversation'},
      });
    }
    final page = await search.read(found.result.address, maxChars: kReadMaxChars);
    return '[$n] ${page.title}\n${page.text}${page.truncated ? '\n[truncated]' : ''}';
  }
}
