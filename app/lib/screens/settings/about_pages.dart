import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../theme.dart';
import '../../version.dart';
import 'widgets.dart';

/// Where the credits text is bundled (a copy of CREDITS.md at the repository root; a test keeps them equal).
const String kCreditsAsset = 'assets/credits.md';

/// Settings > About and credits: the version, the licence, the credits and the open-source licences.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'About and credits',
      children: [
        SettingsGroup(
          rows: [
            SettingsRow(title: 'Version', status: const [Part(kAppVersion)]),
            SettingsRow(
              title: 'Licence',
              status: const [Part('$kAppLicenceId. Free software: you may share and change it under the GNU Affero General Public License, version 3 or later.')],
            ),
          ],
        ),
        SettingsGroup(
          rows: [
            SettingsRow(
              key: const ValueKey('credits'),
              icon: Icons.favorite_border,
              title: 'Credits',
              status: const [Part('The maps, data, libraries and art Cache is built on')],
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CreditsPage())),
            ),
            SettingsRow(
              key: const ValueKey('licences'),
              icon: Icons.description_outlined,
              title: 'Open-source licences',
              status: const [Part('The full licence text of every package')],
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Cache',
                applicationVersion: kAppVersion,
                applicationLegalese: 'Copyright (C) 2026 Happy Little LLC. Licensed $kAppLicenceId. Third-party credits are in Settings > About and credits > Credits.',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The credits: every library, data source and asset with its licence, from the bundled CREDITS.md.
class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key, this.loader});

  /// Test hook: where the text comes from (the bundled asset by default).
  final Future<String> Function()? loader;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Credits')),
      body: FutureBuilder<String>(
        future: (loader ?? () => rootBundle.loadString(kCreditsAsset))(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text("Couldn't load the credits.", style: TextStyle(fontSize: 16, color: k.secondary)));
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return Markdown(
            data: snap.data!,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(fontSize: 15, height: 1.45, color: k.text),
              listBullet: TextStyle(fontSize: 15, color: k.text),
              h1: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: k.text),
              h2: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text),
              h3: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text),
              a: TextStyle(color: k.accent),
            ),
          );
        },
      ),
    );
  }
}
