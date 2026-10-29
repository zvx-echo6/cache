import 'package:flutter/material.dart';

import '../../browse/catalogue_screen.dart' as kiwix;
import '../../video/format.dart';
import '../libraries_screen.dart';
import '../sources_screen.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Library: the reading sources on the phone, and getting more of them. (Nothing technical exists for the Library yet,
/// so there is no Advanced row.)
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  SettingsDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    deps.hub.storage.measure();
  }

  @override
  Widget build(BuildContext context) {
    final s = deps.sources;
    return ListenableBuilder(
      listenable: Listenable.merge([s, deps.hub.storage, ?deps.browse.libraries]),
      builder: (context, _) {
        final u = deps.hub.storage;
        final n = s.zims.length;
        return SettingsPage(
          title: 'Library',
          children: [
            SettingsGroup(
              rows: [
                SettingsRow(
                  icon: Icons.menu_book_outlined,
                  title: 'Reading sources',
                  status: [
                    Part(
                      s.unavailable != null && n == 0
                          ? 'Not available'
                          : n == 0
                          ? 'No sources yet. Add a file or get one.'
                          : '$n ${n == 1 ? 'source' : 'sources'}${u.measured ? ' · ${formatBytes(u.libraryBytes)}' : ''} (with their search indexes)',
                    ),
                  ],
                  onTap: () {
                    s.refresh();
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SourcesScreen(sources: s))).then((_) => deps.hub.storage.measure());
                  },
                ),
                if (deps.browse.libraries != null)
                  SettingsRow(
                    icon: Icons.library_books_outlined,
                    title: 'Libraries',
                    status: [Part(deps.browse.libraries!.summary)],
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => LibrariesScreen(libraries: deps.browse.libraries!)))
                        .then((_) => deps.hub.storage.measure()),
                  ),
                SettingsRow(
                  icon: Icons.cloud_download_outlined,
                  title: 'Get more from the Kiwix library',
                  status: const [Part('Wikipedia, medical guides and more')],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => kiwix.CatalogueScreen(browse: deps.browse))),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
