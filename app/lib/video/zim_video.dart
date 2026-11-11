import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache_search/cache_search.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'video_media.dart';

/// The file name endings of the video and sound entries a ZIM can hold (the player takes them; a web view may not).
const Set<String> kZimMediaExtensions = {'mp4', 'm4v', 'webm', 'ogv', 'mov', 'mkv', 'mp3', 'm4a', 'oga', 'ogg', 'opus', 'wav'};
const Set<String> _audioExtensions = {'mp3', 'm4a', 'oga', 'ogg', 'opus', 'wav'};

String _ext(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String _bare(String address) {
  var a = address;
  for (final c in ['#', '?']) {
    final i = a.indexOf(c);
    if (i >= 0) a = a.substring(0, i);
  }
  return a;
}

/// Opens a ZIM's video entry in the app's player (the app's frame sets it); the reader calls it for a link to a video entry. Null:
/// the reader leaves such a link to the web view.
void Function(String address)? openZimMediaInPlayer;

/// True for a `zim:<uuid>/<path>` address of a video or sound entry (by its name; the entry's type decides when it is read).
bool isZimMediaAddress(String address) => address.startsWith('zim:') && kZimMediaExtensions.contains(_ext(_bare(address)));

/// The caption entries a ZIM keeps beside a video, tried in this order: the same folder and base name, as the search core pairs
/// them (FEMA_UHA_video01.mp4 with FEMA_UHA_video01_en.srt or FEMA_UHA_video01.vtt).
List<String> zimCaptionCandidates(String videoAddress) {
  final a = _bare(videoAddress);
  final dot = a.lastIndexOf('.');
  final base = dot > a.lastIndexOf('/') ? a.substring(0, dot) : a;
  return [for (final suffix in ['', '_en', '.en', '-en']) for (final ext in ['vtt', 'srt']) '$base$suffix.$ext'];
}

/// A video entry of a ZIM, ready for the player: the entry copied to a file (the player plays files and addresses, not
/// bytes), and its caption entry beside it when the ZIM has one.
class ZimVideo {
  const ZimVideo({required this.target, required this.zimTitle});

  final VideoTarget target;

  /// The ZIM's title, for "In Wikipedia (on this device)".
  final String zimTitle;
}

/// Reads the video entry at [address] with [read] (the reader's own entry read, cs_zim_get) into [cacheDir], and its paired
/// caption when there is one, as a [VideoTarget] starting at [offsetS]. Throws a [CacheSearchException] "not_found" when the
/// entry is not in a ZIM on this device, and "unsupported" when it is not a video or sound entry.
Future<ZimVideo> openZimVideo({
  required String address,
  required Future<ZimBytes> Function(String address) read,
  required Directory cacheDir,
  required String zimTitle,
  double offsetS = 0,
}) async {
  final bare = _bare(address);
  final entry = await read(bare);
  final mime = entry.mime.split(';').first.trim().toLowerCase();
  final ext = _ext(bare);
  final audio = mime.startsWith('audio/') || (!mime.startsWith('video/') && _audioExtensions.contains(ext));
  if (!mime.startsWith('video/') && !mime.startsWith('audio/') && !kZimMediaExtensions.contains(ext)) {
    throw CacheSearchException('unsupported', 'not a video: $mime');
  }
  final name = sha1.convert(utf8.encode(bare)).toString().substring(0, 16);
  await cacheDir.create(recursive: true);
  // Only the video being watched is kept: an earlier one's copy goes (a ZIM's videos can be large).
  try {
    for (final f in cacheDir.listSync().whereType<File>()) {
      if (!f.uri.pathSegments.last.startsWith(name)) f.deleteSync();
    }
  } catch (_) {}
  final file = File('${cacheDir.path}/$name.${ext.isEmpty ? 'mp4' : ext}');
  if (!file.existsSync() || file.lengthSync() != entry.bytes.length) await _write(file, entry.bytes);
  final captions = <DownloadedCaption>[];
  for (final c in zimCaptionCandidates(bare)) {
    try {
      final cap = await read(c);
      if (cap.bytes.isEmpty) continue;
      final f = File('${cacheDir.path}/$name.${_ext(c)}');
      await _write(f, cap.bytes);
      final lang = RegExp(r'[_.-]([a-z]{2})\.(vtt|srt)$').firstMatch(c)?.group(1) ?? '';
      captions.add(DownloadedCaption(language: lang, label: 'On', path: f.path));
      break;
    } on CacheSearchException {
      continue;
    }
  }
  final title = Uri.decodeComponent(bare.split('/').last.replaceAll('_', ' ')).replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
  return ZimVideo(
    zimTitle: zimTitle,
    target: VideoTarget(
      isLocal: true,
      uuid: bare,
      title: title,
      offsetS: offsetS,
      durationS: 0,
      location: file.path,
      isAudio: audio,
      captions: captions,
    ),
  );
}

/// A browser's [openZimVideo]: nothing is copied. The player takes the entry from Cache Server's `/api/video/zim/` route (with Range,
/// so it can seek), and the caption entry beside it is found the same way [openZimVideo] finds it ([read] is the reader's own entry
/// read), as an address of that route. A HEAD on the route first says whether the entry is there, and has the server read it ready for the
/// player. Throws "not_found" when it is not, and "unsupported" when the address is not a video or sound entry.
Future<ZimVideo> openZimVideoWeb({
  required String address,
  required Future<ZimBytes> Function(String address) read,
  required String zimTitle,
  double offsetS = 0,
  Future<int> Function(Uri url)? headStatus,
}) async {
  final bare = _bare(address);
  final ext = _ext(bare);
  if (!bare.startsWith('zim:') || !kZimMediaExtensions.contains(ext)) throw CacheSearchException('unsupported', 'not a video: $bare');
  final url = VideoMedia.zimEntry(bare);
  final Future<int> Function(Uri url) head = headStatus ?? (Uri u) async => (await http.Client().head(u)).statusCode;
  final status = await head(VideoMedia.resolve(url));
  if (status == 404) throw const CacheSearchException('not_found', 'That video is not in a ZIM on this device');
  if (status < 200 || status >= 300) throw CacheSearchException('internal', 'The server answered $status');
  final captions = <DownloadedCaption>[];
  for (final c in zimCaptionCandidates(bare)) {
    try {
      final cap = await read(c);
      if (cap.bytes.isEmpty) continue;
      final lang = RegExp(r'[_.-]([a-z]{2})\.(vtt|srt)$').firstMatch(c)?.group(1) ?? '';
      captions.add(DownloadedCaption(language: lang, label: 'On', path: VideoMedia.zimEntry(c)));
      break;
    } on CacheSearchException {
      continue;
    }
  }
  final title = Uri.decodeComponent(bare.split('/').last.replaceAll('_', ' ')).replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
  return ZimVideo(
    zimTitle: zimTitle,
    target: VideoTarget(
      isLocal: true,
      uuid: bare,
      title: title,
      offsetS: offsetS,
      durationS: 0,
      location: url,
      isAudio: _audioExtensions.contains(ext),
      captions: captions,
    ),
  );
}

Future<void> _write(File f, Uint8List bytes) async {
  final tmp = File('${f.path}.part');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(f.path);
}
