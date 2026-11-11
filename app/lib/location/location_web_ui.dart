import 'package:flutter/material.dart';

import 'location_service.dart';

/// Reloads this browser tab. The browser build sets it; until then it does nothing.
void Function() reloadPage = () {};

/// Cache on Linux: the question before the browser's own location prompt. The position is used exactly as on the phone: by the tools
/// on the Cache server, and by live sources that fetch for a place (weather, alerts). It never goes to web search.
Future<bool> showLocationPrePrompt(BuildContext context, {bool weather = false}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use your location?'),
        content: Text(
          weather
              ? "Your browser will ask to share this computer's location with Cache. Cache uses it for the weather where you are. "
                    'It is used by the live weather and alerts sources that fetch for a place, and by the tools on your Cache server. '
                    'It never goes to web search.'
              : "Your browser will ask to share this computer's location with Cache. Cache uses it to show where you are and to answer "
                    'questions about places near you. It is used exactly as on the phone: by the tools on your Cache server, and by live '
                    'sources that fetch for a place, such as weather and alerts. It never goes to web search.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          TextButton(key: const ValueKey('location-continue'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    ) ==
    true;

/// The way out of a block: a page cannot change the browser's permission, so it says where to click, and offers a reload.
Future<void> showHowToAllow(BuildContext context) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    key: const ValueKey('how-to-allow'),
    title: const Text('Allow location in your browser'),
    content: const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Cache cannot change this for you. To allow it:'),
        SizedBox(height: 8),
        Text('1. Click the icon at the left of the address bar.'),
        SizedBox(height: 4),
        Text('2. Set Location to Allow.'),
        SizedBox(height: 4),
        Text('3. Reload this page.'),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      FilledButton(
        key: const ValueKey('reload-page'),
        onPressed: () {
          Navigator.pop(ctx);
          reloadPage();
        },
        child: const Text('Reload page'),
      ),
    ],
  ),
);

/// A browser shares its location only on a secure page.
Future<void> showNeedsSecureAddress(BuildContext context) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    key: const ValueKey('needs-secure'),
    title: const Text('Needs a secure address'),
    content: const Text('Your browser only shares location on secure pages. Open Cache at its https address.'),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
  ),
);

/// The map's one line when there is no position, in the browser's words.
SnackBar webLocationSnack(LocationProblem? problem, {VoidCallback? onHowToAllow, VoidCallback? onTryAgain}) {
  final text = switch (problem) {
    LocationProblem.off => 'Location is off. Switch on "Show my position" in Layers.',
    LocationProblem.permissionDenied => 'Cache was not allowed to read your location.',
    LocationProblem.permissionBlocked => 'Location is blocked in this browser.',
    LocationProblem.serviceOff => 'This computer cannot find its location. Check its location service, then try again.',
    LocationProblem.noFix => 'Could not get a position yet. Try again.',
    null => 'No position yet.',
  };
  return SnackBar(
    content: Text(text),
    action: switch (problem) {
      LocationProblem.permissionBlocked => SnackBarAction(label: 'How to allow', onPressed: onHowToAllow ?? () {}),
      LocationProblem.serviceOff => SnackBarAction(label: 'Try again', onPressed: onTryAgain ?? () {}),
      _ => null,
    },
  );
}

/// Weather's line when "Where I am" cannot be turned on, in the browser's words.
SnackBar webWeatherBlockedSnack({VoidCallback? onHowToAllow}) => SnackBar(
  content: const Text('Could not turn on. Location is blocked in this browser.'),
  action: SnackBarAction(label: 'How to allow', onPressed: onHowToAllow ?? () {}),
);
