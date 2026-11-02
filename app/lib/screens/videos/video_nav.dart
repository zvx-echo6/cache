import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../video/video_state.dart';
import '../../video/zim_video.dart';
import 'player_screen.dart';
import 'video_screen.dart';

/// How the app reads a ZIM's entries for its videos (the reader's own entry read) and names the ZIM; null where no ZIM can be
/// read (tests).
class ZimVideoReader {
  const ZimVideoReader({required this.read, required this.titleOf, this.cacheDir});

  final Future<ZimBytes> Function(String address) read;

  /// The ZIM's title for its id ("Wikipedia").
  final String Function(String zimId) titleOf;

  /// Where a ZIM's video is copied to play (default: the app's temporary folder).
  final Future<Directory> Function()? cacheDir;
}

/// Plays a PeerTube video: the saved copy when it is downloaded (no connection needed), otherwise a stream, at [offsetS]
/// ([cited]: a cited moment, its cue marked). The player starts where the video was left otherwise.
Future<void> playVideo(
  BuildContext context,
  VideoState state, {
  required String video,
  String? instance,
  double? offsetS,
  bool cited = false,
  String? lang,
  List<VideoCaptionInfo> captionUrls = const [],
  List<VideoQuality> qualities = const [],
  String? channel,
}) async {
  final target = await state.resolve(video, instance: instance, offsetS: offsetS);
  if (!context.mounted) return;
  final saved = target.instance == null ? null : state.savedFor(target.instance!, target.uuid);
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (ctx) => PlayerScreen(
        target: target,
        captionUrls: target.isLocal ? const [] : captionUrls,
        thumbnail: saved?.thumbnailPath,
        prefs: state.prefs,
        cited: cited,
        citedLang: lang,
        qualities: target.isLocal ? const [] : qualities,
        savedQuality: saved == null ? null : (saved.isAudio ? 'Audio only' : saved.resolutionLabel),
        channel: saved?.channelName ?? channel,
        onRedownload: saved == null ? null : () => _redownload(ctx, state, saved),
      ),
    ),
  );
}

/// "Delete it and download again": the saved file that cannot play goes, and the same size downloads again (or the video page
/// opens to choose one when that size is gone).
Future<void> _redownload(BuildContext context, VideoState state, DownloadedVideo d) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await state.deleteSaved(d);
    final details = await state.details(d.instance, d.uuid);
    final same = details.options.where((o) => (o.isAudio && d.isAudio) || (!o.isAudio && !d.isAudio && o.label == d.resolutionLabel));
    if (same.isNotEmpty) {
      await state.download(details, same.first);
      nav.pop();
      return;
    }
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(videoErrorText(e))));
  }
  nav.pushReplacement(MaterialPageRoute<void>(builder: (_) => VideoScreen(video: state, instanceId: d.instance, uuid: d.uuid, title: d.title)));
}

/// Plays a ZIM's video entry ([address], `zim:<uuid>/<path>`) at [offsetS] in the same player, with its caption entry when the
/// ZIM has one beside it.
Future<void> playZimVideo(BuildContext context, VideoState state, ZimVideoReader zims, {required String address, double offsetS = 0, bool cited = false, String? lang}) async {
  final id = address.startsWith('zim:') ? address.substring(4).split('/').first : '';
  final dir = await (zims.cacheDir?.call() ?? getTemporaryDirectory().then((d) => Directory('${d.path}${Platform.pathSeparator}zim-video')));
  final v = await openZimVideo(address: address, read: zims.read, cacheDir: dir, zimTitle: zims.titleOf(id), offsetS: offsetS);
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(target: v.target, prefs: state.prefs, cited: cited, citedLang: lang, channel: 'In ${v.zimTitle}', where: 'On this device'),
    ),
  );
}

/// Opens the video a citation points at, at [offsetS], with the cited cue marked: a PeerTube link (the saved copy when it is
/// downloaded, no connection needed; otherwise a stream), a uuid or short uuid ([instance] only matters for a bare id), or a
/// ZIM's video entry (`zim:<uuid>/<path>`). A ZIM address the player cannot take (a caption file whose video is not in the ZIM,
/// or no ZIM reader) opens in the reader with [openInReader], as before. The Ask screen calls this for a video moment.
Future<void> openVideoCitation(
  BuildContext context,
  VideoState state, {
  required String video,
  double? offsetS,
  String? instance,
  String? lang,
  ZimVideoReader? zims,
  void Function(String address)? openInReader,
}) async {
  if (video.startsWith('zim:')) {
    if (zims != null && isZimMediaAddress(video)) {
      try {
        await playZimVideo(context, state, zims, address: video, offsetS: offsetS ?? 0, cited: true, lang: lang);
        return;
      } catch (_) {
        // not a video this player can take: the reader shows the entry
      }
    }
    if (openInReader != null) openInReader(video);
    return;
  }
  try {
    await playVideo(context, state, video: video, instance: instance, offsetS: offsetS, cited: offsetS != null, lang: lang);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("This video isn't saved on this device and can't be reached right now.\n${videoErrorText(e)}")));
    }
  }
}
