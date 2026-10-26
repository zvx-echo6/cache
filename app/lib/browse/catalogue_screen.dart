import 'dart:async';

import 'package:flutter/material.dart';

import '../settings/data_policy.dart';
import '../theme.dart';
import 'browse_state.dart';
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

/// Kiwix's public library: filter by language and category, search, and download.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key, required this.browse});

  final BrowseState browse;

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
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
    b.loadFacets();
    if (b.entries.isEmpty) b.loadFirstPage();
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
      appBar: AppBar(title: const Text('Kiwix library')),
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
                          hintText: 'Search the library',
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

  Widget _list(BuildContext context, CacheTokens k) {
    if (b.entries.isEmpty) {
      if (b.loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                b.catalogError ??
                    'Nothing found. Try another word, language or category.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  color: b.catalogError != null ? k.emergency : k.secondary,
                ),
              ),
              if (b.catalogError != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: b.loadFirstPage,
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: b.entries.length + 1,
      itemBuilder: (context, i) {
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
                style: TextStyle(color: k.emergency),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${b.total} in the library',
              textAlign: TextAlign.center,
              style: TextStyle(color: k.secondary),
            ),
          );
        }
        return EntryTile(browse: b, entry: b.entries[i]);
      },
    );
  }
}

/// One catalogue entry with its icon, description and the action that fits where it stands.
class EntryTile extends StatelessWidget {
  const EntryTile({super.key, required this.browse, required this.entry});

  final BrowseState browse;
  final CatalogEntry entry;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final transfer = browse.transfers[entry.id];
    final installed = browse.installedFor(entry);
    final installedRelease = installed == null
        ? null
        : browse.sources.originOf(installed)?.release;
    final newer =
        installed != null &&
        installedRelease != null &&
        installedRelease.compareTo(entry.release) < 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _icon(k),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: k.text,
                          ),
                        ),
                        if (entry.summary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              entry.summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: k.secondary,
                              ),
                            ),
                          ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            entry.flavourText,
                            entry.language,
                            formatBytes(entry.size),
                            entry.updated,
                          ].where((s) => s.isNotEmpty).join(' · '),
                          style: TextStyle(fontSize: 13, color: k.secondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _action(context, k, transfer, installed != null, newer),
            ],
          ),
        ),
      ),
    );
  }

  Widget _icon(CacheTokens k) {
    final url = entry.iconUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 48,
        child: url == null
            ? Icon(Icons.menu_book_outlined, color: k.secondary)
            : Image.network(
                url.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.menu_book_outlined, color: k.secondary),
              ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    CacheTokens k,
    ZimTransfer? t,
    bool installed,
    bool newer,
  ) {
    if (t != null) return TransferRow(browse: browse, transfer: t);
    if (installed && !newer) {
      return Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: k.ok),
          const SizedBox(width: 6),
          Text('On this phone', style: TextStyle(color: k.ok)),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: () => browse.download(
          entry,
          replaces: newer ? browse.installedFor(entry) : null,
        ),
        icon: Icon(newer ? Icons.system_update_alt : Icons.download),
        label: Text(
          newer
              ? 'Update · ${formatBytes(entry.size)}'
              : 'Download · ${formatBytes(entry.size)}',
        ),
      ),
    );
  }
}

/// The progress of one download, with Cancel and, when it stopped, Try again.
class TransferRow extends StatelessWidget {
  const TransferRow({super.key, required this.browse, required this.transfer});

  final BrowseState browse;
  final ZimTransfer transfer;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final t = transfer;
    final e = t.entry;
    switch (t.phase) {
      case TransferPhase.blockedByMobileData:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              const MobileDataBlocked().message,
              style: TextStyle(color: k.warning, fontWeight: FontWeight.w600),
            ),
            Wrap(
              children: [
                TextButton(
                  key: const ValueKey('download-anyway'),
                  onPressed: () => browse.download(
                    e,
                    replaces: t.replaces,
                    allowMobile: true,
                  ),
                  child: const Text('Download anyway'),
                ),
                TextButton(
                  onPressed: () => browse.cancel(e),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      case TransferPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.error ?? 'The download failed.',
              style: TextStyle(color: k.emergency),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: () => browse.download(e, replaces: t.replaces),
                  child: const Text('Try again'),
                ),
                TextButton(
                  onPressed: () => browse.cancel(e),
                  child: const Text('Discard'),
                ),
              ],
            ),
          ],
        );
      case TransferPhase.starting:
      case TransferPhase.downloading:
      case TransferPhase.verifying:
      case TransferPhase.adding:
        final label = switch (t.phase) {
          TransferPhase.starting => 'Starting…',
          TransferPhase.verifying => 'Checking the file…',
          TransferPhase.adding => 'Adding to your sources…',
          _ => 'Downloading ${formatBytes(t.done)} of ${formatBytes(t.total)}',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 14, color: k.secondary),
                  ),
                ),
                if (t.phase == TransferPhase.downloading ||
                    t.phase == TransferPhase.starting)
                  TextButton(
                    onPressed: () => browse.cancel(e),
                    child: const Text('Cancel'),
                  ),
              ],
            ),
            LinearProgressIndicator(
              value: t.phase == TransferPhase.downloading ? t.fraction : null,
            ),
          ],
        );
    }
  }
}
