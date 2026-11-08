// Screen-size audit at 844x390, light theme (see audit_kit.dart). flutter test test_shots/audit/audit_844x390_light_test.dart --update-goldens
import 'package:cache/theme.dart';

import 'audit_kit.dart';
import 'guide_screens.dart';

void main() {
  auditSizeName = '844x390';
  auditTheme = CacheThemeId.light;
  guideScreens();
}
