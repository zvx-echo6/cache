import 'package:flutter/foundation.dart';

import 'cds_shelf_source.dart';
import 'shelf_source.dart';

/// The phone's [BookFiles] for 1.1: "Delete from all your devices" for a book in the person's own library (My books), through
/// [CdsShelfSource.deleteOwnBook]. Stream-back and "Remove from this device" (offload) come with 1.2, so they say they cannot be
/// done here, as [BookFilesUnavailable] does.
class OwnBookFiles extends ChangeNotifier implements BookFiles {
  OwnBookFiles(this.shelves);

  final CdsShelfSource shelves;

  @override
  BookFileState stateOf(ShelfBook book) => BookFileState.unknown;
  @override
  Future<void> Function()? download(ShelfBook book) => null;
  @override
  bool get canRemove => false;
  @override
  Future<(RemoveOutcome, int, int)> removeFromDevice(List<ShelfBook> books) => throw UnsupportedError('not on this device yet');
  @override
  bool get canDeleteEverywhere => true;
  @override
  bool canDeleteBook(ShelfBook book) => shelves.ownFilesOf(book).isNotEmpty;
  @override
  Future<void> deleteEverywhere(ShelfBook book) async {
    await shelves.deleteOwnBook(book);
    notifyListeners();
  }
}
