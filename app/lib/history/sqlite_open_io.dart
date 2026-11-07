import 'package:sqlite3/sqlite3.dart' as native;
import 'package:sqlite3/common.dart' show CommonDatabase;

/// Opens (or creates) the SQLite file at [path] with the native library.
CommonDatabase openSqliteFile(String path) => native.sqlite3.open(path);

/// A throwaway database in memory.
CommonDatabase openSqliteMemory() => native.sqlite3.openInMemory();
