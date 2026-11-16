// The Cache Server helper (no Flutter) names the group of a synced setting by the key's first part (settings_files.dart,
// settingsGroupOf). The phone's SyncedSetting.group is the truth the link record's off_groups follow: the two must agree for
// every key, so a key added to one table and not the other fails here.

import 'package:cache/layout/layout_state.dart';
import 'package:cache/sharing/settings_files.dart';
import 'package:cache/sharing/synced_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

void main() {
  testWidgets('settingsGroupOf gives every key in kSettingsFileMap the group name appSyncedSettings gives it', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    final phone = {
      for (final s in appSyncedSettings(app: r.app, layout: layout, settings: r.settings, maps: r.maps, weather: r.weather)) s.key: s.group.name,
    };
    expect(kSettingsFileMap.keys.toSet(), phone.keys.toSet());
    for (final k in kSettingsFileMap.keys) {
      expect(settingsGroupOf(k), phone[k], reason: '$k: the helper and the phone name different groups');
      expect(settingsGroupOf(k), isNotEmpty);
    }
    layout.dispose();
    await r.dispose(tester);
  });
}
