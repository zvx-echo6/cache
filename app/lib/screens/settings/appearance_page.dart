import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme.dart';
import 'widgets.dart';

/// Settings > Appearance: the theme, the size of the Modules screen's icons, and Dark pages for the PDF reader.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final k = context.t;
        return SettingsPage(
          title: 'Appearance',
          children: [
            SettingsGroup(
              label: 'Theme',
              rows: [
                for (final id in CacheThemeId.values)
                  SettingsRow(
                    key: ValueKey('theme-${id.name}'),
                    title: id.label,
                    status: [Part(id.hint)],
                    leading: Icon(id == app.theme ? Icons.radio_button_checked : Icons.radio_button_off, color: id == app.theme ? k.accent : k.secondary),
                    chevron: false,
                    onTap: () => app.chooseTheme(id),
                  ),
              ],
            ),
            SettingsGroup(
              label: 'Module icons',
              rows: [
                for (final (large, title, hint) in const [(false, 'Small', 'Three across'), (true, 'Large', 'Bigger, easier to tap')])
                  SettingsRow(
                    key: ValueKey('module-icons-${large ? 'large' : 'small'}'),
                    title: title,
                    status: [Part(hint)],
                    leading: Icon(
                      large == app.largeModuleIcons ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: large == app.largeModuleIcons ? k.accent : k.secondary,
                    ),
                    chevron: false,
                    onTap: () => app.setLargeModuleIcons(large),
                  ),
              ],
            ),
            SettingsGroup(
              label: 'PDF pages',
              rows: [
                SwitchRow(
                  key: const ValueKey('pdf-dark-pages'),
                  title: 'Dark pages',
                  status: [Part(app.darkPdfPages ? 'On: in a dark theme, pages are light on dark. Pictures look wrong' : 'Off: pages look as printed, dimmed in a dark theme')],
                  value: app.darkPdfPages,
                  onChanged: app.setDarkPdfPages,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
