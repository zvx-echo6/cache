import 'package:flutter/material.dart';

import '../../theme.dart';
import 'widgets.dart';

/// Cache on Linux: the card at the top of Settings while Cache runs as the fallback cache account instead of the person who
/// installed it (the drop-in that names them is missing), so it cannot open their folders. The server works it out at start and
/// says so in `GET /api/version` (`run_installer_again`); it is gone after the next start as the person. No dismiss.
const kRunInstallerLine = "Cache can't open your folders. Run the installer again to fix this.";

/// What "How" shows: install.sh --repair from the release in use (its folder holds install.sh), which puts the person back from
/// /etc/cache-app/person with no download.
const kRunInstallerTitle = 'Run the installer again';
const kRunInstallerSteps = 'On this computer, open a terminal and run:';
const kRunInstallerCommand = 'sudo sh /opt/cache-app/current/install.sh --repair';
const kRunInstallerAfter = 'When sudo asks for a password, type your own. Cache starts again by itself; reload this page.';

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
              child: SelectableText(kRunInstallerCommand, style: TextStyle(fontFamily: 'monospace', fontSize: 14, color: k.text, height: 1.5)),
            ),
            const SizedBox(height: 10),
            const Text(kRunInstallerAfter),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}
