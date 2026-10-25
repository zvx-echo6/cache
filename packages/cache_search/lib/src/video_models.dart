// Typed views of the JSON the cs_video_* calls return (shapes: native/include/cache_search.h, "videos").

Map<String, dynamic> _m(Object? o) => (o as Map).cast<String, dynamic>();
List<Map<String, dynamic>> _list(Object? o) => [for (final x in (o as List? ?? const [])) _m(x)];

/// A PeerTube instance the user added.
class VideoInstance {
  const VideoInstance({required this.id, required this.url, required this.name, required this.version});

  factory VideoInstance.fromJson(Map<String, dynamic> j) => VideoInstance(
        id: j['id'] as String,
        url: j['url'] as String,
        name: (j['name'] ?? j['id']) as String,
        version: (j['version'] ?? '') as String,
      );

  final String id;
  final String url;
  final String name;
  final String version;

  /// The address as people read it: no scheme.
  String get host => url.replaceFirst(RegExp(r'^https?://'), '');
}

/// The tokens a login returns. The core keeps nothing: the app stores them in its secure storage.
class VideoTokens {
  const VideoTokens({required this.accessToken, this.refreshToken, this.expiresIn});

  factory VideoTokens.fromJson(Map<String, dynamic> j) =>
      VideoTokens(accessToken: j['access_token'] as String, refreshToken: j['refresh_token'] as String?, expiresIn: j['expires_in'] as int?);

  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;
}

class VideoChannel {
  const VideoChannel({required this.name, required this.displayName, required this.handle, this.host = '', this.avatar, this.description, this.followers = 0});

  factory VideoChannel.fromJson(Map<String, dynamic> j) => VideoChannel(
        name: (j['name'] ?? '') as String,
        displayName: (j['display_name'] ?? j['name'] ?? '') as String,
        handle: (j['handle'] ?? j['name'] ?? '') as String,
        host: (j['host'] ?? '') as String,
        avatar: j['avatar'] as String?,
        description: j['description'] as String?,
        followers: (j['followers'] ?? 0) as int,
      );

  final String name;
  final String displayName;
  final String handle;
  final String host;
  final String? avatar;
  final String? description;
  final int followers;
}

class VideoItem {
  const VideoItem({
    required this.uuid,
    required this.title,
    required this.durationS,
    required this.channel,
    this.thumbnail,
    this.publishedAt,
    this.views = 0,
    this.isLive = false,
    this.nsfw = false,
    this.downloaded = false,
  });

  factory VideoItem.fromJson(Map<String, dynamic> j) => VideoItem(
        uuid: j['uuid'] as String,
        title: (j['title'] ?? '') as String,
        durationS: (j['duration_s'] ?? 0) as int,
        channel: VideoChannel.fromJson(_m(j['channel'])),
        thumbnail: j['thumbnail'] as String?,
        publishedAt: j['published_at'] as String?,
        views: (j['views'] ?? 0) as int,
        isLive: (j['is_live'] ?? false) as bool,
        nsfw: (j['nsfw'] ?? false) as bool,
        downloaded: (j['downloaded'] ?? false) as bool,
      );

  final String uuid;
  final String title;
  final int durationS;
  final VideoChannel channel;
  final String? thumbnail;
  final String? publishedAt;
  final int views;
  final bool isLive;
  final bool nsfw;
  final bool downloaded;
}

class VideoPage {
  const VideoPage({required this.total, required this.start, required this.videos});

  factory VideoPage.fromJson(Map<String, dynamic> j) => VideoPage(
        total: (j['total'] ?? 0) as int,
        start: (j['start'] ?? 0) as int,
        videos: [for (final v in _list(j['videos'])) VideoItem.fromJson(v)],
      );

  final int total;
  final int start;
  final List<VideoItem> videos;
}

class ChannelPage {
  const ChannelPage({required this.total, required this.start, required this.channels});

  factory ChannelPage.fromJson(Map<String, dynamic> j) => ChannelPage(
        total: (j['total'] ?? 0) as int,
        start: (j['start'] ?? 0) as int,
        channels: [for (final c in _list(j['channels'])) VideoChannel.fromJson(c)],
      );

  final int total;
  final int start;
  final List<VideoChannel> channels;
}

/// One download choice: a resolution (key "480") or audio only (key "audio"), with its size when known.
class VideoOption {
  const VideoOption({required this.key, required this.label, required this.isAudio, this.size, this.source = 'web'});

  factory VideoOption.fromJson(Map<String, dynamic> j) => VideoOption(
        key: j['key'] as String,
        label: (j['label'] ?? j['key']) as String,
        isAudio: j['kind'] == 'audio',
        size: j['size'] as int?,
        source: (j['source'] ?? 'web') as String,
      );

  final String key;
  final String label;
  final bool isAudio;
  final int? size;
  final String source;
}

class VideoCaptionInfo {
  const VideoCaptionInfo({required this.language, required this.label, required this.url, this.automatic = false});

  factory VideoCaptionInfo.fromJson(Map<String, dynamic> j) => VideoCaptionInfo(
        language: (j['language'] ?? '') as String,
        label: (j['label'] ?? j['language'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        automatic: (j['automatic'] ?? false) as bool,
      );

  final String language;
  final String label;
  final String url;
  final bool automatic;
}

/// The video page: details, download choices, stream addresses.
class VideoDetails {
  const VideoDetails({
    required this.instance,
    required this.uuid,
    required this.title,
    required this.durationS,
    required this.channel,
    required this.downloadEnabled,
    required this.options,
    required this.captions,
    this.description,
    this.thumbnail,
    this.preview,
    this.publishedAt,
    this.views = 0,
    this.isLive = false,
    this.hlsUrl,
    this.mp4Url,
    this.needsAuth = false,
    this.downloadedResolution,
  });

  factory VideoDetails.fromJson(Map<String, dynamic> j) {
    final stream = _m(j['stream'] ?? const {});
    final dl = j['downloaded'];
    return VideoDetails(
      instance: j['instance'] as String,
      uuid: j['uuid'] as String,
      title: (j['title'] ?? '') as String,
      description: j['description'] as String?,
      durationS: (j['duration_s'] ?? 0) as int,
      channel: VideoChannel.fromJson(_m(j['channel'])),
      thumbnail: j['thumbnail'] as String?,
      preview: j['preview'] as String?,
      publishedAt: j['published_at'] as String?,
      views: (j['views'] ?? 0) as int,
      isLive: (j['is_live'] ?? false) as bool,
      downloadEnabled: (j['download_enabled'] ?? false) as bool,
      options: [for (final o in _list(j['options'])) VideoOption.fromJson(o)],
      captions: [for (final c in _list(j['captions'])) VideoCaptionInfo.fromJson(c)],
      hlsUrl: stream['hls'] as String?,
      mp4Url: stream['mp4'] as String?,
      needsAuth: (stream['needs_auth'] ?? false) as bool,
      downloadedResolution: dl is Map ? dl['resolution'] as String? : null,
    );
  }

  final String instance;
  final String uuid;
  final String title;
  final String? description;
  final int durationS;
  final VideoChannel channel;
  final String? thumbnail;
  final String? preview;
  final String? publishedAt;
  final int views;
  final bool isLive;
  final bool downloadEnabled;
  final List<VideoOption> options;
  final List<VideoCaptionInfo> captions;
  final String? hlsUrl;
  final String? mp4Url;
  final bool needsAuth;

  /// The resolution key already on this phone ("480", "audio"), or null.
  final String? downloadedResolution;

  bool get canStream => !isLive && (hlsUrl != null || mp4Url != null);
}

class DownloadedCaption {
  const DownloadedCaption({required this.language, required this.label, required this.path});

  factory DownloadedCaption.fromJson(Map<String, dynamic> j) =>
      DownloadedCaption(language: (j['language'] ?? '') as String, label: (j['label'] ?? j['language'] ?? '') as String, path: j['path'] as String);

  final String language;
  final String label;
  final String path;
}

/// A video saved on this phone (its manifest).
class DownloadedVideo {
  const DownloadedVideo({
    required this.instance,
    required this.uuid,
    required this.title,
    required this.channelName,
    required this.durationS,
    required this.isAudio,
    required this.resolutionLabel,
    required this.size,
    required this.path,
    required this.captions,
    this.thumbnailPath,
    this.downloadedAt,
  });

  factory DownloadedVideo.fromJson(Map<String, dynamic> j) => DownloadedVideo(
        instance: j['instance'] as String,
        uuid: j['uuid'] as String,
        title: (j['title'] ?? '') as String,
        channelName: (j['channel'] is Map ? (j['channel'] as Map)['display_name'] : '') as String? ?? '',
        durationS: (j['duration_s'] ?? 0) as int,
        isAudio: j['kind'] == 'audio',
        resolutionLabel: (j['resolution_label'] ?? j['resolution'] ?? '') as String,
        size: (j['size'] ?? 0) as int,
        path: j['path'] as String,
        thumbnailPath: j['thumbnail_path'] as String?,
        downloadedAt: j['downloaded_at'] as String?,
        captions: [for (final c in _list(j['captions'])) DownloadedCaption.fromJson(c)],
      );

  final String instance;
  final String uuid;
  final String title;
  final String channelName;
  final int durationS;
  final bool isAudio;
  final String resolutionLabel;
  final int size;
  final String path;
  final String? thumbnailPath;
  final String? downloadedAt;
  final List<DownloadedCaption> captions;
}

/// Where to open a video for a citation: the file on this phone, or a stream.
class VideoTarget {
  const VideoTarget({
    required this.isLocal,
    required this.uuid,
    required this.title,
    required this.offsetS,
    required this.durationS,
    required this.location,
    this.isAudio = false,
    this.isHls = false,
    this.needsAuth = false,
    this.captions = const [],
    this.instance,
  });

  factory VideoTarget.fromJson(Map<String, dynamic> j) {
    final local = j['kind'] == 'local';
    return VideoTarget(
      isLocal: local,
      uuid: j['uuid'] as String,
      title: (j['title'] ?? '') as String,
      offsetS: ((j['offset_s'] ?? 0) as num).toDouble(),
      durationS: (j['duration_s'] ?? 0) as int,
      location: (local ? j['path'] : j['url']) as String,
      isAudio: local && j['media'] == 'audio',
      isHls: !local && j['format'] == 'hls',
      needsAuth: (j['needs_auth'] ?? false) as bool,
      captions: local ? [for (final c in _list(j['captions'])) DownloadedCaption.fromJson(c)] : const [],
      instance: j['instance'] as String?,
    );
  }

  final bool isLocal;
  final String uuid;
  final String title;
  final double offsetS;
  final int durationS;

  /// A file path (local) or a URL (stream).
  final String location;
  final bool isAudio;
  final bool isHls;
  final bool needsAuth;
  final List<DownloadedCaption> captions;
  final String? instance;
}
