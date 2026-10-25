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
