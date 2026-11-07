import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../screens/download_confirm.dart';
import '../settings/space.dart' show Space;
import '../sources/sources_state.dart' show ZimFile;
import '../theme.dart';
import '../video/format.dart';
import 'browse_state.dart';
import 'opds.dart';
import 'web/device_api.dart' show DeviceException;

/// What the Library's hold menu (and the "..." of an opened item) offers for one item. An action that does not apply is null and
/// is left out of the menu.
class LibraryActions {
  const LibraryActions({required this.title, required this.bytes, this.delete, this.checkUpdate, this.changeIcon, this.addToHome, this.free, this.again, this.parts, this.linkedFolders});

  /// The last line of the delete confirm; null: "You can download it again later."
  final String? again;

  final String title;
  final int bytes;

  /// Free bytes on the phone now, for the delete confirm.
  final int? free;
  final Future<void> Function()? checkUpdate;
  final Future<void> Function()? changeIcon;
  final VoidCallback? addToHome;
  /// Null for an item that cannot be deleted (the guide that ships in the app).
  final Future<void> Function()? delete;

  /// The item's parts above the actions (a ZIM's PDFs, which can be made searchable); null for none.
  final WidgetBuilder? parts;

  /// Opens linked-folder management for this library when supported.
  final Future<void> Function()? linkedFolders;
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
            if (a.parts != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: a.parts!(ctx)),
            if (a.checkUpdate != null) item('update', Icons.system_update_alt, 'Check for update'),
            if (a.changeIcon != null) item('icon', Icons.image_outlined, 'Change icon'),
            if (a.addToHome != null) item('home', Icons.add_to_home_screen, 'Add to Home'),
            if (a.linkedFolders != null) item('linked-folders', Icons.link, 'Linked folders'),
            if (a.delete != null) item('delete', Icons.delete_outline, 'Delete · frees ${formatBytes(a.bytes)}', danger: true),
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
    case 'linked-folders':
      await a.linkedFolders!();
    case 'delete':
      if (a.again != null
          ? await confirmDelete(context, name: a.title, bytes: a.bytes, free: a.free, again: a.again!)
          : await confirmDelete(context, name: a.title, bytes: a.bytes, free: a.free)) {
        await a.delete!();
      }
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

/// Downloads a ZIM after the download pop-up: [replaces] makes it an update. Wait for Wi-Fi starts it waiting. In a browser the device
/// downloads it, and it goes on with the tab closed (the pop-up says so).
Future<void> downloadZim(BuildContext context, BrowseState browse, CatalogEntry entry, {ZimFile? replaces}) async {
  final dir = browse.sources.zimsDir;
  final device = browse.device;
  if (dir == null && device == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (device != null) {
    await device.refresh(); // the room it shows is the room there is now
    if (!context.mounted) return;
  }
  final choice = await askToDownload(
    context,
    title: replaces == null ? 'Download ${entry.title}?' : 'Update ${entry.title}?',
    lines: [DownloadLine(entry.summary.isEmpty ? entry.title : '${entry.title}, ${entry.summary}', entry.size)],
    dir: dir?.path ?? '',
    policy: device == null ? browse.policy : null,
    spaceOf: device == null ? Space.of : (_) => device.spaceForDialog,
    footnote: device == null ? null : 'It keeps downloading if you close this tab.',
  );
  if (choice == DownloadChoice.cancel) return;
  if (device != null) {
    String say;
    try {
      await browse.download(entry, replaces: replaces);
      say = 'Download started. It keeps downloading if you close this tab.';
    } on DeviceException {
      say = "The download couldn't be started. Try again.";
    }
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(say)));
    return;
  }
  unawaited(browse.download(entry, replaces: replaces, allowMobile: choice == DownloadChoice.now));
}
