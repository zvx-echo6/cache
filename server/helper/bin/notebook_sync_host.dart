import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../app/lib/files.dart' show writeStringAtomic;
import '../../../app/lib/notebook/notebook_store.dart';
import '../../../app/lib/notebook/sync/folder.dart';
import '../../../app/lib/notebook/sync/photo_gate.dart';
import '../../../app/lib/notebook/sync/sync_engine_core.dart';
import '../../../app/lib/notebook/templates_model.dart';
import '../../../app/lib/sharing/share_rules.dart' show kNotebookShareDir;
import 'core_notebook_store.dart';
import 'line_protocol.dart';
import 'sharing_host.dart';

/// Cache for Linux's notebook sync, headless: the phone's `NotebookConnections` for the notebook share (kind `notebooks`), with no
/// Flutter and no tab open, run by the helper. It keeps the notebooks in the core and the folder `<support>/notebook-share` the same,
/// through the one engine the phone runs (sync_engine_core.dart, the phone's merge rules unchanged), over a [NotebookStore] backed by
/// the core ([CoreNotebookStore]).
///
///  * One writer: this host writes the share folder. A browser never does; it changes the notebooks in the core and this host exports.
///  * Triggers, as the phone's: one pass at [start]; [shareChanged] for kind `notebooks` (the engine settled a change from a linked
///    device: import); [changed] after any write to the core's notebooks (2 s later, several changes one pass: export); and a switch
///    of a private notebook's "Include in sync and sharing" ([setIncluded]). Nothing runs while the kind is off ([shareOn]).
///  * Private notebooks stay out of the share until their switch is on, as on the phone: the folder names of those not included are
///    the share's extra off list ([privateOff]), and no entry of theirs is written.
///  * Photos: an incoming photo is stored where the browser's viewer reads it (`<support>/notebook/photos/<id>.jpg`); an outgoing
///    one is offered to the engine only when an entry that goes out refers to it ([photosToSend], the engine's `gate`).
///
/// What the host keeps, in `<support>/notebook-sync` as on the phone: `targets.json` (`private_included`: the ids of the private
/// notebooks switched on) and `share.json` (the engine's record of the last pass).
class NotebookSyncHost {
  NotebookSyncHost({
    required this.support,
    required this.store,
    required this.shareOn,
    this.prepareShare,
    this.offChanged,
    this.templates,
    this.clock,
    this.debounce = const Duration(seconds: 2),
    this.every = const Duration(minutes: 2),
    this.log,
  });

  final Directory support;
  final NotebookStore store;

  /// Whether the Notebooks kind is shared now (the sharing host's engine runs and shares `notebooks`).
  final bool Function() shareOn;

  /// Run before a pass writes anything: the engine's list of the photos that may be sent is made current.
  final Future<void> Function()? prepareShare;

  /// Told when the private notebooks left out changed: the engine's off list and photo gate are given again.
  final Future<void> Function()? offChanged;

  /// The built-in templates (see [serverTemplates]); none when null.
  final Future<Templates> Function()? templates;
  final DateTime Function()? clock;
  final Duration debounce;

  /// A pass this often too while the kind is on (the phone's 2 minutes), for what no trigger told of.
  final Duration every;
  final void Function(String message)? log;

  Directory get _dir => Directory('${support.path}/notebook-sync');
  File get _targets => File('${_dir.path}/targets.json');
  Directory get shareDir => Directory('${support.path}/$kNotebookShareDir');

  final Set<String> _included = {};
  List<String> _privateOff = const [];
  Timer? _debounce, _timer;
  int passes = 0;
  bool _stopped = false;
  Future<void>? _loop;
  bool _again = false;

  /// The last pass's report (tests read it).
  SyncReport? last;

  /// Notebooks that need a person's decision after the last pass (an entry removed outside; a file that cannot be read).
  List<SyncConflict> conflicts = const [];

  // ---- the private notebooks' switches ----

  /// The private notebooks switched on, by id (sorted).
  List<String> get includedIds => [..._included]..sort();

  bool included(String notebookId) => _included.contains(notebookId);

  /// The folder names (in the share) of the private notebooks that are not switched on: what the engine leaves out.
  List<String> privateOff() => _privateOff;

  Future<void> _readTargets() async {
    try {
      if (!await _targets.exists()) return;
      final j = jsonDecode(await _targets.readAsString());
      if (j is Map && j['private_included'] is List) {
        _included
          ..clear()
          ..addAll([for (final x in j['private_included'] as List) '$x']);
      }
    } catch (e) {
      log?.call('notebook sync: its switches are unreadable: $e');
    }
  }

  Future<void> _saveTargets() async {
    await _dir.create(recursive: true);
    // The phone's format (`targets` is its folders: the server has none but the share, which is not listed).
    await writeStringAtomic(_targets, jsonEncode({'targets': const <Object>[], 'private_included': includedIds}));
  }

  /// A private notebook's "Include in sync and sharing", on or off. Kept; the engine is told which notebooks are left out; a pass
  /// follows. A notebook that is not private is always in, so the switch is only kept.
  Future<void> setIncluded(String notebookId, bool on) async {
    await _readOnce();
    on ? _included.add(notebookId) : _included.remove(notebookId);
    await _saveTargets();
    await _refreshPrivate();
    unawaited(run());
  }

  /// Reads the notebooks again and works out which private ones are left out; true when that list changed. The engine is not told (see
  /// [_refreshPrivate]): the sharing host calls this before it gives the engine the off list, from inside its own work.
  Future<bool> readPrivate() async {
    try {
      await store.reload();
    } catch (e) {
      log?.call('notebook sync: could not read the notebooks: $e');
      return false;
    }
    final now = ({for (final n in store.notebooks) if (n.private && !_included.contains(n.id)) NotebookSyncCore.folderNameOf(n)}).toList()..sort();
    final same = now.length == _privateOff.length && [for (var i = 0; i < now.length; i++) now[i] == _privateOff[i]].every((x) => x);
    _privateOff = now;
    return !same;
  }

  Future<void> _refreshPrivate() async {
    if (!await readPrivate()) return;
    try {
      await offChanged?.call();
    } catch (e) {
      log?.call('notebook sync: could not give the engine the notebooks left out: $e');
    }
  }

  /// The photos that may be sent, for the engine's gate: those an entry that goes out refers to ([off] is the share's off list).
  Future<List<String>> photosToSend(List<String> off) async {
    await store.reload();
    return notebookPhotosToSendFrom(store, off, included: _included.contains);
  }

  // ---- the passes ----

  bool _read = false;

  Future<void> _readOnce() async {
    if (_read) return;
    _read = true;
    await _readTargets();
  }

  /// The pass at start (the notebooks and the share folder are made the same): the helper calls it once sharing is up and again
  /// each time the core has opened, whichever comes last finds both ready; passes that find the kind off or the core not open yet
  /// do nothing.
  Future<void> start() {
    _timer ??= Timer.periodic(every, (_) => unawaited(run()));
    return run();
  }

  void stop() {
    _stopped = true;
    _debounce?.cancel();
    _debounce = null;
    _timer?.cancel();
    _timer = null;
  }

  /// A linked device's change settled in the shares [ids]: for `notebooks`, a pass (import).
  Future<void> shareChanged(Set<String> ids) async {
    if (ids.contains('notebooks')) await run();
  }

  /// The core's notebooks were written (by a browser): a pass in [debounce] (export).
  void changed() {
    if (_stopped) return;
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(run()));
  }

  /// One pass; a call while one runs asks for another right after it. Completes when the passes are done.
  Future<void> run() {
    if (_stopped) return Future.value();
    final l = _loop;
    if (l != null) {
      _again = true;
      return l;
    }
    return _loop = () async {
      try {
        do {
          _again = false;
          await _pass();
        } while (_again && !_stopped);
      } finally {
        _loop = null;
      }
    }();
  }

  Future<void> _pass() async {
    if (!shareOn()) return;
    passes++;
    try {
      await _readOnce();
      await _refreshPrivate();
      try {
        await prepareShare?.call();
      } catch (e) {
        log?.call('notebook sync: could not update the photos that may be sent: $e');
      }
      final core = NotebookSyncCore(
        notebook: store,
        kind: SyncKind.share,
        folder: IoFolder(shareDir.path),
        stateFile: File('${_dir.path}/share.json'),
        includePrivate: false,
        privateBooks: {..._included},
        clock: clock,
        templates: templates ?? () async => const Templates([], []),
        onError: (what, {Object? error, String? detail}) => log?.call('$what${detail == null ? '' : ' ($detail)'}${error == null ? '' : ': $error'}'),
      );
      final s = store;
      if (s is CoreNotebookStore) core.storePhotoBytes = s.storePhoto;
      await shareDir.create(recursive: true);
      final r = await core.run();
      last = r;
      conflicts = core.conflicts;
      _say(r);
    } on FileSystemException catch (e) {
      log?.call('notebook sync: cannot use the share folder: ${e.message}');
    } catch (e) {
      log?.call('notebook sync: a pass failed: $e');
    }
  }

  void _say(SyncReport r) {
    String entries(int n) => n == 1 ? '1 entry' : '$n entries';
    final updated = r.read - r.arrived;
    for (final line in [
      if (r.arrived > 0) 'notebook sync: ${entries(r.arrived)} arrived from your other devices',
      if (updated > 0) 'notebook sync: ${entries(updated)} updated from your other devices',
      if (r.removedHere > 0) 'notebook sync: ${entries(r.removedHere)} removed by your other devices',
      if (r.merged.isNotEmpty) 'notebook sync: ${entries(r.merged.length)} combined with changes from your other devices',
      if (r.keptAsTwo.isNotEmpty) 'notebook sync: ${entries(r.keptAsTwo.length)} changed in the same words on both devices; the other version is kept as a new entry',
    ]) {
      log?.call(line);
    }
  }
}

/// The notebook ops of the core that only read; any other `notebook` op may change the notebooks.
const Set<String> kNotebookReadOps = {'notebooks', 'notebook', 'entries', 'entry', 'search', 'pins', 'source_rows'};

/// A look at the core's ops that tells the host when the notebooks were written (a browser's `notebook` op that is not a read), so
/// it exports. The sync's own writes go through [CoreNotebookStore] and never reach here.
class NotebookWriteHook implements CoreHook {
  NotebookWriteHook(this._changed, {CoreHook? then}) : _then = then;

  final void Function() _changed;
  final CoreHook? _then;

  @override
  Map<String, dynamic> before(String op, Map<String, dynamic> args) => _then?.before(op, args) ?? args;

  @override
  void after(String op, Map<String, dynamic> args) {
    _then?.after(op, args);
    if (op != 'notebook') return;
    final inner = args['op'];
    if (inner is String && !kNotebookReadOps.contains(inner)) _changed();
  }
}

/// Wires [nb] to [sharing] as the helper does: the host's off lists and photo gate know the private notebooks and the photos that
/// may go, share changes for `notebooks` import, and a browser can switch a private notebook's inclusion (`sharing.set_private`).
void attachNotebookSync(SharingHost sharing, NotebookSyncHost nb) {
  sharing.extraOff = (id) => id == 'notebooks' ? nb.privateOff() : const [];
  sharing.photosAllowed = (id, off) => nb.photosToSend(off);
  sharing.privateIncluded = () => nb.includedIds;
  sharing.setPrivateIncluded = nb.setIncluded;
  sharing.beforeKindOn = (kind) => kind == 'notebooks' ? nb.readPrivate().then((_) {}) : Future<void>.value();
  sharing.kindSet = (kind, on) => kind == 'notebooks' && on ? nb.run() : Future<void>.value();
}

/// The built-in notebook templates and starter logs from [dir] (the web build's `assets/notebook`: `templates.json`,
/// `starters.json`), read once. A notebook that arrives from a phone without its definition is made from the template its files
/// name; without them (a helper run by hand) it is made as a plain notebook.
Future<Templates> Function() serverTemplates(String? dir, {void Function(String message)? log}) {
  Templates? loaded;
  return () async {
    if (loaded != null) return loaded!;
    if (dir == null || dir.isEmpty) return const Templates([], []);
    try {
      return loaded = Templates.parse(await File('$dir/templates.json').readAsString(), await File('$dir/starters.json').readAsString());
    } catch (e) {
      log?.call('notebook sync: the built-in templates could not be read ($dir): $e');
      return const Templates([], []);
    }
  };
}
