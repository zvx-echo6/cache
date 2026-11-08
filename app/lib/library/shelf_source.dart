import 'package:flutter/foundation.dart';

/// What Bookshelves draws, whatever puts the books on the shelves: the shelves (a tree: the source's top shelves, then each
/// one's children), then the books on each shelf. The app's source is the Cache Decimal System ([CdsShelfSource]: ten classes,
/// nine divisions each, books placed by the library log). A folder tree (a linked folder's own folders) can be supplied later
/// through the same interface: its shelves are folders, with no [Shelf.number], and it has no [ShelfSource.placer] (a folder's
/// books are placed by moving files).
abstract class ShelfSource implements Listenable {
  /// The line under the Bookshelves title: "Shelved by the Cache Decimal System".
  String get scheme;

  /// The short name of the scheme in rows ("CDS"), or null when shelves have no numbers.
  String? get shortName;

  /// The top shelves, in order: every one shows, empty ones too (the whole scheme is visible).
  List<Shelf> get shelves;

  /// The shelf [id] anywhere in the tree, or null.
  Shelf? shelf(String id);

  /// The shelves from the top down to [id], [id]'s own last: the breadcrumb ("Bookshelves > CDS 200 > CDS 210").
  List<Shelf> pathTo(String id);

  /// The books standing on shelf [id] itself (a division), in shelf order (by call number).
  List<ShelfBook> booksOn(String id);

  /// Every book on [shelf] and the shelves under it.
  int countUnder(Shelf shelf);

  /// The books no shelf holds yet, in the order they came.
  List<ShelfBook> get unsorted;

  /// Every book the source has (shelved and unsorted).
  int get bookCount;

  /// The book [id], or null when it is gone.
  ShelfBook? book(String id);

  /// True while the source is still reading what it has (the first time): an empty list then is not "No books yet".
  bool get loading;

  /// "Go to a number": what [text] names (a shelf or a book), or null when nothing does. Null [goToHint] leaves the box out.
  ShelfTarget? goTo(String text);

  /// The box's hint ("Go to a number, such as 530"); null: the source has no numbers to go to.
  String? get goToHint;

  /// Placing books on shelves (Place it, Move, Place all best guesses), or null when this source cannot.
  ShelfPlacer? get placer;

  /// Whether [book] is searchable on this device.
  BookSearch searchOf(ShelfBook book);
}

enum BookSearchState {
  /// "Searchable here".
  searchable,

  /// "Making it searchable 40%".
  making,

  /// Not searchable yet, and nothing is making it so right now.
  waiting,

  /// Its library is being opened.
  gettingReady,

  /// Its library could not be read.
  failed,
}

@immutable
class BookSearch {
  const BookSearch(this.state, [this.fraction]);

  final BookSearchState state;

  /// How far [BookSearchState.making] is, when known.
  final double? fraction;
}

/// One shelf: a CDS class or division, or a folder.
@immutable
class Shelf {
  const Shelf({required this.id, required this.name, this.number, this.children = const [], this.assigned = true});

  /// Unique in its source ("200", "210", a folder's path).
  final String id;
  final String name;

  /// The printed number ("200"), set in the fixed-width face; null for a shelf without one.
  final String? number;
  final List<Shelf> children;

  /// False for a number the scheme keeps free; such a shelf is never shown.
  final bool assigned;

  /// Books stand on it directly (a division, a folder with no subfolders).
  bool get holdsBooks => children.isEmpty;

  /// What its rows print: "CDS 210" for a numbered shelf (with [prefix]), else its name.
  String label(String? prefix) => number == null ? name : (prefix == null ? number! : '$prefix $number');
}

/// Who put a book where it is.
enum ShelvedBy {
  /// The sorter, a label, or the library's builder: "Filed by Cache".
  cache,

  /// A person: "Placed by you".
  person,
}

/// One book as Bookshelves shows it.
@immutable
class ShelfBook {
  const ShelfBook({
    required this.id,
    required this.title,
    this.shelf,
    this.callNumber,
    this.shelvedBy,
    this.suggestions = const [],
    this.author,
    this.edition,
    this.pages,
    this.bytes,
    this.stored,
    this.sourceKey,
    this.docId,
    this.originalTitle,
    this.pdfPath,
  });

  /// The title the book came with, when it was renamed since ("Original title").
  final String? originalTitle;

  /// The book's PDF on this device (a file path), or null when it is not here. Open reads it in the PDF reader.
  final String? pdfPath;

  /// Unique in its source.
  final String id;
  final String title;

  /// The shelf it stands on ([Shelf.id]); null in Unsorted.
  final String? shelf;

  /// "CDS 210-001"; null in Unsorted ("CDS —").
  final String? callNumber;
  final ShelvedBy? shelvedBy;

  /// Where Cache would put it, best first (shelf ids), as stored with the book when it was built; never a guess made here.
  final List<String> suggestions;
  final String? author;

  /// "5th edition, 2018".
  final String? edition;
  final int? pages;

  /// The size of its PDF as stored, when known.
  final int? bytes;

  /// What making it smaller did, in the approved words ("Stored 41 MB (was 58 MB) · Smaller scans: Balanced"); null when unknown.
  final String? stored;

  /// Which collection of the source the book belongs to (a library's folder), for the source's own use.
  final String? sourceKey;

  /// The book's document id in its library.
  final String? docId;

  bool get unsorted => shelf == null;
}

/// What "Go to a number" found.
@immutable
class ShelfTarget {
  const ShelfTarget.shelf(String this.shelfId) : bookId = null;
  const ShelfTarget.book(String this.bookId, {this.shelfId});

  final String? shelfId;
  final String? bookId;
}

/// Puts books on shelves. Numbers are permanent: a moved book gets a new number in its new shelf and its old one is never used
/// again, so an Undo files the book again (back to Unsorted, or a new number in its old shelf).
abstract class ShelfPlacer {
  /// The number a book would get on [shelfId] if placed now ("CDS 350-004"), for the sheet to say before the tap.
  String? nextNumber(String shelfId);

  /// Places every book on its shelf at once (Place it, Move, Place all best guesses).
  Future<Placement> place(List<(ShelfBook, String)> moves);

  /// Undoes [placement]: every book goes back where it was.
  Future<void> undo(Placement placement);
}

/// What a placement did, for its Undo and its message.
@immutable
class Placement {
  const Placement(this.books);

  final List<PlacedBook> books;
}

@immutable
class PlacedBook {
  const PlacedBook({required this.before, required this.shelf, required this.callNumber});

  /// The book as it was (its shelf, or Unsorted).
  final ShelfBook before;
  final String shelf;

  /// "CDS 350-004".
  final String? callNumber;
}

/// Where a book's PDF is, as this device knows it.
enum BookFileWhere {
  /// On this device.
  here,

  /// Not on this device; [BookFileState.from] names a device that has it, when known.
  elsewhere,

  /// This device cannot tell.
  unknown,
}

@immutable
class BookFileState {
  const BookFileState(this.where, {this.bytes, this.from});

  static const unknown = BookFileState(BookFileWhere.unknown);

  final BookFileWhere where;
  final int? bytes;

  /// "Kitchen tablet".
  final String? from;
}

/// What came of "Remove from this device".
enum RemoveOutcome {
  removed,

  /// No other device has a checked copy right now; nothing was removed.
  noOtherCopy,

  /// No device is linked.
  noLinkedDevice,
}

/// What this device can do with books beyond reading the PDF it has ([ShelfBook.pdfPath], opened in the PDF reader): which other
/// device has a book, getting it, taking it off this device (only after a live check that another device has a checked copy),
/// and deleting a book on every linked device. On phones none of this is available yet ([BookFilesUnavailable]); the book page
/// then shows Download greyed and the delete choices as not available yet.
abstract class BookFiles implements Listenable {
  /// Which linked device has the book ([BookFileState.from]), when this device knows.
  BookFileState stateOf(ShelfBook book);

  /// Null when it cannot be downloaded to this device.
  Future<void> Function()? download(ShelfBook book);

  /// Whether "Remove from this device" can be asked here.
  bool get canRemove;

  /// Takes the books off this device after asking the other devices, right now, whether one has a checked copy of each.
  Future<(RemoveOutcome, int removed, int kept)> removeFromDevice(List<ShelfBook> books);

  /// Whether "Delete from all your devices" can be done here.
  bool get canDeleteEverywhere;

  /// Deletes the book, its search index and its call number on every linked device.
  Future<void> deleteEverywhere(ShelfBook book);
}

/// The phone's [BookFiles] for 1.1: STUB. Phones have no stream-back or offload yet (the live "does another device have a
/// checked copy" check and fetching a book's pages from a linked device are not built), and deleting a book on every device
/// needs the search core to drop its passages, which it cannot yet. Everything says it cannot be done, nothing is faked.
class BookFilesUnavailable extends ChangeNotifier implements BookFiles {
  @override
  BookFileState stateOf(ShelfBook book) => BookFileState.unknown;
  @override
  Future<void> Function()? download(ShelfBook book) => null;
  @override
  bool get canRemove => false;
  @override
  Future<(RemoveOutcome, int, int)> removeFromDevice(List<ShelfBook> books) => throw UnsupportedError('not on this device yet');
  @override
  bool get canDeleteEverywhere => false;
  @override
  Future<void> deleteEverywhere(ShelfBook book) => throw UnsupportedError('not on this device yet');
}

/// The book's original file where it was found (a linked folder's own copy), for the book page's "Open original". The Linux
/// session supplies it; the phone has none.
abstract class OriginalFileProvider implements Listenable {
  /// Whether "Open original" shows for [book]: its original is available on this device now.
  bool available(ShelfBook book);

  Future<void> open(ShelfBook book);
}
