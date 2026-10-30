import 'package:cache_search/cache_search.dart';

import '../settings/data_policy.dart';

/// Plain words for why a map download stopped, from the layer engine's message for it (which may still say "tap Update"): what
/// happened, without the next step, which the screen gives as a button.
String areaProblemWords(String? message) {
  final m = (message ?? '').toLowerCase();
  if (m.contains('no connection') || m.contains('offline')) return 'No connection';
  if (m.contains('free space')) return 'Not enough free space';
  if (m.contains('too big')) return 'Too big for one download';
  return 'The download stopped';
}

/// What a region action that failed says: what happened and the next step, never the core's own text (which is for the log and
/// can read like "a download needs \"bbox\" ..."). [what] is the action in words ("carry on with Idaho").
String downloadProblemWords(Object e, {required String what}) {
  if (e is MobileDataBlocked) return e.message;
  if (e is CacheSearchException) {
    return switch (e.code) {
      'offline' || 'fetch_failed' => "Couldn't $what: no connection. Connect, then try again.",
      'no_space' => "Couldn't $what: there is not enough free space. Free some space in Settings > Storage, then try again.",
      'busy' => "Couldn't $what just now: another download is starting. Try again in a moment.",
      'not_found' => "Couldn't $what: part of it is no longer on the phone. Remove it and download it again.",
      _ => "Couldn't $what. Try again; if it happens again, remove it and download it again.",
    };
  }
  if (e is StateError && _plain(e.message)) return "Couldn't $what: ${e.message[0].toLowerCase()}${e.message.substring(1)}";
  return "Couldn't $what. Try again; if it happens again, remove it and download it again.";
}

/// A message the app itself wrote for people (a sentence with no code, address or JSON in it).
bool _plain(String m) => m.isNotEmpty && !RegExp(r'[{}\[\]"`]|://|_[a-z]').hasMatch(m) && m.length < 160;
