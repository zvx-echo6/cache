import '../browse/zim_download.dart' show FreeSpace, allowedBytesOnDisk, freeBytesOnDisk;
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
  const Space({required this.free, required this.reserve, int? allowed}) : allowed = allowed ?? free;

  /// Reads the storage holding [dir]. With only [freeSpace] given (tests) the allowance is that figure too.
  factory Space.of(String dir, {FreeSpace? freeSpace, FreeSpace? allowedSpace, TotalSpace totalSpace = totalBytesOnDisk}) {
    final free = (freeSpace ?? freeBytesOnDisk)(dir);
    final allowed = allowedSpace != null ? allowedSpace(dir) : (freeSpace == null ? allowedBytesOnDisk(dir) : free);
    return Space(free: free, allowed: allowed, reserve: reserveFor(totalSpace(dir)));
  }

  /// Free bytes now: the figure screens show. Null when the phone cannot say.
  final int? free;

  /// What a download may count on before the reserve: [free] everywhere except iOS, where it also counts half of the space iOS can
  /// purge (see [allowedBytesOnDisk]). Null when the phone cannot say.
  final int? allowed;

  /// What Cache never uses ([reserveFor]).
  final int reserve;

  /// What a download may use; null when the free space is unknown.
  int? get usable => allowed == null ? null : (allowed! - reserve).clamp(0, allowed!);

  /// How many more bytes are needed before [bytes] fit; 0 when they fit or the free space is unknown.
  int shortBy(int bytes) => usable == null ? 0 : (bytes - usable!).clamp(0, bytes);
}

/// A [FreeSpace] that leaves the reserve out: downloads that check free space with it never use the space kept for the phone.
int? usableBytesOnDisk(String dir) => Space.of(dir).usable;
