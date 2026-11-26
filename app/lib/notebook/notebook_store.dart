import 'dart:io';
import 'dart:typed_data';

import 'notebook_model.dart';

/// What the notebook sync engine needs of the app's notebooks, and nothing of Flutter: the phone's [NotebookState] implements it,
/// and the Dart helper on a server gives the engine one backed by the core. The engine's reads (`notebooks`, `notebook`, `journal`,
/// `nameTaken`, `entries`, `entry`) answer from what the store has now, after [reload]; its writes go through [saveNotebook],
/// [ensureSavedPlaces], [saveEntry] and [deleteEntry]. The private notebooks "Include in sync and sharing" switches are not here:
/// the engine is told them when it is made.
abstract class NotebookStore {
  /// Every notebook, as of the last [reload] or write.
  List<Notebook> get notebooks;

  /// Notebook [id], or null.
  Notebook? notebook(String id);

  /// The Journal notebook (the most recently used one of the Journal template), or null.
  Notebook? get journal;

  /// Whether a notebook already has this name ([exceptId] excepted), spaces and case ignored.
  bool nameTaken(String name, {String? exceptId});

  /// Reads the notebooks again from the store.
  Future<void> reload();

  /// Saves a notebook (a new one when [id] is null) and returns it as stored.
  Future<Notebook> saveNotebook({String? id, String? template, required NotebookDef def, bool? private, bool? map, String? templateRef});

  /// Notebook [id] as the store has it now (not the list read last); null when there is none.
  Future<Notebook?> storedNotebook(String id);

  /// Deletes notebook [id] and its entries (notebook sync: a notebook deleted on another device, once it holds no entries).
  Future<void> deleteNotebook(String id);

  /// The saved places' notebook, made the first time.
  Future<Notebook> ensureSavedPlaces();

  /// A notebook's entries, drafts included: all of them.
  Future<List<NbEntry>> entries(String notebookId);

  /// Entry [id], or null.
  Future<NbEntry?> entry(String id);

  /// Saves the whole entry (a new one when [id] is null) and returns it as stored.
  Future<NbEntry> saveEntry({
    String? id,
    required String notebookId,
    required String occurredAt,
    String? title,
    String? body,
    Map<String, dynamic> values = const {},
    NbPlace? place,
    List<NbPhoto> photos = const [],
    List<NbFile> files = const [],
    bool draft = false,
    bool private = false,
    Map<String, dynamic> props = const {},
  });

  Future<void> deleteEntry(String id);

  /// Where the photo [id] is, or would be, on this device.
  Future<File> photoFile(String id);

  /// A photo's bytes, null when it is not on this device.
  Future<Uint8List?> photoBytes(String id);

  /// Gives photo [to] its own copy of photo [from]'s bytes and thumbnail (a photo belongs to one entry). False when [from] is not
  /// on this device.
  Future<bool> copyPhoto(String from, String to);
}
