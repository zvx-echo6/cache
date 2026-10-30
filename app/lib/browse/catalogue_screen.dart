import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/hold.dart';
import '../screens/libraries_screen.dart';
import '../screens/settings/widgets.dart' show GroupLabel;
import '../theme.dart';
import 'browse_state.dart';
import 'library_actions.dart';
import 'opds.dart';

String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) {
    return '${(bytes / (1 << 20)).toStringAsFixed(bytes >= 100 << 20 ? 0 : 1)} MB';
  }
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// A topic that is a tag in Kiwix's catalogue rather than a category.
class _Topic {
  const _Topic(this.label, this.tag);

  final String label;
  final String tag;
}

const List<_Topic> _topics = [
  _Topic('Medicine', 'medicine'),
  _Topic('Preparedness', 'preppers'),
];

/// Add to Library: the one screen for adding anything. Your own library (from a file or a download link), then Kiwix's ready-made
/// collections, searchable and filtered by language and category, each with its own download button and the download pop-up.
class AddToLibraryScreen extends StatefulWidget {
  const AddToLibraryScreen({super.key, required this.browse});

  final BrowseState browse;

  @override
  State<AddToLibraryScreen> createState() => _AddToLibraryScreenState();
}

class _AddToLibraryScreenState extends State<AddToLibraryScreen> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  BrowseState get b => widget.browse;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        b.loadMore();
      }
    });
    _search.text = b.query;
    // After the first frame: the Library behind this screen listens to the same state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      b.loadFacets();
      if (b.entries.isEmpty) b.loadFirstPage();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _languageName() {
    if (b.language.isEmpty) return 'All languages';
    for (final l in b.languages) {
      if (l.code == b.language) return l.name;
    }
    return b.language;
  }

  Future<void> _pickLanguage() async {
    await b.loadFacets();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, controller) => ListView(
          controller: controller,
          children: [
            ListTile(
              title: const Text('All languages'),
              selected: b.language.isEmpty,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final l in b.languages)
              ListTile(
                title: Text(l.name),
                trailing: Text('${l.count}'),
                selected: l.code == b.language,
                onTap: () => Navigator.pop(ctx, l.code),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await b.setFilter(language: picked);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Add to Library')),
      body: ListenableBuilder(
        listenable: b,
        builder: (context, _) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search the catalogue',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _search.clear();
                                    b.setFilter(query: '');
                                  },
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: k.surface,
                        ),
                        onChanged: (v) {
                          setState(() {});
                          _debounce?.cancel();
                          _debounce = Timer(
                            const Duration(milliseconds: 400),
                            () => b.setFilter(query: v),
                          );
                        },
                        onSubmitted: (v) => b.setFilter(query: v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ActionChip(
                      avatar: const Icon(Icons.language, size: 18),
                      label: Text(_languageName()),
                      onPressed: _pickLanguage,
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _chip(
                      'All',
                      b.category == null && b.tag == null,
                      () => b.setFilter(clearCategory: true, clearTag: true),
                    ),
                    for (final c in b.categories)
                      _chip(
                        c.label,
                        b.category == c.id,
                        () => b.setFilter(category: c.id, clearTag: true),
                      ),
                    for (final t in _topics)
                      _chip(
                        t.label,
                        b.tag == t.tag,
                        () => b.setFilter(tag: t.tag, clearCategory: true),
                      ),
                  ],
                ),
              ),
              Expanded(child: _list(context, k)),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    ),
  );

  /// "Your own library", and the label over Kiwix's collections.
  List<Widget> _head(CacheTokens k) {
    final libraries = b.libraries;
    return [
      if (libraries != null) ...[
        const GroupLabel('Your own'),
        Material(
          color: k.surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: const ValueKey('add-own-library'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LibrariesScreen(libraries: libraries))),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.library_add_outlined, size: 22, color: k.text),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Your own library', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                          Text('From a file or a download link', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: k.secondary),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
      ],
      const GroupLabel('Ready-made collections · free from Kiwix'),
    ];
  }

  Widget _list(BuildContext context, CacheTokens k) {
    if (b.entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          ..._head(k),
          if (b.loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else
            _nothing(k),
        ],
      );
    }
    final head = _head(k);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: head.length + b.entries.length + 1,
      itemBuilder: (context, j) {
        if (j < head.length) return head[j];
        final i = j - head.length;
        if (i == b.entries.length) {
          if (b.loading) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (b.catalogError != null) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                b.catalogError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: k.warning),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${b.total} in the catalogue',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: k.secondary),
            ),
          );
        }
        return EntryTile(browse: b, entry: b.entries[i]);
      },
    );
  }

  /// Nothing found, or the catalogue cannot be reached (with Try again).
  Widget _nothing(CacheTokens k) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          b.catalogError == null ? 'Nothing found. Try another word, language or category.' : "Couldn't reach the catalogue. ${b.catalogError}",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: b.catalogError != null ? k.warning : k.secondary),
        ),
        if (b.catalogError != null) ...[
          const SizedBox(height: 12),
          OutlinedButton(onPressed: b.loadFirstPage, child: const Text('Try again')),
        ],
      ],
    ),
  );
}

/// One catalogue entry: its icon, name, a short description and size, and its own download button (the download pop-up follows), or
/// "On this phone", or how its download is going.
class EntryTile extends StatelessWidget {
  const EntryTile({super.key, required this.browse, required this.entry});

  final BrowseState browse;
  final CatalogEntry entry;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final transfer = browse.transfers[entry.id];
    final installed = browse.installedFor(entry);
    final installedRelease = installed == null ? null : browse.sources.originOf(installed)?.release;
    final newer = installed != null && installedRelease != null && installedRelease.compareTo(entry.release) < 0;
    final detail = transfer == null
        ? [if (entry.summary.isNotEmpty) entry.summary, formatBytes(entry.size)].join(' · ')
        : switch (transfer.phase) {
            TransferPhase.blockedByMobileData => 'Waiting for Wi-Fi',
            TransferPhase.paused => 'Paused',
            TransferPhase.failed => transfer.error ?? 'The download stopped',
            TransferPhase.downloading => 'Downloading ${formatBytes(transfer.done)} of ${formatBytes(transfer.total)}',
            _ => 'Downloading…',
          };
    final Widget action;
    if (transfer != null) {
      action = SizedBox(
        width: 44,
        height: 44,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: CircularProgressIndicator(strokeWidth: 2.5, value: transfer.phase == TransferPhase.downloading ? transfer.fraction : null),
        ),
      );
    } else if (installed != null && !newer) {
      action = RowBadge('On this phone', color: k.ok);
    } else {
      action = IconButton(
        key: ValueKey('download-${entry.id}'),
        tooltip: newer ? 'Update ${entry.title}' : 'Download ${entry.title}',
        onPressed: () => downloadZim(context, browse, entry, replaces: newer ? installed : null),
        icon: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.accent, width: 1.5)),
          child: Icon(newer ? Icons.system_update_alt : Icons.download, size: 17, color: k.accent),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                _icon(k),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: transfer?.phase == TransferPhase.failed ? k.warning : k.secondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                action,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon(CacheTokens k) {
    final url = entry.iconUrl;
    final letter = Center(child: Text(entry.title.isEmpty ? '?' : entry.title.characters.first.toUpperCase(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: k.accent)));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 32,
        height: 32,
        color: k.background,
        child: url == null ? letter : Image.network(url.toString(), fit: BoxFit.cover, errorBuilder: (_, _, _) => letter),
      ),
    );
  }
}
