import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../screens/download_confirm.dart';
import '../sources/sources_state.dart' show ZimFile;
import '../theme.dart';
import '../video/format.dart';
import 'browse_state.dart';
import 'opds.dart';

/// What the Library's hold menu (and the "..." of an opened item) offers for one item. An action that does not apply is null and
/// is left out of the menu.
class LibraryActions {
  const LibraryActions({required this.title, required this.bytes, required this.delete, this.checkUpdate, this.changeIcon, this.addToHome, this.free});

  final String title;
  final int bytes;

  /// Free bytes on the phone now, for the delete confirm.
  final int? free;
  final Future<void> Function()? checkUpdate;
  final Future<void> Function()? changeIcon;
  final VoidCallback? addToHome;
  final Future<void> Function() delete;
}

/// The one menu: Check for update, Change icon, Add to Home, Delete (which confirms first).
Future<void> showLibraryMenu(BuildContext context, LibraryActions a) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final k = ctx.t;
      Widget item(String value, IconData icon, String label, {bool danger = false}) => ListTile(
        key: ValueKey('library-menu-$value'),
        minTileHeight: 48,
        leading: Icon(icon, color: danger ? k.emergency : k.text),
        title: Text(label, style: TextStyle(fontSize: 15, color: danger ? k.emergency : k.text)),
        onTap: () => Navigator.pop(ctx, value),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
            ),
            if (a.checkUpdate != null) item('update', Icons.system_update_alt, 'Check for update'),
            if (a.changeIcon != null) item('icon', Icons.image_outlined, 'Change icon'),
            if (a.addToHome != null) item('home', Icons.add_to_home_screen, 'Add to Home'),
            item('delete', Icons.delete_outline, 'Delete · frees ${formatBytes(a.bytes)}', danger: true),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'update':
      await a.checkUpdate!();
    case 'icon':
      await a.changeIcon!();
    case 'home':
      a.addToHome!();
    case 'delete':
      if (await confirmDelete(context, name: a.title, bytes: a.bytes, free: a.free)) await a.delete();
  }
}

/// Lets the person pick a picture for an item's icon and copies it to [dest]. False when nothing was picked or it is not a picture.
Future<bool> pickIconInto(File dest, {Future<String?> Function()? pick}) async {
  final path = pick != null ? await pick() : (await FilePicker.pickFile())?.path;
  if (path == null) return false;
  final lower = path.toLowerCase();
  if (!['.png', '.jpg', '.jpeg', '.webp', '.gif'].any(lower.endsWith)) return false;
  try {
    await dest.parent.create(recursive: true);
    await File(path).copy(dest.path);
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {}
  }
}

/// Downloads a ZIM after the download pop-up: [replaces] makes it an update. Wait for Wi-Fi starts it waiting.
Future<void> downloadZim(BuildContext context, BrowseState browse, CatalogEntry entry, {ZimFile? replaces}) async {
  final dir = browse.sources.zimsDir;
  if (dir == null) return;
  final choice = await askToDownload(
    context,
    title: replaces == null ? 'Download ${entry.title}?' : 'Update ${entry.title}?',
    lines: [DownloadLine(entry.summary.isEmpty ? entry.title : '${entry.title}, ${entry.summary}', entry.size)],
    dir: dir.path,
    policy: browse.policy,
  );
  if (choice == DownloadChoice.cancel) return;
  unawaited(browse.download(entry, replaces: replaces, allowMobile: choice == DownloadChoice.now));
}
