import 'navigation_action.dart';

/// One thing a tool found.
class SourceResult {
  const SourceResult({required this.title, required this.snippet, required this.address});

  final String title;
  final String snippet;

  /// Local address of the content (for later: where a citation opens).
  final String address;
}

/// A tool result with its conversation-wide number.
class NumberedResult {
  const NumberedResult(this.id, this.result);

  final int id;
  final SourceResult result;
}

abstract class Tool {
  String get name;
  String get description;

  /// JSON schema of the arguments.
  Map<String, dynamic> get parameters;

  Future<List<SourceResult>> run(Map<String, dynamic> args);

  Map<String, dynamic> toSchema() => {
        'type': 'function',
        'function': {'name': name, 'description': description, 'parameters': parameters},
      };
}

/// A tool whose result is plain text, not a list of numbered sources (read). The loop passes it a way to
/// find a result of this conversation by its number.
abstract class TextTool extends Tool {
  Future<String> runText(Map<String, dynamic> args, NumberedResult? Function(int n) lookup);

  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async => const [];
}

/// Numbers one conversation's tool results. The shipped one is the search core's (cs_format and
/// cs_conversation_ids); the loop falls back to counting in Dart when there is none.
abstract class ResultNumbering {
  /// Numbers [results] and returns the exact tool message.
  Future<String> format(List<SourceResult> results);

  /// Every number given so far in this conversation, with its address and title.
  Future<List<NumberedAddress>> ids();

  Future<void> dispose();
}

class NumberedAddress {
  const NumberedAddress({required this.n, required this.address, required this.title});

  final int n;
  final String address;
  final String title;
}

/// The tools run by the search core (cs_tool_schemas, cs_tool): every installed tool is offered to the model and
/// the core numbers the sources of each result in the conversation.
abstract class ToolHost {
  /// The function schemas of the tools available now ({"type":"function","function":{...}}).
  Future<List<Map<String, dynamic>>> schemas();

  /// Runs one tool call. [content] is exactly the tool message; [ids] are the numbers this call gave.
  Future<HostToolResult> call(String name, Map<String, dynamic> args, DateTime now);

  Future<void> dispose();
}

class HostToolResult {
  const HostToolResult({required this.content, required this.ids, this.navigationActions = const []});

  final String content;
  final List<NumberedAddress> ids;
  final List<NavigationAction> navigationActions;
}
