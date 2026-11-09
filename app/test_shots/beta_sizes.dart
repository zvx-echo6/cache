// The beta checklist's sizes (Cache 1.1's beta condition: every screen at every size, light and dark). A render test that takes them
// draws at these four sizes instead of its own when run with --dart-define=BETA_SIZES=true, and names each picture by its size
// (390x844 and so on). Not part of the test suite.

import 'package:flutter/widgets.dart';

/// Run with --dart-define=BETA_SIZES=true: draw at [kBetaSizes].
const bool kBeta = bool.fromEnvironment('BETA_SIZES');

/// A phone upright and sideways, a 12.9" tablet upright, a desktop browser window (logical points).
const Map<String, Size> kBetaSizes = {
  '390x844': Size(390, 844),
  '844x390': Size(844, 390),
  '1024x1366': Size(1024, 1366),
  '1440x900': Size(1440, 900),
};

/// The system bars' room at [s]: a notched phone upright and sideways, a tablet's status bar, none in a browser window.
EdgeInsets betaInsets(Size s) => s.width < 600
    ? const EdgeInsets.only(top: 47, bottom: 34)
    : s.height < 480
    ? const EdgeInsets.only(left: 47, right: 47, bottom: 21)
    : s.width < 1280
    ? const EdgeInsets.only(top: 24, bottom: 20)
    : EdgeInsets.zero;

/// Pixels per point at [s] (2 on a phone, 1 otherwise, as the audit draws).
double betaRatio(Size s) => s.shortestSide < 600 ? 2 : 1;

/// [s] shows the phone layout's one pane (narrow, or a phone held sideways).
bool betaOnePane(Size s) => s.width < 640 || s.height < 480;
