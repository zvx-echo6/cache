import 'dart:async';

import 'package:flutter/foundation.dart';

/// A device heard nearby (`nearby_list`). [name] is null until the engine has asked for it.
class NearbyDevice {
  const NearbyDevice({required this.id, this.name, this.via = 'wifi'});

  final String id;
  final String? name;
  final String via;
}

/// Where a Nearby link stands (`nearby_state`).
enum NearbyPhase { idle, incoming, exchanging, words, waiting, linked, dropped }

class NearbyState {
  const NearbyState(this.phase, {this.name, this.words = const [], this.reason});

  static const idle = NearbyState(NearbyPhase.idle);

  final NearbyPhase phase;

  /// The other device's name, when the engine knows it.
  final String? name;

  /// The three words ([NearbyPhase.words]).
  final List<String> words;

  /// Why it ended ([NearbyPhase.dropped]): cancelled, timeout, mismatch or busy.
  final String? reason;

  /// A link is under way: the dialog is up.
  bool get active => phase != NearbyPhase.idle && phase != NearbyPhase.dropped;

  static NearbyState parse(Map<String, dynamic> m) {
    final name = m['name'] as String?;
    switch (m['state']) {
      case 'incoming':
        return NearbyState(NearbyPhase.incoming, name: name);
      case 'exchanging':
        return NearbyState(NearbyPhase.exchanging, name: name);
      case 'words':
        return NearbyState(NearbyPhase.words, name: name, words: [for (final w in (m['words'] as List? ?? const [])) '$w']);
      case 'waiting':
        return NearbyState(NearbyPhase.waiting, name: name);
      case 'linked':
        return NearbyState(NearbyPhase.linked, name: name);
      case 'dropped':
        return NearbyState(NearbyPhase.dropped, reason: m['reason'] as String?);
    }
    return idle;
  }
}

/// What to tell the person when a link ended without linking.
String nearbyDroppedMessage(String? reason) {
  switch (reason) {
    case 'cancelled':
      return 'Link cancelled. Nothing was linked.';
    case 'timeout':
      return 'No answer from the other device. Nothing was linked. Try again.';
    case 'mismatch':
      return 'The words did not match, so nothing was linked. Try again.';
    case 'busy':
      return 'Too many link requests. Try again in a minute.';
  }
  return 'The link did not finish. Nothing was linked. Try again.';
}

typedef EngineCall = Future<Map<String, dynamic>> Function(String method, [Map<String, Object?> args]);

/// The Nearby side of "Show my link code": starts it when the page opens (`pairing_open`), asks the engine who is nearby and how a
/// link stands every half second, and stops when the page closes (`pairing_close`). Talks to the engine only through [call].
class NearbyController extends ChangeNotifier {
  NearbyController(this._call, {this.every = const Duration(milliseconds: 500)});

  final EngineCall _call;
  final Duration every;

  Timer? _timer;
  bool _opened = false, _closed = false, _ticking = false;

  /// False when the engine cannot do Nearby here (the list is then not shown).
  bool available = true;

  /// Set once the first answer is in, so the page can tell "looking" from "nothing nearby".
  bool looked = false;

  List<NearbyDevice> devices = const [];

  /// The device whose Link was just tapped, until the engine has taken it.
  String? linking;

  NearbyState _raw = NearbyState.idle;
  bool _hidden = false, _answered = false, _ownCancel = false;

  /// Told once when a link ended without linking.
  void Function(String? reason)? onDropped;

  /// The state as the page shows it: what the person already answered or closed is not shown again.
  NearbyState get state {
    if (_hidden && (_raw.phase == NearbyPhase.linked || _raw.active)) return NearbyState.idle;
    if (_answered && _raw.phase == NearbyPhase.words) return NearbyState(NearbyPhase.waiting, name: _raw.name);
    return _raw;
  }

  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    try {
      await _call('pairing_open');
    } catch (_) {
      available = false;
      notifyListeners();
      return;
    }
    if (_closed) return;
    _timer = Timer.periodic(every, (_) => poll());
    await poll();
  }

  /// Stops the polling and tells the engine. Safe to call twice.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    if (_opened && available) {
      try {
        await _call('pairing_close');
      } catch (_) {}
    }
  }

  Future<void> poll() async {
    if (_ticking || _closed || !available) return;
    _ticking = true;
    try {
      final list = await _call('nearby_list');
      final st = await _call('nearby_state');
      if (_closed) return;
      devices = [
        for (final d in (list['devices'] as List? ?? const []))
          if (d is Map && d['id'] is String) NearbyDevice(id: d['id'] as String, name: d['name'] as String?, via: (d['via'] as String?) ?? 'wifi'),
      ];
      looked = true;
      final before = _raw.phase;
      _raw = NearbyState.parse(st);
      if (_raw.phase != NearbyPhase.words) _answered = false;
      if (_raw.phase != NearbyPhase.linked && !_raw.active) _hidden = false;
      if (_raw.phase == NearbyPhase.dropped && before != NearbyPhase.dropped) {
        // the person's own Cancel was said when it was tapped
        if (!(_ownCancel && _raw.reason == 'cancelled')) onDropped?.call(_raw.reason);
        _ownCancel = false;
      }
      if (_raw.phase != NearbyPhase.idle) linking = null;
      notifyListeners();
    } catch (_) {
      // a missed answer: the next one tries again
    } finally {
      _ticking = false;
    }
  }

  /// This side tapped Link on [d].
  Future<void> link(NearbyDevice d) async {
    if (linking != null || state.active) return;
    linking = d.id;
    notifyListeners();
    try {
      await _call('nearby_link', {'id': d.id});
      await poll();
    } finally {
      linking = null;
      if (!_closed) notifyListeners();
    }
  }

  /// Link or Cancel on the words (or Cancel while waiting). A Cancel closes the dialog at once.
  Future<void> answer(bool ok) async {
    if (ok) {
      _answered = true;
    } else {
      _hidden = true;
      _ownCancel = true;
      onDropped?.call('cancelled');
    }
    notifyListeners();
    try {
      await _call('nearby_answer', {'ok': ok});
    } finally {
      await poll();
    }
  }

  /// Done on "Linked": the dialog goes and does not come back for the same link.
  void acknowledge() {
    _hidden = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _closed = true;
    super.dispose();
  }
}
