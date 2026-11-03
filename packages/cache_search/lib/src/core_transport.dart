/// How a [SearchCore] reaches the core's dispatcher: [call] sends one `{op, args}` and returns the dispatcher's result, or
/// throws the [CacheSearchException] it raised. The phone uses an isolate (transport_isolate.dart); the browser uses
/// HTTPS to Cache Server (transport_http.dart).
abstract class CoreTransport {
  Future<dynamic> call(String op, Map<String, dynamic> args);

  Future<void> close();
}
