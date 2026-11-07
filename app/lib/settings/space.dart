import '../browse/zim_download.dart' show FreeSpace, freeBytesOnDisk;
import 'total_space.dart';

export 'total_space.dart' show totalBytesOnDisk;

const int _gb = 1 << 30;

/// The space Cache always leaves for the phone: 10% of the storage, at least 5 GB and at most 20 GB. With the size of the storage
/// unknown it is the most, 20 GB.
int reserveFor(int? totalBytes) => totalBytes == null ? 20 * _gb : (totalBytes ~/ 10).clamp(5 * _gb, 20 * _gb);

/// The size of the file system holding [dir], or null when it cannot be told.
typedef TotalSpace = int? Function(String dir);

/// The phone's storage as a download sees it: what is free, what Cache leaves for the phone, and what is left to use.
class Space {
  const Space({required this.free, required this.reserve});

  /// Reads the storage holding [dir].
  factory Space.of(String dir, {FreeSpace freeSpace = freeBytesOnDisk, TotalSpace totalSpace = totalBytesOnDisk}) =>
      Space(free: freeSpace(dir), reserve: reserveFor(totalSpace(dir)));

  /// Free bytes (on iOS the space available for important use), or null when the phone cannot say.
  final int? free;

  /// What Cache never uses ([reserveFor]).
  final int reserve;

  /// What a download may use; null when the free space is unknown.
  int? get usable => free == null ? null : (free! - reserve).clamp(0, free!);

  /// How many more bytes are needed before [bytes] fit; 0 when they fit or the free space is unknown.
  int shortBy(int bytes) => usable == null ? 0 : (bytes - usable!).clamp(0, bytes);
}

/// A [FreeSpace] that leaves the reserve out: downloads that check free space with it never use the space kept for the phone.
int? usableBytesOnDisk(String dir) => Space.of(dir).usable;
