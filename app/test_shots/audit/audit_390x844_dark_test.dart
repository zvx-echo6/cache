// Screen-size audit at 390x844, dark theme (see audit_kit.dart). flutter test test_shots/audit/audit_390x844_dark_test.dart --update-goldens
import 'package:cache/theme.dart';

import 'audit_kit.dart';
import 'guide_screens.dart';

void main() {
  auditSizeName = '390x844';
  auditTheme = CacheThemeId.dark;
  guideScreens();
}
