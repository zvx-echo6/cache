import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../settings/hub.dart';
import '../../theme.dart';
import '../../version.dart';
import 'widgets.dart';

/// Where the source code is published.
const String kSourceUrl = 'https://github.com/zvx-echo6/cache';

/// Where the credits text is bundled (a copy of CREDITS.md at the repository root; a test keeps them equal).
const String kCreditsAsset = 'assets/credits.md';

/// Settings > Credits and licences: the version, the licence, the credits and the open-source licences.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.openUrl = openInSystemBrowser, this.version = installedVersion});

  /// How a link is opened (the phone's browser; a test passes its own).
  final UrlOpener openUrl;

  /// The installed version and build (read from the phone; a test passes its own).
  final Future<String> Function() version;

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Credits and licences',
      children: [
        SettingsGroup(
          rows: [
            SettingsRow(title: 'Version', statusWidget: _VersionText(version: version)),
            SettingsRow(
              title: 'Licence',
              status: const [Part('$kAppLicenceId. Free software: you may share and change it under the GNU Affero General Public License, version 3 or later.')],
            ),
            SettingsRow(
              key: const ValueKey('source-code'),
              title: 'Source code',
              statusWidget: _SourceNotice(openUrl: openUrl),
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
                applicationLegalese: 'Copyright (C) 2026 Happy Little LLC. Licensed $kAppLicenceId. Third-party credits are in Settings > Credits and licences > Credits.',
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

/// The installed version and build; the version this code was built as until the phone has answered.
class _VersionText extends StatefulWidget {
  const _VersionText({required this.version});

  final Future<String> Function() version;

  @override
  State<_VersionText> createState() => _VersionTextState();
}

class _VersionTextState extends State<_VersionText> {
  late final Future<String> _read = widget.version();

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _read,
    initialData: kAppVersion,
    builder: (context, snap) => statusText(context, [Part(snap.data ?? kAppVersion)]),
  );
}

/// The licence's permission in words for where this build came from: TestFlight on iOS, Google Play on Android.
String sourceNoticeEnd(TargetPlatform platform) => switch (platform) {
  TargetPlatform.iOS => ', including builds you receive through TestFlight.',
  TargetPlatform.android => ', including builds you get from Google Play.',
  _ => '.',
};

/// Where the source is and what testers may do with it. The address is tappable (opens the browser) and the text is selectable.
class _SourceNotice extends StatefulWidget {
  const _SourceNotice({required this.openUrl});

  final UrlOpener openUrl;

  @override
  State<_SourceNotice> createState() => _SourceNoticeState();
}

class _SourceNoticeState extends State<_SourceNotice> {
  late final TapGestureRecognizer _tap = TapGestureRecognizer()..onTap = () => widget.openUrl(kSourceUrl);

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return SelectableText.rich(
      TextSpan(
        style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary),
        children: [
          const TextSpan(text: 'Cache is free software under the GNU AGPL-3.0 (or any later version). Copyright (C) 2026 Happy Little LLC. The source code is at '),
          TextSpan(
            text: kSourceUrl,
            recognizer: _tap,
            style: TextStyle(decoration: TextDecoration.underline, color: k.accent),
          ),
          TextSpan(text: '. You may copy, share and modify Cache under the AGPL${sourceNoticeEnd(defaultTargetPlatform)}'),
        ],
      ),
    );
  }
}
