import 'dart:io';

import 'package:flutter/widgets.dart';

/// One kind of thing Cache keeps on the phone (Library, Models, Regions, ...) and the folders that hold it: the one list Storage
/// measures and Sharing shares, so the two always agree. A new kind is one more entry in the app's list.
class DataKind {
  const DataKind({
    required this.id,
    required this.label,
    required this.icon,
    this.shared = _none,
    this.local = _noDirs,
    this.notShared = const {},
    this.count,
    this.list,
    this.inStorage = true,
    this.shareLabel,
    this.items,
    this.itemDepth = const {},
    this.remoteItem,
    this.alongside,
    this.setPrivate,
  });

  final String id;
  final String label;
  final IconData icon;

  /// The folders linked devices keep the same, by their fixed share id (the same kind on two devices is one shared folder). Read
  /// when used, because some folders are only known once the app has started.
  final Map<String, Directory?> Function() shared;

  /// Folders counted in Storage but never shared: what each device builds for itself (search indexes) or fetches on its own.
  final List<Directory?> Function() local;

  /// What each device builds for itself inside a shared folder, by share id, so it never syncs: path patterns in the sync engine's
  /// form (segments, `*` for any one segment, each covering everything under it), as `*/index` for every library's search index.
  final Map<String, List<String>> notShared;

  /// How many items there are ("4" in "4 · 113.6 GB"); null when the kind has no items to count.
  final int Function()? count;

  /// The screen that lists the items to remove them (each removal confirms); null when there is none.
  final Widget Function()? list;

  /// False for a kind that Storage does not measure.
  final bool inStorage;

  /// Its name under "Shared with linked devices" when that differs from [label] ("Maps" for Regions).
  final String? shareLabel;
  String get sharingLabel => shareLabel ?? label;

  /// The items of this kind on this device, each shared or not on its own (a library or ZIM, a map layer, a model, a notebook, a
  /// video); null when the kind has none.
  final List<ShareItem> Function()? items;

  /// How deep an item sits in each shared folder, by share id: 1 (the default) for a file or folder at the top (a ZIM, a
  /// library), 2 for `store/<layer>.sqlite`, 3 for `downloads/<site>/<video>`. What a linked device holds is listed by it.
  final Map<String, int> itemDepth;

  /// The item a path listed by a linked device is ([itemDepth] segments of it), or null when it is not one (a file every item
  /// of the kind needs, which travels with the kind). Null: every listed path is an item, named after its file.
  final ShareItem? Function(String share, String path, int bytes)? remoteItem;

  /// The other paths that go with an item, as sync patterns in the same shared folder (a ZIM's saved icon beside it): switched off
  /// and synced with the item, but never an item of their own. Null: the item's path covers all of it.
  final List<String> Function(String share, String path)? alongside;

  /// Switches a private item on or off (a private notebook's "Include in sync and sharing"); its state is [ShareItem.on].
  final Future<void> Function(ShareItem item, bool on)? setPrivate;

  /// Every folder of this kind.
  List<Directory?> get folders => [...shared().values, ...local()];

  static Map<String, Directory?> _none() => const {};
  static List<Directory?> _noDirs() => const [];
}

/// One item of a kind, shared or not on its own: [path] in the shared folder [share], as a sync pattern (it covers everything
/// under it). The kind's share carries the items switched off as one list; there is never a share per item.
class ShareItem {
  const ShareItem({required this.share, required this.path, required this.name, this.bytes, this.private = false, this.on});

  final String share;
  final String path;
  final String name;

  /// Its size here, when known (else what a linked device holds of it).
  final int? bytes;

  /// A private notebook: listed, and off until the person switches it on.
  final bool private;

  /// For a private item, whether it is switched on (kept where its "Include in sync and sharing" is); null for any other item.
  final bool? on;

  /// The same item on every device.
  String get key => '$share/$path';

  /// A path a linked device lists, as an item named after its file ("wikipedia_en_all_maxi_2026-10.zim" -> "wikipedia en all
  /// maxi 2026-10").
  static ShareItem plain(String share, String path, int bytes) {
    final file = path.split('/').last;
    final dot = file.lastIndexOf('.');
    final stem = dot > 0 ? file.substring(0, dot) : file;
    return ShareItem(share: share, path: path, name: stem.replaceAll('_', ' '), bytes: bytes);
  }
}
