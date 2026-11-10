// Screen-size audit at 1440x900, dark theme (see audit_kit.dart). flutter test test_shots/audit/audit_1440x900_dark_test.dart --update-goldens
import 'package:cache/theme.dart';

import 'audit_kit.dart';
import 'guide_screens.dart';

void main() {
  auditSizeName = '1440x900';
  auditTheme = CacheThemeId.dark;
  guideScreens();
}
