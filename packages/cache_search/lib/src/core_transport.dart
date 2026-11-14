/// How a [SearchCore] reaches the core's dispatcher: [call] sends one `{op, args}` and returns the dispatcher's result, or
/// throws the [CacheSearchException] it raised. The phone uses an isolate (transport_isolate.dart); the browser uses
/// HTTPS to Cache Server (transport_http.dart).
abstract class CoreTransport {
  Future<dynamic> call(String op, Map<String, dynamic> args);

  Future<void> close();
}

/// Times of the core's calls on the phone (transport_isolate.dart): a call that took longer than [slowAfter] from being sent
/// to its answer is reported to [onSlow] with its op name, its time waiting in the worker's queue and its time running. The
/// app logs it ([line]), so a call that holds the queue shows in the log. No arguments or results are passed on.
class CoreCallTimes {
  CoreCallTimes._();

  static Duration slowAfter = const Duration(seconds: 2);

  /// Null: nothing is reported.
  static void Function(String op, Duration queued, Duration ran)? onSlow;

  /// The log line for one slow call.
  static String line(String op, Duration queued, Duration ran) =>
      'Core call $op: ${(queued + ran).inMilliseconds} ms (${queued.inMilliseconds} ms in the queue, ${ran.inMilliseconds} ms running)';

  /// Called with each answered call: [total] from being sent to the answer, [ran] as the worker measured it.
  static void answered(String op, Duration total, Duration ran) {
    final report = onSlow;
    if (report == null || total <= slowAfter) return;
    final queued = total - ran;
    report(op, queued.isNegative ? Duration.zero : queued, ran);
  }
}
