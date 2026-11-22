import '../platform.dart' as plat;

/// Where a browser gets a video's files and streams: Cache Server's `/api/video/` routes (server/src/video.rs). A same-origin
/// `<video>` or image sends the session cookie by itself, so these addresses need no token. Nothing here is used on a phone.
class VideoMedia {
  VideoMedia._();

  /// The saved videos' folder on the server (`<docs>/videos`), set by VideoState when it starts in a browser.
  static String? root;

  /// The address of a file of the saved videos (a video, caption or picture) from its path on the server. An address that is already
  /// one of the server's (a ZIM entry, see [zimEntry]) is returned as it is.
  static String file(String path) {
    if (path.startsWith('/api/')) return path;
    var rel = path;
    final r = root;
    if (r != null && path.startsWith('$r/')) {
      rel = path.substring(r.length + 1);
    } else {
      final i = path.lastIndexOf('/videos/');
      if (i >= 0) rel = path.substring(i + '/videos/'.length);
    }
    return '/api/video/media/${_encodePath(rel)}';
  }

  /// A stream, caption file or picture of a video site, read by the server. [url] is the site's address.
  static String stream(String url) => '/api/video/stream?u=${Uri.encodeQueryComponent(url)}';

  /// A video or caption entry of a ZIM, from its address `zim:<uuid>/<path>`.
  static String zimEntry(String address) {
    final rest = address.startsWith('zim:') ? address.substring(4) : address;
    return '/api/video/zim/${_encodePath(rest)}';
  }

  /// [url] as the page should load it: through the server in a browser, which may not read other sites; as it is elsewhere.
  static String remote(String url) => plat.isWeb && !url.startsWith('/api/') ? stream(url) : url;

  /// The address as a full URL (a `<video>` and an image take it relative to the page; this also makes tests and logs plain).
  static Uri resolve(String address) => Uri.base.resolve(address);

  static String _encodePath(String p) => [for (final s in p.split('/')) Uri.encodeComponent(s)].join('/');
}
