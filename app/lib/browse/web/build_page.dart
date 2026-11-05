import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/settings/widgets.dart' show GroupLabel;
import '../../theme.dart';
import '../../video/format.dart' show formatBytes;
import '../../layout/adaptive.dart' show ReadingWidth, openDetail;
import 'two_column.dart';
import 'build_api.dart';
import 'build_common.dart';
import 'build_library_page.dart';
import 'build_state.dart';
import 'compression_default_link.dart';
import 'compression_settings_page.dart';
import 'build_text.dart';
import 'device_api.dart' show DeviceException;
import 'local_files.dart';

/// Opens the page of a built library: in the desktop frame's detail pane when there is one, else as a page of its own (replacing
/// [replace], the page that is leaving, when given).
void openBuiltLibrary(BuildContext context, BuildController build, String id, {bool replace = false}) {
  Widget page(BuildContext _) => BuiltLibraryPage(build: build, libraryId: id);
  if (replace) {
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: page));
  } else {
    openDetail(context, key: 'built:$id', builder: page);
  }
}

/// Opens "Build from your PDFs" holding [files] (a drop anywhere on the Library): the person says where they go.
void openBuildPage(BuildContext context, BuildController build, {List<LocalFile> files = const []}) {
  Widget page(BuildContext _) => BuildPage(build: build, initialFiles: files);
  // From a page beside the list (Add to Library) it is pushed there with its back arrow; from the list it takes the detail pane.
  openDetail(context, key: 'build', builder: page);
}

/// "Build from your PDFs": where the books go, then the PDFs (dropped, chosen, or a whole folder). Dropping starts the upload; there is
/// no confirm step. While the PDFs go up the page shows the upload; when it ends the library's own page opens.
class BuildPage extends StatefulWidget {
  const BuildPage({super.key, required this.build, this.initialFiles = const []});

  final BuildController build;

  /// PDFs that were dropped on the Library: they wait here until the person says where they go.
  final List<LocalFile> initialFiles;

  @override
  State<BuildPage> createState() => _BuildPageState();
}

class _BuildPageState extends State<BuildPage> {
  final TextEditingController _name = TextEditingController();
  bool _newLibrary = true;
  String? _existing;
  List<LocalFile> _pending = const [];
  BuildUpload? _active;
  String? _error;
  bool _starting = false;
  bool _preparing = false;
  bool _needsChoice = false;
  CompressionChoice? _compression;
  int _selection = 0;

  BuildController get c => widget.build;

  @override
  void initState() {
    super.initState();
    c.sink = _take;
    c.addListener(_onChange);
    if (widget.initialFiles.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _take(widget.initialFiles));
  }

  @override
  void dispose() {
    if (c.sink == _take) c.sink = null;
    c.removeListener(_onChange);
    _name.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  List<BuildLibrary> get _mine => c.libraries;

  String? get _target {
    if (_newLibrary) return null;
    final id = _existing ?? _mine.firstOrNull?.id;
    return id;
  }

  BuildLibrary? get _taken => _newLibrary ? c.libraryNamed(_name.text) : null;

  bool get _valid => _newLibrary ? (_name.text.trim().isNotEmpty && _taken == null) : (_target != null);

  void _take(List<LocalFile> files) => unawaited(_prepare(files));

  Future<void> _prepare(List<LocalFile> files) async {
    if (!mounted || _active != null) return;
    final selection = ++_selection;
    setState(() {
      _pending = files;
      _error = null;
      _preparing = true;
      _needsChoice = false;
      _compression = null;
    });
    try {
      if (c.api is BuildCompressionApi) {
        final settings = await c.loadCompressionSettings();
        if (!mounted || selection != _selection) return;
        _compression = settings.compression;
        _needsChoice = settings.askWhenOne && splitPdfs(files).pdfs.length == 1;
      }
      if (!mounted || selection != _selection) return;
      setState(() => _preparing = false);
      if (_valid && !_needsChoice) await _start();
    } on DeviceException catch (e) {
      if (mounted && selection == _selection) setState(() { _preparing = false; _error = callWords(e); });
    }
  }

  Future<void> _start({bool confirmed = false}) async {
    if (_pending.isEmpty || !_valid || _starting || _preparing || (_needsChoice && !confirmed)) return;
    final files = _pending;
    if (c.api is BuildCompressionApi && _compression == null) { await _prepare(files); return; }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final u = await c.addFiles(files, libraryId: _newLibrary ? null : _target, newTitle: _newLibrary ? _name.text.trim() : null, compression: _compression);
      if (!mounted) return;
      setState(() {
        _starting = false;
        _pending = const [];
        _active = u;
      });
      if (u == null) return;
      say(context, 'Uploading ${u.count} ${u.count == 1 ? 'PDF' : 'PDFs'}. Keep this tab open.');
      await u.done;
      if (!mounted) return;
      if (u.failed.isEmpty && u.stopped == null) openBuiltLibrary(context, c, u.libraryId, replace: true);
      setState(() {});
    } on DeviceException catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = callWords(e);
      });
    }
  }

  Future<void> _choose(Future<List<LocalFile>> Function() pick) async {
    final files = await pick();
    if (files.isEmpty || !mounted) return;
    _take(files);
  }

  @override
  Widget build(BuildContext context) {
    final u = _active;
    return Scaffold(
      appBar: pageBar(context, 'Build from your PDFs'),
      body: u != null ? _uploading(context, u) : _form(context),
    );
  }

  // ---- the form

  Widget _form(BuildContext context) {
    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_where(context), CompressionDefaultLink(build: c)]);
    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_blocked(context), _zone(context), const SizedBox(height: 14), _notes(context)]);
    return ScrollingTwoColumn(left: left, right: right);
  }

  Widget _blocked(BuildContext context) {
    final b = c.queue.blocked;
    if (b == null) return const SizedBox.shrink();
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PanelCard(
        key: const ValueKey('build-blocked'),
        warnEdge: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Building is ${b.toLowerCase()}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
            const SizedBox(height: 2),
            const Small('PDFs can be added now. They wait, and building starts when the search model is on this device.'),
          ],
        ),
      ),
    );
  }

  Widget _where(BuildContext context) {
    final k = context.t;
    final taken = _taken;
    final mine = _mine;
    Widget radio(bool on) => Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 22, color: on ? k.accent : k.secondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GroupLabel('1 · Where should the books go?'),
        PanelCard(
          key: const ValueKey('where-new'),
          selected: _newLibrary,
          onTap: () => setState(() => _newLibrary = true),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                radio(_newLibrary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('A new library', style: TextStyle(fontSize: 15, color: k.text)),
                    const Small('Give it a name you will recognise on your phone.'),
                  ]),
                ),
              ]),
              if (_newLibrary) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: TextField(
                    key: const ValueKey('library-name'),
                    controller: _name,
                    onChanged: (_) {
                      setState(() {});
                      if (_valid && _pending.isNotEmpty && _active == null) unawaited(_start());
                    },
                    decoration: InputDecoration(
                      hintText: 'Library name',
                      isDense: true,
                      filled: true,
                      fillColor: k.background,
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: taken != null ? k.warning : k.secondary.withValues(alpha: 0.5))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: taken != null ? k.warning : k.accent, width: 2)),
                    ),
                  ),
                ),
                if (taken != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 6, 0, 0),
                    child: Text('You already have a library called "${taken.title}". Choose another name, or add to it.', key: const ValueKey('name-taken'), style: TextStyle(fontSize: 12, color: k.warning)),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        PanelCard(
          key: const ValueKey('where-existing'),
          selected: !_newLibrary,
          onTap: mine.isEmpty ? null : () => setState(() => _newLibrary = false),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                radio(!_newLibrary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('A library you built', style: TextStyle(fontSize: 15, color: mine.isEmpty ? k.secondary : k.text)),
                    Small(mine.isEmpty ? 'None yet. The first one is made above.' : 'Add to one you made from PDFs earlier.'),
                  ]),
                ),
              ]),
              for (final l in mine)
                Padding(
                  padding: const EdgeInsets.only(left: 32, top: 4),
                  child: InkWell(
                    key: ValueKey('existing-${l.id}'),
                    onTap: () => setState(() {
                      _newLibrary = false;
                      _existing = l.id;
                    }),
                    child: Row(children: [
                      if (!_newLibrary) Icon((_target == l.id) ? Icons.check_circle : Icons.circle_outlined, size: 16, color: (_target == l.id) ? k.accent : k.secondary),
                      if (!_newLibrary) const SizedBox(width: 6),
                      Expanded(child: Text('${l.title} · ${bookCount(l.books)}', style: TextStyle(fontSize: 12, color: k.text))),
                    ]),
                  ),
                ),
            ],
          ),
        ),
        if (_pending.isNotEmpty && !_needsChoice) ...[
          const SizedBox(height: 12),
          _pendingCard(context),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('build-error'), style: TextStyle(fontSize: 13, color: k.warning))),
        if (c.notice != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(c.notice!, key: const ValueKey('build-notice'), style: TextStyle(fontSize: 13, color: k.warning))),
      ],
    );
  }

  Widget _pendingCard(BuildContext context) {
    final split = splitPdfs(_pending);
    final n = split.pdfs.length;
    return PanelCard(
      key: const ValueKey('pending-card'),
      accentEdge: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$n ${n == 1 ? 'PDF is' : 'PDFs are'} ready · ${formatBytes(totalBytes(split.pdfs))}', style: TextStyle(fontSize: 15, color: context.t.text)),
          if (n == 1) Text(split.pdfs.single.name),
          if (split.leftOutWords != null) Small(split.leftOutWords!),
          const SizedBox(height: 4),
          if (_needsChoice && _compression != null) ...[
            const Text("Make this book's file smaller?", style: TextStyle(fontWeight: FontWeight.w600)),
            const Small('For this book only.'),
            CompressionChoiceControl(value: _compression!, onChanged: (value) => setState(() => _compression = value)),
            if (c.compressionSettings?.compression != _compression) const Small('Different from your default'),
          ],
          Small(_preparing ? 'Reading your default…' : _needsChoice ? 'Choose the setting for this book, then add it.' : _valid ? 'Adding them now.' : (_newLibrary ? 'Name the library, or choose one you built, and they are added.' : 'Choose where they go.')),
          Row(children: [
            TextButton(key: const ValueKey('pending-start'), onPressed: _valid && !_starting && !_preparing ? () => _start(confirmed: true) : null, child: Text(_needsChoice ? 'Add to library' : n == 1 ? 'Add 1 PDF' : 'Add ${thousands(n)} PDFs')),
            TextButton(key: const ValueKey('pending-clear'), onPressed: () => setState(() { ++_selection; _pending = const []; _needsChoice = false; _preparing = false; }), child: const Text('Not these')),
          ]),
        ],
      ),
    );
  }

  Widget _zone(BuildContext context) {
    final k = context.t;
    if (_needsChoice && _pending.isNotEmpty) {
      return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GroupLabel('2 · Add your PDF'),
        _pendingCard(context),
        if (_error != null) Text(_error!, style: TextStyle(color: k.warning)),
      ],
    );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GroupLabel('2 · Add your PDFs'),
        DashedBox(
          key: const ValueKey('pdf-drop-zone'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 34),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              children: [
                Icon(Icons.upload, size: 44, color: k.accent),
                const SizedBox(height: 10),
                Text('Drop PDFs or a folder here', style: TextStyle(fontSize: 20, color: k.text)),
                const SizedBox(height: 6),
                Text('Folders are searched for PDFs, including inside other folders. You can add more at any time.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, height: 1.4, color: k.secondary)),
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  FilledButton(key: const ValueKey('choose-pdfs'), onPressed: () => _choose(c.pickPdfs), child: const Text('Choose PDFs')),
                  OutlinedButton(key: const ValueKey('choose-folder'), onPressed: () => _choose(c.pickFolder), child: const Text('Choose a folder')),
                ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _notes(BuildContext context) {
    final k = context.t;
    final style = TextStyle(fontSize: 14, height: 1.5, color: k.text);
    return ReadingWidth(
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const GroupLabel('What happens next'),
          Text('Each PDF is cut into passages of about 200 words, keeping the real page and heading, so answers can quote the book.', style: style),
          const SizedBox(height: 10),
          Text(
            'Building takes about a second per passage on a desktop computer and longer on a small device: a 300-page book is roughly 8 to 10 minutes. Scanned pages are read as images and take longer. It keeps going if you close this tab.',
            style: style,
          ),
        ],
      ),
    );
  }

  // ---- while the PDFs go up

  Widget _uploading(BuildContext context, BuildUpload u) {
    final k = context.t;
    final speed = u.speed;
    final left = u.secondsLeft;
    final line = u.finishing
        ? 'Putting the last ones in place…'
        : [
            '${thousands(u.doneCount)} of ${thousands(u.count)} done',
            '${formatBytes(u.sentBytes)} of ${formatBytes(u.totalBytes)}',
            if (speed != null) '${formatBytes(speed.round())}/s',
            if (left != null) _left(left),
          ].join(' · ');
    final shown = <UploadEntry>[
      ...u.entries.where((e) => e.state == 'done').toList().reversed.take(2).toList().reversed,
      ...u.inFlight.take(4),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        ReadingWidth(
          alignment: Alignment.topLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10, left: 4),
                child: Row(children: [
                  Text('Going to', style: TextStyle(fontSize: 14, color: k.secondary)),
                  const SizedBox(width: 24),
                  Expanded(child: Text('${u.libraryTitle}${u.newLibrary ? ' (new library)' : ''}', style: TextStyle(fontSize: 14, color: k.text))),
                ]),
              ),
              PanelCard(
                key: const ValueKey('upload-batch'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(u.replaceDocId != null ? 'Uploading the new copy of ${u.replaceTitle}' : 'Uploading ${thousands(u.count)} ${u.count == 1 ? 'PDF' : 'PDFs'}', style: TextStyle(fontSize: 15, color: k.text)),
                          Small(u.running ? line : _endedLine(u)),
                        ]),
                      ),
                      if (u.running) TextButton(key: const ValueKey('cancel-batch'), onPressed: c.cancelUpload, child: const Text('Cancel')),
                    ]),
                    const SizedBox(height: 8),
                    SlimBar(value: u.finishing ? null : u.fraction, height: 6),
                    const SizedBox(height: 8),
                    const Small('Keep this tab open until the upload ends. Building starts on the first book and carries on without this tab.'),
                  ],
                ),
              ),
              if (shown.isNotEmpty) ...[
                const GroupLabel('Uploading now'),
                PanelCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Column(children: [for (final e in shown) _fileRow(k, e)]),
                ),
              ],
              if (u.failed.isNotEmpty || u.stopped != null) ...[
                const GroupLabel('Not sent'),
                if (u.stopped != null) Padding(padding: const EdgeInsets.only(left: 6, bottom: 4), child: Text(u.stopped!, key: const ValueKey('upload-stopped'), style: TextStyle(fontSize: 13, color: k.warning))),
                for (final e in u.failed.take(8))
                  Padding(padding: const EdgeInsets.only(left: 6, bottom: 2), child: Text('${e.name}: ${e.error ?? 'not sent'}', style: TextStyle(fontSize: 12, color: k.warning))),
              ],
              if (u.leftOut.isNotEmpty)
                Padding(padding: const EdgeInsets.fromLTRB(6, 10, 6, 0), child: Small(PdfSplit(const [], u.leftOut).leftOutWords!)),
              if (u.ended)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(key: const ValueKey('open-built'), onPressed: () => openBuiltLibrary(context, c, u.libraryId, replace: true), child: Text('Open ${u.libraryTitle}')),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _endedLine(BuildUpload u) => '${thousands(u.doneCount)} of ${thousands(u.count)} sent';

  Widget _fileRow(CacheTokens k, UploadEntry e) {
    final done = e.state == 'done';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 22, child: done ? Icon(Icons.check, size: 16, color: k.secondary) : null),
        Expanded(child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.text))),
        const SizedBox(width: 12),
        SizedBox(width: 110, child: SlimBar(value: done ? 1 : e.fraction, height: 3)),
        SizedBox(width: 84, child: Text(formatBytes(e.size), textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: k.secondary))),
      ]),
    );
  }

  static String _left(int seconds) {
    if (seconds < 60) return 'less than a minute left';
    final m = (seconds / 60).ceil();
    if (m < 90) return 'about $m min left';
    return 'about ${(m / 60).round()} h left';
  }
}
