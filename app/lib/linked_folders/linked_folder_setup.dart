import 'dart:async';
import 'package:flutter/foundation.dart' show listEquals;
import '../browse/web/device_api.dart' show DeviceException;
import 'package:flutter/material.dart';
import '../theme.dart';
import '../browse/web/build_common.dart' show pageBar, PanelCard, Small;
import 'linked_folders.dart';
import 'linked_folder_management.dart';
import '../browse/web/two_column.dart';

class LinkedFolderSetupPage extends StatefulWidget {
  const LinkedFolderSetupPage({super.key, required this.controller});
  final LinkedFolderController controller;
  @override
  State<LinkedFolderSetupPage> createState() => _LinkedFolderSetupPageState();
}

class _LinkedFolderSetupPageState extends State<LinkedFolderSetupPage> {
  final _label = TextEditingController(),
      _path = TextEditingController(),
      _exclude = TextEditingController();
  String? _libraryId, _error;
  bool _checking = false,
      _linking = false,
      _checked = false,
      _registered = false;
  String? _checkedPath;
  List<String> _checkedExclusions = const [];
  LinkedFolderController get c => widget.controller;
  List<String> get _exclusions => _exclude.text
      .split(RegExp(r'\r?\n'))
      .map((x) => x.trim().replaceAll('\\', '/'))
      .where((x) => x.isNotEmpty)
      .toSet()
      .toList();
  bool get _validExclusions => _exclusions.every(
    (x) =>
        !x.startsWith('/') &&
        !RegExp(r'^[A-Za-z]:').hasMatch(x) &&
        !x.split('/').contains('..'),
  );
  @override
  void initState() {
    super.initState();
    _path.addListener(_edited);
    _exclude.addListener(_edited);
    _label.addListener(_edited);
    unawaited(c.loadTargets());
  }

  void _edited() {
    if (mounted) {
      setState(
        () => _checked =
            _checked &&
            _path.text.trim() == _checkedPath &&
            listEquals(_exclusions, _checkedExclusions),
      );
    }
  }

  @override
  void dispose() {
    _path.dispose();
    _label.dispose();
    _exclude.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final testedPath = _path.text.trim();
    final testedExclusions = List<String>.of(_exclusions);
    if (testedPath.isEmpty ||
        !testedPath.startsWith('/') ||
        !_validExclusions) {
      setState(
        () => _error =
            'Enter a full folder path on this device and relative excluded folder names.',
      );
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
      _checked = false;
    });
    try {
      final result = await c.preview(testedPath, testedExclusions);
      if (!mounted) return;
      if (result['readable'] != true) {
        setState(
          () => _error =
              'Cache could not read that folder. Check the path and access, then try again.',
        );
        return;
      }
      setState(() {
        _checked =
            testedPath == _path.text.trim() &&
            listEquals(testedExclusions, _exclusions);
        _checkedPath = testedPath;
        _checkedExclusions = testedExclusions;
      });
    } on DeviceException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.message.isEmpty
              ? 'Cache could not check that folder. Check the path and try again.'
              : e.message,
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _link() async {
    if (!_checked ||
        _checkedPath != _path.text.trim() ||
        !listEquals(_checkedExclusions, _exclusions) ||
        _libraryId == null ||
        !c.targets.any((target) => target.id == _libraryId) ||
        _linking) {
      return;
    }
    final libraryId = _libraryId!;
    final path = _checkedPath!;
    final exclusions = List<String>.of(_checkedExclusions);
    final label = _label.text.trim().isEmpty
        ? 'Linked folder'
        : _label.text.trim();
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _linking = true;
      _error = null;
    });
    final rootId = 'linked-${DateTime.now().microsecondsSinceEpoch}';
    _registered = false;
    try {
      await c.register(
        libraryId,
        id: rootId,
        label: label,
        path: path,
        exclusions: exclusions,
      );
      _registered = true;
      await c.refresh(libraryId);
      await c.checkNow(libraryId, rootId: rootId);
      if (!mounted) return;
      final checkError = c.error;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              LinkedFolderManagementPage(controller: c, libraryId: libraryId),
        ),
      );
      if (checkError != null) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Folder linked. $checkError')),
        );
      }
    } on DeviceException catch (e) {
      if (!mounted) return;
      if (_registered) {
        await c.refresh(libraryId);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) =>
                LinkedFolderManagementPage(controller: c, libraryId: libraryId),
          ),
        );
        messenger?.showSnackBar(
          const SnackBar(
            content: Text(
              'Folder linked. The check could not start. Try Check now on the folder.',
            ),
          ),
        );
      } else {
        setState(
          () => _error = e.status == 409
              ? 'A folder check is in progress. Wait for it to finish, then link this folder.'
              : e.message.isEmpty
              ? 'The folder could not be linked. Try again.'
              : e.message,
        );
      }
    } finally {
      if (mounted) setState(() => _linking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final k = context.t;
        final targets = c.targets;
        final selectedLibraryId =
            targets.any((target) => target.id == _libraryId)
            ? _libraryId
            : null;
        final ready =
            _checked &&
            _checkedPath == _path.text.trim() &&
            listEquals(_checkedExclusions, _exclusions) &&
            selectedLibraryId != null &&
            !_linking;
        final left = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Folder and library',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            const Small('Folder on this Cache device'),
            TextField(
              key: const ValueKey('linked-folder-path'),
              controller: _path,
              enabled: !_linking,
              decoration: const InputDecoration(
                hintText: '/path/on/this/device',
                border: OutlineInputBorder(),
              ),
            ),
            const Small(
              'This path is on the device running Cache, not this browser.',
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('linked-folder-label'),
              controller: _label,
              enabled: !_linking,
              decoration: const InputDecoration(
                labelText: 'Folder label',
                hintText: 'For example, Field manuals',
              ),
            ),
            const SizedBox(height: 10),
            KeyedSubtree(
              key: const ValueKey('linked-folder-library'),
              child: DropdownButtonFormField<String>(
                key: ValueKey(selectedLibraryId),
                initialValue: selectedLibraryId,
                decoration: const InputDecoration(labelText: 'Add to library'),
                items: [
                  for (final x in targets)
                    DropdownMenuItem(
                      value: x.id,
                      child: Text(x.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _linking
                    ? null
                    : (v) => setState(() => _libraryId = v),
              ),
            ),
            if (c.loading) const LinearProgressIndicator(),
            if (c.error != null)
              Text(c.error!, style: TextStyle(color: k.warning)),
            if (!c.loading && targets.isEmpty)
              const Small('No libraries are available to link yet.'),
            if (c.error != null || (!c.loading && targets.isEmpty))
              TextButton(
                key: const ValueKey('retry-linked-libraries'),
                onPressed: c.loading ? null : c.loadTargets,
                child: const Text('Retry'),
              ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('linked-folder-exclusions'),
              controller: _exclude,
              enabled: !_linking,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Excluded subfolders',
                hintText: 'One relative folder path per line',
              ),
            ),
            const Small('Hidden folders are excluded automatically.'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('check-linked-folder'),
              onPressed:
                  _checking ||
                      _linking ||
                      _path.text.trim().isEmpty ||
                      !_validExclusions
                  ? null
                  : _check,
              icon: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.folder_open),
              label: Text(_checking ? 'Checking folder…' : 'Check folder'),
            ),
            if (_checked)
              const Small(
                'Folder is readable. This check did not match files or add them to search.',
              ),
            if (!_validExclusions)
              Text(
                'Use relative folder names. Paths cannot start at the device root or include ..',
                style: TextStyle(color: k.warning, fontSize: 12),
              ),
            const SizedBox(height: 14),
            const Text(
              'Your originals stay read-only',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const Small(
              'Cache reads files in place. It does not move, rename, change, compress, or delete your originals.',
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('linked-folder-error'),
                  style: TextStyle(color: k.warning),
                ),
              ),
            FilledButton(
              key: const ValueKey('link-folder'),
              onPressed: ready ? _link : null,
              child: Text(_linking ? 'Linking…' : 'Link folder'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _linking
                  ? null
                  : () => Navigator.of(context).maybePop(),
              child: const Text('Cancel'),
            ),
          ],
        );
        final right = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Future browsing views',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const Small(
              'These planned views are not available in this release. Linking a folder keeps the current library view.',
            ),
            for (final entry in const [
              ('Keep my folders', 'Shelves from folders'),
              ('Sort with CDS', 'Subjects and call numbers'),
              ('Both', 'Folders and subjects'),
            ])
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Opacity(
                  opacity: 0.6,
                  child: PanelCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.$1,
                          style: TextStyle(
                            color: k.secondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Small(entry.$2),
                        const Small('Not available yet'),
                      ],
                    ),
                  ),
                ),
              ),
            const Small(
              'Nothing moves on disk. The current library view stays the same.',
            ),
            const SizedBox(height: 18),
            const Text(
              'PDFs only',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const Small(
              'PDFs that already match books in this library reuse those books. Other PDFs are listed as not added to search yet. Other file types are left alone.',
            ),
            const SizedBox(height: 18),
            const Text(
              'Sharing and privacy',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const Small(
              'Details stay on this device for now. Folder and file names will be shared when linked-folder sharing is available. The full system path stays here.',
            ),
          ],
        );
        return Scaffold(
          appBar: pageBar(context, 'Link a folder'),
          body: ScrollingTwoColumn(left: left, right: right),
        );
      },
    );
  }
}
