import 'dart:typed_data';

import 'package:cache/browse/web/device_api.dart' show DeviceException;
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

  /// `<library>/<doc>` -> the book's PDF; a book not here is a 404, as on the server.
  final Map<String, Uint8List> pdfs = {};
  final List<String> pdfAsked = [];

  @override
  Future<Uint8List> bookPdf(String library, String doc) async {
    pdfAsked.add('$library/$doc');
    return pdfs['$library/$doc'] ?? (throw const DeviceException('not_found', 'no such PDF', status: 404));
  }

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
