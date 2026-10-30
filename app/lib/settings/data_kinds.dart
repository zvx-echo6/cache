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
    this.count,
    this.list,
    this.inStorage = true,
  });

  final String id;
  final String label;
  final IconData icon;

  /// The folders linked devices keep the same, by their fixed share id (the same kind on two devices is one shared folder). Read
  /// when used, because some folders are only known once the app has started.
  final Map<String, Directory?> Function() shared;

  /// Folders counted in Storage but never shared: what each device builds for itself (search indexes) or fetches on its own.
  final List<Directory?> Function() local;

  /// How many items there are ("4" in "4 · 113.6 GB"); null when the kind has no items to count.
  final int Function()? count;

  /// The screen that lists the items to remove them (each removal confirms); null when there is none.
  final Widget Function()? list;

  /// False for a kind that is only shared (the Shared folder holds the person's own files and is not one of Cache's kinds).
  final bool inStorage;

  /// Every folder of this kind.
  List<Directory?> get folders => [...shared().values, ...local()];

  static Map<String, Directory?> _none() => const {};
  static List<Directory?> _noDirs() => const [];
}
