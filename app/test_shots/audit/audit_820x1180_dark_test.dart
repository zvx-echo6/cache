// Screen-size audit at 820x1180, dark theme (see audit_kit.dart). flutter test test_shots/audit/audit_820x1180_dark_test.dart --update-goldens
import 'package:cache/theme.dart';

import 'audit_kit.dart';
import 'guide_screens.dart';

void main() {
  auditSizeName = '820x1180';
  auditTheme = CacheThemeId.dark;
  guideScreens();
}
