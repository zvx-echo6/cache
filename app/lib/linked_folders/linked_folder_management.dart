import 'package:flutter/material.dart';
import '../theme.dart';
import '../video/format.dart' show formatBytes;
import '../browse/web/build_common.dart' show pageBar, PanelCard, Small;
import 'linked_folders.dart';
import '../browse/web/two_column.dart';

class LinkedFolderManagementPage extends StatefulWidget {
  const LinkedFolderManagementPage({
    super.key,
    required this.controller,
    required this.libraryId,
  });
  final LinkedFolderController controller;
  final String libraryId;
  @override
  State<LinkedFolderManagementPage> createState() =>
      _LinkedFolderManagementPageState();
}

class _LinkedFolderManagementPageState
    extends State<LinkedFolderManagementPage> {
  LinkedFolderController get c => widget.controller;
  static const _permissionHelp =
      'Cache cannot read this folder. Restore access, then check again.';
  static const _unavailableHelp =
      'This folder cannot be reached right now. Existing books remain searchable.';

  String _count(int count, String singular) =>
      '$count $singular${count == 1 ? '' : 's'}';
  int _watchRequest = 0;
  bool _watchStarted = false;

  @override
  void initState() {
    super.initState();
    _watchAfterFrame();
  }

  void _watchAfterFrame() {
    final request = ++_watchRequest;
    final controller = c;
    final libraryId = widget.libraryId;
    // The previous route may still be listening to the same controller.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _watchRequest) return;
      controller.watch(libraryId);
      if (mounted && request == _watchRequest) {
        setState(() => _watchStarted = true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant LinkedFolderManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, c) ||
        oldWidget.libraryId != widget.libraryId) {
      if (_watchStarted) {
        oldWidget.controller.unwatch(oldWidget.libraryId, notify: false);
      }
      _watchStarted = false;
      _watchAfterFrame();
    }
  }

  @override
  void dispose() {
    _watchRequest++;
    if (_watchStarted) c.unwatch(widget.libraryId, notify: false);
    super.dispose();
  }

  String _stage(LinkedJob j) =>
      j.state == 'queued' ? 'Waiting to check' : 'Checking files';
  Future<void> _unlink(LinkedRoot r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink folder?'),
        content: const Text(
          'Cache will stop checking this folder. Your originals will stay where they are. Indexed books and searchable passages will stay in this library. This folder location will become unavailable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unlink folder'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await c.unlink(widget.libraryId, r.id);
      if (mounted && c.error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(c.error!)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final k = context.t;
      final snap = _watchStarted ? c.snapshot : null;
      final job = _watchStarted ? c.activeJob : null;
      final displayedJob = job ?? (_watchStarted ? c.latestJob : null);
      final left = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Linked folders',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          if ((!_watchStarted || c.busy) && snap == null)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (snap != null && snap.roots.isEmpty)
            const Small('No folders are linked to this library.'),
          for (final r in snap?.roots ?? const <LinkedRoot>[])
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _rootCard(context, r, displayedJob),
            ),
          if (_watchStarted && c.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(c.error!, style: TextStyle(color: k.warning)),
            ),
          OutlinedButton.icon(
            onPressed: !_watchStarted || c.busy || c.actionBusy
                ? null
                : () => c.refresh(widget.libraryId),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      );
      final right = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Books and locations',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          if (snap != null) ...[
            Text(
              '${_count(snap.books.where((b) => !b.pendingIndexing).map((b) => b.id).toSet().length, 'matched book')}\n'
              '${_count(snap.books.expand((b) => b.locations).where((x) => x.available).length, 'available location')} · '
              '${_count(snap.books.expand((b) => b.locations).where((x) => !x.available).length, 'unavailable location')}',
              style: TextStyle(color: k.text),
            ),
            for (final b in snap.books.where((x) => x.pendingIndexing).take(12))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: PanelCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.title),
                      const Small('Not added to search yet.'),
                      for (final location in b.locations)
                        Small(
                          '${location.available ? 'Available location' : 'Unavailable location'} · ${location.path}',
                        ),
                    ],
                  ),
                ),
              ),
          ],
          if (displayedJob != null &&
              (displayedJob.rootId == null ||
                  !(snap?.roots.any((r) => r.id == displayedJob.rootId) ??
                      false)))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _jobCard(displayedJob),
            ),
          const SizedBox(height: 10),
          const Small(
            'New and changed PDFs are listed here when found. They are not added to search in this release. Original PDFs are never opened from this page.',
          ),
        ],
      );
      return Scaffold(
        appBar: pageBar(context, 'Linked folders'),
        body: ScrollingTwoColumn(left: left, right: right),
      );
    },
  );
  Widget _rootCard(BuildContext context, LinkedRoot r, LinkedJob? job) {
    final k = context.t;
    final rootStatus = job?.roots
        .where((x) => x['root_id'] == r.id)
        .firstOrNull;
    final issues = rootStatus?['errors'] is List
        ? (rootStatus!['errors'] as List).whereType<Map>().toList()
        : const <Map>[];
    final permissionLost = issues.any((x) => x['code'] == 'permission_denied');
    final unavailableRoot =
        rootStatus?['unavailable'] == true ||
        issues.any((x) => x['code'] == 'root_unavailable');
    final active =
        job?.active == true &&
        (job?.rootId == r.id || (job?.rootId == null && rootStatus != null));
    final rootJob = job?.rootId == r.id ? job : null;
    final futurePaused = job?.active == true && job?.rootId == r.id
        ? job!.pausedForFuture
        : r.paused;
    final shownErrors = <String>{
      if (permissionLost) _permissionHelp,
      if (unavailableRoot) _unavailableHelp,
      for (final issue in issues)
        if (issue['message'] is String) issue['message'] as String,
    };
    final visibleIssues = issues.where((issue) {
      final path = issue['path']?.toString() ?? '';
      return path.isNotEmpty ||
          !((permissionLost && issue['message'] == _permissionHelp) ||
              (unavailableRoot && issue['message'] == _unavailableHelp));
    });
    final rootLocations =
        c.snapshot?.books
            .expand((b) => b.locations)
            .where((x) => x.rootId == r.id && x.available)
            .length ??
        0;
    final unavailable =
        c.snapshot?.books
            .expand((b) => b.locations)
            .where((x) => x.rootId == r.id && !x.available)
            .length ??
        0;
    final rootBooks =
        c.snapshot?.books
            .where(
              (b) =>
                  !b.pendingIndexing &&
                  b.locations.any((x) => x.rootId == r.id),
            )
            .map((b) => b.id)
            .toSet()
            .length ??
        0;
    return PanelCard(
      key: ValueKey('linked-root-${r.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            r.label,
            style: TextStyle(color: k.text, fontWeight: FontWeight.w600),
          ),
          SelectableText(
            r.path,
            style: TextStyle(color: k.secondary, fontSize: 12),
          ),
          Small(
            active
                ? 'Checking files'
                : permissionLost
                ? 'Permission needed'
                : unavailableRoot
                ? 'Folder unavailable'
                : futurePaused
                ? 'Paused'
                : rootStatus?['complete'] == true && job?.state == 'done'
                ? 'Check finished'
                : 'Linked',
          ),
          Small(
            '${_count(rootBooks, 'matched book')} · ${_count(rootLocations, 'available location')}'
            '${unavailable > 0 ? ' · ${_count(unavailable, 'unavailable location')}' : ''}',
          ),
          if (permissionLost) const Small(_permissionHelp),
          if (unavailableRoot) const Small(_unavailableHelp),
          for (final issue in visibleIssues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Small(
                      '${issue['path'] is String && (issue['path'] as String).isNotEmpty ? '${issue['path']} · ' : ''}${issue['message'] ?? issue['code'] ?? 'A file needs attention'}',
                    ),
                  ),
                  if (issue['code'] != 'permission_denied' &&
                      issue['code'] != 'root_unavailable' &&
                      issue['code'] != 'file_changing')
                    TextButton(
                      onPressed: job?.active == true || c.actionBusy
                          ? null
                          : () => c.checkNow(widget.libraryId, rootId: r.id),
                      child: const Text('Retry'),
                    ),
                ],
              ),
            ),
          if (futurePaused)
            Small(
              active
                  ? 'Future checks paused. The current check will finish.'
                  : 'Future checks are paused. Existing books remain searchable.',
            ),
          if (rootJob != null) _jobCard(rootJob, shownErrors: shownErrors),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: job?.active == true || c.actionBusy
                    ? null
                    : () => c.checkNow(widget.libraryId, rootId: r.id),
                child: const Text('Check now'),
              ),
              TextButton(
                onPressed: c.actionBusy
                    ? null
                    : () => futurePaused
                          ? c.resume(widget.libraryId, r.id)
                          : c.pause(widget.libraryId, r.id),
                child: Text(futurePaused ? 'Resume' : 'Pause'),
              ),
              TextButton(
                onPressed: job?.active == true || c.actionBusy
                    ? null
                    : () => _unlink(r),
                child: const Text('Unlink folder'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _date(String? value) {
    if (value == null) return 'Unknown';
    final n = int.tryParse(value);
    final d = n == null
        ? DateTime.tryParse(value)?.toLocal()
        : DateTime.fromMillisecondsSinceEpoch(n, isUtc: true).toLocal();
    if (d == null) return 'Unknown';
    String two(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _jobCard(LinkedJob j, {Set<String> shownErrors = const {}}) {
    final n = j.counts;
    final active = j.active;
    final errorsAlreadyShown = <String>{
      ...shownErrors,
      if (j.rootId == null)
        for (final root in j.roots)
          if (root['errors'] is List)
            for (final issue in (root['errors'] as List).whereType<Map>()) ...[
              if (issue['message'] is String) issue['message'] as String,
              if (issue['code'] == 'permission_denied') _permissionHelp,
              if (issue['code'] == 'root_unavailable') _unavailableHelp,
            ],
    };
    final settling =
        (n.settlingFileCount ?? 0) > 0 ||
        j.roots.any(
          (root) => root['pending'] is num && (root['pending'] as num) > 0,
        );
    final values = <String>[
      if (n.filesSeen != null) '${n.filesSeen} files seen',
      if (n.filesHashed != null) '${n.filesHashed} checked',
      if (n.bytesHashed != null) '${formatBytes(n.bytesHashed!)} checked',
      if (n.matchedUniqueIds != null)
        _count(n.matchedUniqueIds!, 'matched book'),
      if (n.matchedLocations != null) _count(n.matchedLocations!, 'location'),
      if (n.unmatchedIdentity != null && n.unmatchedIdentity! > 0)
        '${n.unmatchedIdentity} not added to search yet',
      if (n.settlingFileCount != null && n.settlingFileCount! > 0)
        '${n.settlingFileCount} still settling',
      if (n.errors != null && n.errors! > 0) '${n.errors} need attention',
    ];
    return PanelCard(
      key: ValueKey('linked-job-${j.id}'),
      accentEdge: active,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            active
                ? _stage(j)
                : switch (j.state) {
                    'done' => 'Last check finished',
                    'failed' => 'Last check stopped',
                    'interrupted' => 'Last check interrupted',
                    _ => 'Check status',
                  },
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (values.isNotEmpty) Small(values.join(' · ')),
          if (active && values.isEmpty)
            const Small('Progress counts are not available yet.'),
          if (j.pausedForFuture && active && j.rootId == null)
            const Small(
              'Future checks are paused for one or more folders. The current check will finish.',
            ),
          if (!active && settling)
            const Small(
              'Still being copied or changed. Check again after the files stop changing.',
            ),
          if (j.error != null && !errorsAlreadyShown.contains(j.error))
            Small(j.error!),
          if (!active && j.lastSuccessfulAt != null)
            Small('Last successful check: ${_date(j.lastSuccessfulAt)}'),
        ],
      ),
    );
  }
}
