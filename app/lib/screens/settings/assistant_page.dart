import 'package:flutter/material.dart';

import '../../chat/answer_reports.dart';
import '../../linux_ui.dart';
import '../../location/location_service.dart';
import '../../location/location_web_ui.dart';
import '../../location/position_source.dart' show LocationPermissionState;
import '../../theme.dart';
import '../../models/model_downloads.dart' show ModelDownloads, modelDownloadLine;
import '../answer_reports_ui.dart';
import '../history_drawer.dart';
import '../models_screen.dart';
import 'deps.dart';
import 'api_keys_page.dart';
import 'widgets.dart';

/// Settings > Assistant: the model, the web search service and its switch, and the saved conversations.
class AssistantPage extends StatelessWidget {
  AssistantPage({super.key, required this.deps, AnswerReports? reports}) : reports = reports ?? AnswerReports.shared;

  final SettingsDeps deps;
  final AnswerReports reports;

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all conversations?'),
        content: const Text('Every saved chat is removed from this device. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete all', style: TextStyle(color: ctx.t.emergency)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    deps.chat.deleteAllConversations();
    say(context, 'All conversations deleted');
  }

  /// A reported answer's row: the chat it came from, shown in Ask (a chat that was deleted since says so).
  void _openReportChat(BuildContext context, int id) {
    if (!deps.chat.hasConversation(id)) {
      say(context, 'That chat is gone');
      return;
    }
    deps.chat.openConversation(id);
    deps.onOpenAsk?.call();
  }

  void _openConversations(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Saved conversations')),
          body: HistoryDrawer(chat: deps.chat, width: double.infinity, onChosen: deps.onOpenAsk),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = deps.app;
    final web = deps.hub.webSearch;
    return ListenableBuilder(
      listenable: Listenable.merge([app, web, deps.chat.historyRevision, reports, ?ModelDownloads.shared]),
      builder: (context, _) {
        final m = app.active;
        final resting = app.resting;
        final List<Part> modelStatus = app.loading != null
            ? const [Part('Loading…')]
            : m == null && modelDownloadLine() != null
            ? [Part(modelDownloadLine()!)]
            : m == null && resting != null
            // the chosen model, not in memory now (a cold start leaves it resting): it loads when Ask opens
            ? joinParts([
                const [Part('On this device')],
                [Part(app.sizeLine(resting))],
                const [Part('Loads when you open Ask')],
              ])
            : m == null
            ? const [Part('No model chosen', Tone.warn)]
            : joinParts([
                const [Part('On this device')],
                [Part(app.sizeLine(m))],
                const [Part('Ready', Tone.ok)],
              ]);
        final count = deps.chat.store?.list().length ?? 0;
        return SettingsPage(
          title: 'Cache model and web search',
          children: [
            SettingsGroup(
              label: 'Model',
              rows: [
                SettingsRow(
                  title: m != null ? app.displayName(m) : resting != null && app.loading == null && modelDownloadLine() == null ? app.displayName(resting) : 'Choose a model',
                  status: modelStatus,
                  onTap: () => openModels(context, app),
                ),
              ],
            ),
            SettingsGroup(
              label: 'Web search',
              rows: [
                SwitchRow(
                  title: 'Search the web when online',
                  status: const [Part('Kagi searches the web for the assistant')],
                  value: web.settings.webSearchOn,
                  onChanged: (v) => web.setEnabled(v),
                ),
                ApiKeyShortcutRow(deps: deps, providerId: 'kagi'),
              ],
            ),
            SettingsGroup(label: 'Location', rows: [UseMyLocationRow(location: deps.location)]),
            SettingsGroup(
              label: 'Conversations',
              rows: [
                SettingsRow(
                  title: 'Saved conversations',
                  status: [Part('$count on this device')],
                  onTap: () => _openConversations(context),
                ),
                FutureBuilder<int>(
                  future: reports.count(),
                  builder: (context, snap) => SettingsRow(
                    key: const ValueKey('reported-answers'),
                    title: 'Reported answers',
                    status: [Part(snap.hasData ? (snap.data == 0 ? 'None' : '${snap.data} on this device') : '…')],
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => ReportedAnswersPage(reports: reports, onOpenChat: (id) => _openReportChat(context, id))),
                    ),
                  ),
                ),
                SettingsRow(
                  title: 'Delete all conversations',
                  status: const [Part("Asks first. This can't be undone.")],
                  danger: true,
                  chevron: false,
                  onTap: () => _deleteAll(context),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// "Use my location": Cache's own switch, the same one as the + menu in Ask. Cache uses the location whenever the phone allows it and
/// never asks; when the phone blocks it, the row says so and opens the phone's settings.
class UseMyLocationRow extends StatelessWidget {
  const UseMyLocationRow({super.key, required this.location, this.insecure = false});

  final LocationService location;

  /// Cache on Linux: the page is not on a secure address, so the browser refuses location.
  final bool insecure;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: location,
    builder: (context, _) {
      final blocked = location.permission == LocationPermissionState.deniedForever || location.problem == LocationProblem.permissionBlocked;
      final serviceOff = location.problem == LocationProblem.serviceOff;
      if (linuxUi) {
        if (insecure || blocked || serviceOff) {
          return SettingsRow(
            key: const ValueKey('use-my-location-row'),
            title: 'Use my location',
            status: [
              Part(
                insecure
                    ? 'Needs a secure address'
                    : blocked
                    ? 'Blocked in this browser'
                    : 'This computer cannot find its location',
                Tone.warn,
              ),
            ],
            trailing: RowButton(
              label: insecure
                  ? 'Why?'
                  : blocked
                  ? 'How to allow'
                  : 'Try again',
              onPressed: insecure
                  ? () => showNeedsSecureAddress(context)
                  : blocked
                  ? () => showHowToAllow(context)
                  : () => location.setEnabled(true),
            ),
          );
        }
        return SwitchRow(
          key: const ValueKey('use-my-location-row'),
          title: 'Use my location',
          status: const [Part("Uses this browser's location")],
          value: location.enabled,
          onChanged: location.setEnabled,
        );
      }
      if (blocked || serviceOff) {
        return SettingsRow(
          key: const ValueKey('use-my-location-row'),
          title: 'Use my location',
          status: [Part(blocked ? "Blocked in the device's settings" : "The device's location is switched off", Tone.warn)],
          trailing: RowButton(label: 'Device settings', onPressed: blocked ? location.openAppSettings : location.openLocationSettings),
        );
      }
      return SwitchRow(
        key: const ValueKey('use-my-location-row'),
        title: 'Use my location',
        status: const [Part('Cache finds things near you')],
        value: location.enabled,
        onChanged: location.setEnabled,
      );
    },
  );
}
