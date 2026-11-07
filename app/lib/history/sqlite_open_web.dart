import 'package:sqlite3/common.dart' show CommonDatabase;

/// The synchronous SQLite of the phone is not available in a browser.
CommonDatabase openSqliteFile(String path) => throw UnsupportedError('web: openSqliteFile');

/// A throwaway database in memory. Not available in a browser.
CommonDatabase openSqliteMemory() => throw UnsupportedError('web: openSqliteMemory');
