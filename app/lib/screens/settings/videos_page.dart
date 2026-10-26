import 'package:flutter/material.dart';

import '../../video/format.dart';
import '../videos/instance_screen.dart';
import '../videos/library_screen.dart';
import '../videos/videos_screen.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Videos: the saved videos and downloads, and the PeerTube instances that are connected. (Nothing technical exists for
/// videos yet, so there is no Advanced row.)
class VideosPage extends StatelessWidget {
  const VideosPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final v = deps.video;
    return ListenableBuilder(
      listenable: v,
      builder: (context, _) {
        final active = v.tasks.where((t) => t.isActive).length;
        return SettingsPage(
          title: 'Videos',
          children: [
            if (v.unavailable != null)
              NoteText(v.unavailable!)
            else ...[
              SettingsGroup(
                label: 'Downloads',
                rows: [
                  SettingsRow(
                    icon: Icons.download_done,
                    title: 'Saved on this phone',
                    status: [
                      Part(
                        v.saved.isEmpty && active == 0
                            ? 'Nothing yet'
                            : '${v.saved.length} video${v.saved.length == 1 ? '' : 's'} · ${formatBytes(v.savedBytes)}${active > 0 ? ' · $active downloading' : ''}',
                      ),
                    ],
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LibraryScreen(video: v))),
                  ),
                ],
              ),
              SettingsGroup(
                label: 'Instances',
                rows: [
                  for (final i in v.instances)
                    SettingsRow(
                      title: i.name,
                      status: [Part(v.userOf(i.id) == null ? i.host : '${i.host} · ${v.userOf(i.id)}')],
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InstanceScreen(video: v, instance: i))),
                    ),
                  SettingsRow(
                    icon: Icons.add,
                    title: 'Add an instance',
                    status: [Part(v.instances.isEmpty ? 'The address of any PeerTube site' : 'Another PeerTube site')],
                    onTap: () => addVideoInstance(context, v),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
