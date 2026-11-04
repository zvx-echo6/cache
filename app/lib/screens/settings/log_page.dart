import 'package:flutter/material.dart';

import '../../platform/app_log.dart';
import '../../platform/app_log_io.dart' show appLogSize, shareAppLog;
import '../../theme.dart';
import 'widgets.dart';

/// Settings > Log: how much Cache keeps in its own log on this device, Share log and Clear log.
class LogPage extends StatelessWidget {
  const LogPage({super.key, this.log});

  /// The log (the app's own by default).
  final AppLog? log;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final log = this.log ?? appLog;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => SettingsPage(
        title: 'Log',
        children: [
          SettingsGroup(
            label: 'Log level',
            rows: [
              for (final l in LogLevel.values)
                SettingsRow(
                  key: ValueKey('log-${l.name}'),
                  title: l == LogLevel.standard ? '${logLevelTitle(l)} (default)' : logLevelTitle(l),
                  status: [Part(logLevelDetail(l))],
                  trailing: log.level == l ? Icon(Icons.check, color: k.accent) : null,
                  chevron: false,
                  onTap: () => log.setLevel(l),
                ),
            ],
          ),
          const NoteText('The log stays on this device. Nothing leaves it unless you tap Share log.'),
          SettingsGroup(
            rows: [
              SettingsRow(
                key: const ValueKey('log-share'),
                icon: Icons.ios_share,
                title: 'Share log',
                status: [Part(log.dir == null ? 'No log yet' : appLogSize())],
                onTap: log.dir == null ? null : () => shareAppLog(context),
              ),
              SettingsRow(
                key: const ValueKey('log-clear'),
                icon: Icons.delete_outline,
                title: 'Clear log',
                chevron: false,
                onTap: log.dir == null ? null : log.clear,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
