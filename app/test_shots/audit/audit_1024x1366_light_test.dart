// Screen-size audit at 1024x1366, light theme (see audit_kit.dart). flutter test test_shots/audit/audit_1024x1366_light_test.dart --update-goldens
import 'package:cache/theme.dart';

import 'audit_kit.dart';
import 'guide_screens.dart';

void main() {
  auditSizeName = '1024x1366';
  auditTheme = CacheThemeId.light;
  guideScreens();
}
