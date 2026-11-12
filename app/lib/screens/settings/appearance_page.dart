import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../car/car_support.dart';
import '../../theme.dart';
import 'widgets.dart';

/// Settings > Appearance: the theme, the size of the Modules screen's icons, Dark pages for the PDF reader, and (in a build with a
/// car screen) the Car group.
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
                    onTap: () => app.setTheme(id),
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
            // Only in a build with a car screen (Android Auto): what the car draws over the map.
            ValueListenableBuilder<bool>(
              valueListenable: carScreenSupported,
              builder: (context, supported, _) => supported
                  ? SettingsGroup(
                      label: 'Car',
                      rows: [
                        SwitchRow(
                          key: const ValueKey('car-climb-ahead'),
                          title: 'Climb ahead on the car screen',
                          value: app.carClimbAhead,
                          onChanged: app.setCarClimbAhead,
                        ),
                        SwitchRow(
                          key: const ValueKey('car-route-mini-map'),
                          title: 'Route mini map on the car screen',
                          value: app.carRouteMiniMap,
                          onChanged: app.setCarRouteMiniMap,
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }
}
