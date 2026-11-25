import 'package:flutter/material.dart';

import '../../theme.dart';
import 'widgets.dart';

/// Cache on Linux: the card at the top of Settings while Cache runs as the fallback cache account instead of the person who
/// installed it (the drop-in that names them is missing), so it cannot open their folders. The server works it out at start and
/// says so in `GET /api/version` (`run_installer_again`); it is gone after the next start as the person. No dismiss.
const kRunInstallerLine = "Cache can't open your folders. Run the installer again to fix this.";

/// What "How" shows: the README's `sudo sh install.sh <tarball>`, with the installer first taken out of the download (it sits at
/// the top of the tarball as ./install.sh).
const kRunInstallerTitle = 'Run the installer again';
const kRunInstallerSteps =
    'On this computer, open a terminal in the folder with your newest Cache download (the file whose name starts with cache- '
    'and ends in .tar.gz). Then run these two commands:';
const kRunInstallerCommands = 'tar -xzf cache-*.tar.gz ./install.sh\nsudo sh install.sh cache-*.tar.gz';
const kRunInstallerAfter =
    'The first takes the installer out of the download, and the second runs it. When sudo asks for a password, type your own. '
    'Keep only the newest Cache download in that folder.';
const kRunInstallerDone = 'Cache starts again by itself. Reload this page and this message is gone. Your library, notebooks and settings stay.';

class RunInstallerCard extends StatelessWidget {
  const RunInstallerCard({super.key});

  @override
  Widget build(BuildContext context) => SettingsGroup(
    rows: [
      SettingsRow(
        key: const ValueKey('settings-run-installer'),
        leading: Icon(Icons.folder_off_outlined, size: 22, color: toneColor(context.t, Tone.warn)),
        title: kRunInstallerLine,
        // the whole sentence, never cut: the How link sits under it, not beside it
        titleLines: 4,
        statusWidget: Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('settings-run-installer-how'),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4), minimumSize: const Size(48, 32), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () => showHowToRunInstaller(context),
            child: const Text('How'),
          ),
        ),
      ),
    ],
  );
}

Future<void> showHowToRunInstaller(BuildContext context) {
  final k = context.t;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('how-to-run-installer'),
      title: const Text(kRunInstallerTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(kRunInstallerSteps),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: k.background, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(kRunInstallerCommands, style: TextStyle(fontFamily: 'monospace', fontSize: 14, color: k.text, height: 1.5)),
            ),
            const SizedBox(height: 10),
            const Text(kRunInstallerAfter),
            const SizedBox(height: 10),
            const Text(kRunInstallerDone),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}
