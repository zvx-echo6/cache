import 'package:flutter/material.dart';

import '../../video/video_state.dart';
import 'player_screen.dart';

/// Opens the video a citation points at: the saved copy when it is downloaded (no connection needed), otherwise a
/// stream, starting at [offsetS]. [video] is a PeerTube link, a uuid or a short uuid; [instance] only matters for a
/// bare id. The Ask screen calls this when a citation is a video moment (a library point with a link and a time).
Future<void> openVideoCitation(BuildContext context, VideoState state, {required String video, double? offsetS, String? instance}) async {
  try {
    final target = await state.resolve(video, instance: instance, offsetS: offsetS);
    if (!context.mounted) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PlayerScreen(target: target)));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("This video isn't saved on the phone and can't be reached right now.\n${videoErrorText(e)}")));
    }
  }
}
