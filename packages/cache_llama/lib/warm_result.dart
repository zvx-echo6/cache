/// How a read of the prompt start ahead of the first question ended (cl_warm).
enum WarmOutcome {
  /// The start is in the KV cache or in a saved prefix file already: nothing to read.
  covered,

  /// With check only: the start still has to be read. Otherwise: it was read (and saved as a prefix file).
  read,

  /// The read was stopped before the start was whole (nothing is saved as a prefix file).
  stopped,

  /// There is nothing to read (no model, no prefix folder or tools, an older library), or the call was not made.
  skipped,

  /// The read failed; [WarmResult.error] says why.
  failed,
}

class WarmResult {
  const WarmResult(this.outcome, {this.tokens = 0, this.joined = false, this.error});

  final WarmOutcome outcome;

  /// The prompt tokens still to read (check only), read, or read before the stop.
  final int tokens;

  /// A question was sent while the read ran, so it waited behind the read and reused it.
  final bool joined;
  final String? error;

  @override
  String toString() => 'WarmResult(${outcome.name}, $tokens tokens${joined ? ', joined' : ''}${error == null ? '' : ', $error'})';
}
