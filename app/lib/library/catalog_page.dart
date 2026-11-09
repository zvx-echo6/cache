import 'package:flutter/material.dart';

import '../pdf/index/pdf_index_app.dart' show pdfIndexShared, pdfZimRef;
import '../pdf/index/pdf_index_state.dart' show PdfPartPhase, PdfZimRef;
import '../pdf/index/pdf_index_ui.dart' show PdfIndexPartRow;
import '../screens/download_confirm.dart' show openStorageForSpace;
import '../screens/settings/widgets.dart';
import '../search/index_scheduler.dart';
import '../search/index_status.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import '../platform.dart' as plat;
import '../theme.dart';
import 'library_pages.dart';
import 'library_panes.dart';

/// Catalog's groups, in order.
enum CatalogGroup {
  books('Your books'),
  zims('ZIM Collections'),
  own('Your own'),
  places('Maps and places');

  const CatalogGroup(this.label);
  final String label;
}

/// One search index on this device, as Catalog shows it: its name, its kind (BOOKS, PAGES, PDFS, EPUBS, CAPTIONS, LIBRARY,
/// PLACES, ROUTING), where it stands and the one thing that can be done about it. The index scheduler and the PDF state are the
/// one source of what runs, waits or stopped; nothing here keeps state of its own.
class CatalogEntry {
  const CatalogEntry({
    required this.key,
    required this.group,
    required this.name,
    required this.kind,
    required this.state,
    required this.ready,
    this.tone = Tone.normal,
    this.fraction,
    this.pdf,
    this.onOpen,
  });

  /// The scheduler's key of its work (`zim-pdf/<id>`), or another unique key.
  final String key;
  final CatalogGroup group;
  final String name;
  final String kind;
  final String state;
  final bool ready;
  final Tone tone;

  /// The bar while it is being made, when known.
  final double? fraction;

  /// A ZIM's PDFs: the PDF state draws the line and its Pause, Resume and Free space.
  final PdfZimRef? pdf;

  /// Opens what the index belongs to (a library of your own).
  final void Function(BuildContext context)? onOpen;
}

/// The scheduler's words for [key]'s work, when it has it (running with progress, held with its reason, queued).
String? _scheduled(String key) {
  final s = indexSchedulerShared;
  if (s == null) return null;
  return indexRowWords(s, [key]);
}

/// Every search index on this device, grouped: your books, the ZIM Collections' (pages, PDFs, EPUBs, captions), your own
/// libraries and the guide, and the regions' places and routing.
List<CatalogEntry> catalogEntries(LibraryDeps d) {
  final out = <CatalogEntry>[];
  final sources = d.sources;
  final libs = d.libraries;
  if (libs != null) {
    for (final l in libs.libraries) {
      final books = d.holdsBooks(l);
      final key = 'library/${libs.statusOf(l)?.sourceId ?? libs.idOf(l) ?? l.folderName}';
      final phase = libs.phaseOf(l);
      final n = libs.docsOf(l);
      final shelfBooks = books ? d.shelves.bookCount : 0;
      final f = libs.indexFraction(l);
      final words = _scheduled(key);
      out.add(
        CatalogEntry(
          key: key,
          group: books ? CatalogGroup.books : CatalogGroup.own,
          name: libs.titleOf(l),
          kind: books ? 'BOOKS' : 'LIBRARY',
          ready: phase == LibraryPhase.ready,
          fraction: phase == LibraryPhase.indexing ? f : null,
          tone: switch (phase) {
            LibraryPhase.ready => Tone.ok,
            LibraryPhase.failed => Tone.danger,
            _ => Tone.warn,
          },
          state: words ??
              switch (phase) {
                LibraryPhase.ready => books
                    ? 'Ready · ${booksWord(shelfBooks)}'
                    : (libs.isGuide(l) ? 'Ready · Built in' : 'Ready${n > 0 ? ' · $n ${n == 1 ? 'entry' : 'entries'}' : ''}'),
                LibraryPhase.indexing => f == null ? 'Making searchable' : 'Making searchable · ${(f * 100).round()}%',
                LibraryPhase.opening => 'Getting ready',
                LibraryPhase.failed => 'Stopped: it could not be read',
                LibraryPhase.waiting => 'Waiting to make it searchable',
              },
          onOpen: books ? null : (ctx) => d.openOwnLibrary(ctx, l),
        ),
      );
    }
  }
  for (final z in sources.zims) {
    final id = sources.idOf(z);
    final name = sources.titleOf(z);
    final phase = sources.phaseOf(z);
    final own = sources.statusAt(z.path)?.keywordSource == 'own';
    final pageKey = 'zim/${id ?? z.path}';
    final f = sources.indexFraction(z);
    out.add(
      CatalogEntry(
        key: pageKey,
        group: CatalogGroup.zims,
        name: name,
        kind: 'PAGES',
        ready: phase == ZimPhase.ready || own,
        fraction: phase == ZimPhase.indexing ? f : null,
        tone: phase == ZimPhase.ready || own ? Tone.ok : (phase == ZimPhase.failed ? Tone.danger : Tone.warn),
        state: _scheduled(pageKey) ??
            switch (phase) {
              _ when own => 'Ready',
              ZimPhase.ready => 'Ready',
              ZimPhase.indexing => f == null ? 'Making searchable' : 'Making searchable · ${(f * 100).round()}%',
              ZimPhase.failed => 'Stopped: it could not be read',
              ZimPhase.waiting => 'Waiting to make it searchable',
            },
      ),
    );
    final pdf = pdfIndexShared;
    // a browser makes no PDF index of its own (the server builds none for ZIM PDFs yet), so there is nothing to list or pause
    if (pdf != null && id != null && !plat.isWeb) {
      final ref = pdfZimRef(sources, z);
      final part = pdf.partOf(ref);
      if (part != null) {
        out.add(
          CatalogEntry(
            key: 'zim-pdf/$id',
            group: CatalogGroup.zims,
            name: name,
            kind: 'PDFS',
            ready: part.phase == PdfPartPhase.done,
            state: '',
            pdf: ref,
          ),
        );
      }
    }
    final st = sources.statusAt(z.path);
    for (final (kind, tag, sub) in [('zim-epub', 'EPUBS', st?.epubIndex), ('zim-captions', 'CAPTIONS', st?.captionsIndex)]) {
      if (sub == null || (sub.state != 'ready' && sub.needsBuild != true)) continue;
      final key = '$kind/${sub.sourceId ?? id ?? z.path}';
      final ready = sub.state == 'ready';
      out.add(
        CatalogEntry(
          key: key,
          group: CatalogGroup.zims,
          name: name,
          kind: tag,
          ready: ready,
          tone: ready ? Tone.ok : Tone.warn,
          state: _scheduled(key) ?? (ready ? 'Ready' : indexWaitingWords(kind)),
        ),
      );
    }
  }
  for (final r in d.regions?.local ?? const []) {
    for (final (tag, state, has) in [('PLACES', r.placesState, r.hasPlaces), ('ROUTING', r.routingState, r.hasRouting)]) {
      if (!has) continue;
      final ready = state == 'ready';
      out.add(
        CatalogEntry(
          key: '${tag.toLowerCase()}/${r.id}',
          group: CatalogGroup.places,
          name: r.name,
          kind: tag,
          ready: ready,
          tone: ready ? Tone.ok : (state == 'failed' ? Tone.danger : Tone.warn),
          state: switch (state) {
            'ready' => 'Ready',
            'failed' => 'Stopped: it could not be read',
            _ => 'Getting ready',
          },
        ),
      );
    }
  }
  return out;
}

/// Catalog: every search index on this device, grouped, each with its state and how it syncs. The one place for Pause, Resume,
/// Try again and Free space (the scheduler's and the PDF state's own controls). [focus] marks one entry (from ZIM Collections).
class CatalogPage extends StatelessWidget {
  const CatalogPage({super.key, required this.deps, this.focus});

  final LibraryDeps deps;
  final String? focus;

  /// How the search indexes sync, from Sharing: off, or nothing linked yet. Per-index sync (which devices have which index) is
  /// not reported by sync yet, so with devices linked no line is shown rather than a guess.
  String? _syncLine() {
    final s = deps.sharing;
    if (s == null) return null;
    if (!s.enabled) return 'Not synced: sharing is off';
    if (s.peers.isEmpty) return 'Not synced yet';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final d = deps;
    final nav = LibraryNav.of(context);
    return Scaffold(
      appBar: libraryAppBar(context, title: 'Catalog'),
      body: ListenableBuilder(
        listenable: d.changes,
        builder: (context, _) {
          final k = context.t;
          final entries = catalogEntries(d);
          final sync = _syncLine();
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              if (!nav.compact) const LibraryCrumbs(crumbs: [Crumb('Library', []), Crumb('Catalog')]),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                child: Text('Every search index on this device. Pause, resume and fixes live here.', style: TextStyle(fontSize: 14, color: k.secondary)),
              ),
              if (indexSchedulerShared case final s? when s.busy)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                    child: s.pausedAll
                        ? RowButton(key: const ValueKey('catalog-resume-all'), label: 'Resume', onPressed: s.resumeAll)
                        : RowButton(key: const ValueKey('catalog-pause-all'), label: 'Pause all', onPressed: s.pauseAll),
                  ),
                ),
              // In a browser the server does the index work; its Pause all and Resume are the same buttons.
              if (plat.isWeb && d.sources.serverIndexBusy)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                    child: d.sources.serverIndexPaused
                        ? RowButton(key: const ValueKey('catalog-resume-all'), label: 'Resume', onPressed: () => d.sources.setServerIndexPaused(false))
                        : RowButton(key: const ValueKey('catalog-pause-all'), label: 'Pause all', onPressed: () => d.sources.setServerIndexPaused(true)),
                  ),
                ),
              if (entries.isEmpty) ...[
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('No search indexes yet.', key: const ValueKey('catalog-empty'), style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(onPressed: () => d.addToLibrary(context), icon: const Icon(Icons.add, size: 18), label: const Text('Add to Library')),
                ),
              ],
              for (final g in CatalogGroup.values)
                if (entries.where((e) => e.group == g).toList() case final rows when rows.isNotEmpty) ...[
                  GroupLabel(g.label),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const SizedBox(height: 2),
                          CatalogRow(entry: rows[i], sync: sync, focused: rows[i].key == focus),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
            ],
          );
        },
      ),
    );
  }
}

/// One search index: name and kind tag, its state (with the bar while it is made) and its one action, then how it syncs.
class CatalogRow extends StatelessWidget {
  const CatalogRow({super.key, required this.entry, this.sync, this.focused = false});

  final CatalogEntry entry;
  final String? sync;
  final bool focused;

  /// The one thing to do about the work, from the scheduler: Pause while it runs, Resume after the person paused it, Try again
  /// when it stopped moving, Free space when it needs room.
  (String, VoidCallback)? _action(BuildContext context) {
    final s = indexSchedulerShared;
    final item = s?.statusOf(entry.key);
    if (s == null || item == null) return null;
    if (item.state == IndexState.running && item.why == IndexWait.none) return ('Pause', s.pauseAll);
    if (item.why == IndexWait.person) return ('Resume', s.resumeAll);
    if (item.why == IndexWait.stuck) return ('Try again', () => s.retry(entry.key));
    if (item.why == IndexWait.storage && openStorageForSpace != null) return ('Free space', () => openStorageForSpace!(context));
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final e = entry;
    final action = e.pdf == null ? _action(context) : null;
    final item = indexSchedulerShared?.statusOf(e.key);
    final p = item?.progress;
    final running = !e.ready && item?.state == IndexState.running;
    // the work's own count when it says one (PDFs read of all), else the source's
    final fraction = e.fraction ?? (running && p != null && p.$2 > 0 ? (p.$1 / p.$2).clamp(0.0, 1.0) : null);
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: k.secondary.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(5)),
      child: Text(e.kind, style: TextStyle(fontSize: 11, letterSpacing: 0.6, fontWeight: FontWeight.w700, color: k.secondary)),
    );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text))),
              const SizedBox(width: 8),
              tag,
            ],
          ),
          if (e.pdf != null && pdfIndexShared != null)
            // the PDF state's own line and its Pause, Resume or Free space (one place, one source)
            PdfIndexPartRow(
              key: ValueKey('catalog-pdf-${e.key}'),
              state: pdfIndexShared!,
              zim: e.pdf!,
              changes: indexSchedulerShared,
              schedulerLine: (_) => _scheduled(e.key),
            )
          else ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(e.state, key: ValueKey('catalog-state-${e.key}'), style: TextStyle(fontSize: 13, color: toneColor(k, e.tone))),
                ),
                if (action != null) RowButton(key: ValueKey('catalog-action-${e.key}'), label: action.$1, onPressed: action.$2),
              ],
            ),
            if (fraction != null || running)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: fraction, minHeight: 5, color: k.accent, backgroundColor: k.secondary.withValues(alpha: 0.15)),
                ),
              ),
          ],
          if (sync != null) ...[const SizedBox(height: 4), Text(sync!, style: TextStyle(fontSize: 12, color: k.secondary))],
        ],
      ),
    );
    return Material(
      key: ValueKey('catalog-${e.key}'),
      color: focused ? Color.alphaBlend(k.accent.withValues(alpha: 0.16), k.surface) : k.surface,
      child: e.onOpen == null ? body : InkWell(onTap: () => e.onOpen!(context), child: body),
    );
  }
}
