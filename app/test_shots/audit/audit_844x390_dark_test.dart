// Screen-size audit at 844x390, dark theme (see audit_kit.dart). flutter test test_shots/audit/audit_844x390_dark_test.dart --update-goldens
import 'package:cache/theme.dart';

import 'audit_kit.dart';
import 'guide_screens.dart';

void main() {
  auditSizeName = '844x390';
  auditTheme = CacheThemeId.dark;
  guideScreens();
}
