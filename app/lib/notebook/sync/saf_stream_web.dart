// Web build: Storage Access Framework folders are an Android feature (package:saf_stream needs JNI). The members SafFolder uses, as stubs
// that throw.
import 'dart:typed_data';

/// Where a file was written.
class SafNewFile {
  SafNewFile(this.uri, this.fileName);

  final Uri uri;
  final String? fileName;
}

class SafStream {
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async => throw UnsupportedError('web: SafStream.readFileBytes');

  Future<SafNewFile> writeFileBytes(String treeUri, String fileName, String mime, Uint8List data, {bool? overwrite, bool? append}) async =>
      throw UnsupportedError('web: SafStream.writeFileBytes');

  Future<SafNewFile> writeFileUriBytes(String fileUri, Uint8List data, {bool? append}) async =>
      throw UnsupportedError('web: SafStream.writeFileUriBytes');

  Future<void> copyToLocalFile(String srcUri, String destPath) async => throw UnsupportedError('web: SafStream.copyToLocalFile');

  Future<Stream<Uint8List>> readFileStream(String uri, {int? bufferSize, int? start}) async => throw UnsupportedError('web: SafStream.readFileStream');
}
