import 'package:cache/library/shelf_server.dart';

/// Cache Server's Bookshelves as a browser sees them, answered from what a test sets.
class FakeShelfServer implements ShelfServer {
  Map<String, dynamic> viewJson = {};
  Map<String, Map<String, Map<String, dynamic>>> factsJson = {};
  String stampText = 's1';
  bool down = false;
  int stamps = 0;
  int views = 0;
  final List<List<Map<String, dynamic>>> sent = [];

  @override
  Future<({String device, String stamp, Map<String, dynamic> view})> view() async {
    if (down) throw StateError('down');
    views++;
    return (device: 'server-device', stamp: stampText, view: viewJson);
  }

  @override
  Future<String> stamp() async {
    if (down) throw StateError('down');
    stamps++;
    return stampText;
  }

  @override
  Future<Map<String, Map<String, Map<String, dynamic>>>> facts() async => factsJson;

  @override
  Future<void> events(List<Map<String, dynamic>> events) async {
    if (down) throw StateError('down');
    sent.add(events);
  }
}
