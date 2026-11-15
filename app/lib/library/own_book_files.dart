import 'package:flutter/foundation.dart';

import '../sharing/sharing_state.dart';
import 'cds_shelf_source.dart';
import 'shelf_source.dart';

/// The phone's [BookFiles] for 1.1: "Delete from all your devices" for a book in the person's own library (My books), through
/// [CdsShelfSource.deleteOwnBook]. Stream-back and "Remove from this device" (offload) come with 1.2, so they say they cannot be
/// done here, as [BookFilesUnavailable] does.
class OwnBookFiles extends ChangeNotifier implements BookFiles {
  OwnBookFiles(this.shelves, {this.sharing});

  final CdsShelfSource shelves;

  /// Where the shares and the linked devices are; none (a test, Sharing not started): nothing is synced.
  final SharingState? sharing;

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
  bool syncedWithOtherDevice(ShelfBook book) {
    final sh = sharing;
    if (sh == null) return false;
    return shelves.ownFilesOf(book).any((f) => sh.libraryTakenByAnotherDevice(f.library.folderName));
  }
  @override
  Future<void> deleteEverywhere(ShelfBook book) async {
    await shelves.deleteOwnBook(book);
    notifyListeners();
  }
}
