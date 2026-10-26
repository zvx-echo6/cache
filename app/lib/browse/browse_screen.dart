import 'package:flutter/material.dart';

import '../sources/sources_state.dart';
import '../theme.dart';
import '../layout/layout_state.dart';
import 'browse_state.dart';
import 'catalogue_screen.dart';
import 'reader_screen.dart';
import 'zim_urls.dart';

/// The Library module: the ZIMs on this phone (open one like a web site), the downloads running, the updates
/// found, and the way to the Kiwix library.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({
    super.key,
    required this.browse,
    required this.active,
    this.layout,
  });

  final BrowseState browse;

  /// Where "Add to Home" on a page puts its shortcut (the reader offers it only when this is given).
  final LayoutState? layout;

  /// True while the Library is the screen showing.
  final bool active;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  bool _checked = false;

  BrowseState get b => widget.browse;
  SourcesState get sources => b.sources;

  @override
  void initState() {
    super.initState();
    b.addListener(_onBrowse);
    _maybeCheck();
  }

  @override
  void didUpdateWidget(BrowseScreen old) {
    super.didUpdateWidget(old);
    _maybeCheck();
    _onBrowse();
  }

  @override
  void dispose() {
    b.removeListener(_onBrowse);
    super.dispose();
  }

  /// Looks for updates once, the first time the tab is shown and there are ZIMs to check.
  void _maybeCheck() {
    if (!widget.active || _checked || sources.zims.isEmpty) return;
    _checked = true;
    b.checkUpdates();
  }

  /// A citation asked for an article.
  void _onBrowse() {
    final a = b.requestedAddress;
    if (a == null || !widget.active) return;
    b.requestedAddress = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openAddress(a));
  }

  void _openAddress(String address) {
    final id = zimIdOfAddress(address);
    final z = id == null ? null : sources.zimById(id);
    if (z == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('That source is not on this phone any more.'),
          ),
        );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ZimReaderScreen(sources: sources, zim: z, address: address, layout: widget.layout),
      ),
    );
  }

  void _openZim(ZimFile z) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ZimReaderScreen(sources: sources, zim: z, layout: widget.layout),
      ),
    );
  }

  void _openCatalogue() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => CatalogueScreen(browse: b)));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: 'Check for updates',
            icon: const Icon(Icons.refresh),
            onPressed: b.checkingUpdates ? null : b.checkUpdates,
          ),
          ListenableBuilder(
            listenable: b,
            builder: (context, _) => PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'wifi') b.setWifiOnly(!b.wifiOnly);
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'wifi',
                  checked: b.wifiOnly,
                  child: const Text('Download on Wi-Fi only'),
                ),
              ],
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([b, sources]),
        builder: (context, _) {
          _maybeCheck();
          final transfers = b.transfers.values.toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (b.checkingUpdates)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(),
                ),
              if (b.updateError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    b.updateError!,
                    style: TextStyle(color: k.warning),
                  ),
                ),
              if (b.updates.isNotEmpty) _updatesCard(k),
              for (final t in transfers) _transferCard(k, t),
              if (sources.zims.isEmpty && transfers.isEmpty) _empty(k),
              for (final z in sources.zims) _zimCard(context, k, z),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _openCatalogue,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Get more from the Kiwix library'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _empty(CacheTokens k) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Text(
      sources.unavailable ??
          'No ZIMs on this phone yet. Get Wikipedia, medical guides and more from the Kiwix library, or add a file in Sources.',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 17, color: k.secondary),
    ),
  );

  Widget _updatesCard(CacheTokens k) {
    final n = b.updates.length;
    final bytes = b.updates.values.fold<int>(0, (s, e) => s + e.size);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.system_update_alt, color: k.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  n == 1
                      ? '1 update available · ${formatBytes(bytes)}'
                      : '$n updates available · ${formatBytes(bytes)}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: k.text,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  for (final z in sources.zims) {
                    if (b.updates.containsKey(z.path)) b.update(z);
                  }
                },
                child: const Text('Update all'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _transferCard(CacheTokens k, ZimTransfer t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.replaces == null ? t.entry.title : 'Updating ${t.entry.title}',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: k.text,
              ),
            ),
            Text(
              [t.entry.flavourText, formatBytes(t.entry.size)].join(' · '),
              style: TextStyle(fontSize: 13, color: k.secondary),
            ),
            const SizedBox(height: 6),
            TransferRow(browse: b, transfer: t),
          ],
        ),
      ),
    ),
  );

  Widget _zimCard(BuildContext context, CacheTokens k, ZimFile z) {
    final phase = sources.phaseOf(z);
    final update = b.updates[z.path];
    final replacing = b.isBeingReplaced(z);
    final String status;
    switch (phase) {
      case ZimPhase.ready:
        status = replacing
            ? 'Ready · replaced when the new one is indexed'
            : 'Ready · ${sources.docsOf(z)} articles';
      case ZimPhase.indexing:
        final f = sources.indexFraction(z);
        status = f == null
            ? 'Indexing…'
            : 'Indexing ${(f * 100).toStringAsFixed(0)}%';
      case ZimPhase.failed:
        status = sources.failureOf(z) ?? 'Could not be read';
      case ZimPhase.waiting:
        status = sources.coreReady ? 'Waiting to index' : 'Not available';
    }
    final icon = sources.iconOf(z);
    final canOpen = sources.idOf(z) != null && phase != ZimPhase.failed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: canOpen ? () => _openZim(z) : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: icon == null
                            ? Icon(Icons.menu_book_outlined, color: k.secondary)
                            : Image.file(icon, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sources.titleOf(z),
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: k.text,
                            ),
                          ),
                          Text(
                            '${formatBytes(z.size)} · $status',
                            style: TextStyle(
                              fontSize: 14,
                              color: phase == ZimPhase.failed
                                  ? k.emergency
                                  : k.secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (canOpen) Icon(Icons.chevron_right, color: k.secondary),
                  ],
                ),
                if (phase == ZimPhase.indexing) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: sources.indexFraction(z)),
                ],
                if (update != null && !b.transfers.containsKey(update.id))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => b.update(z),
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(
                        'Update to ${update.release} · ${formatBytes(update.size)}',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
