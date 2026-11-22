/// Whole megabytes (MiB) in [bytes], rounded down as `bytes >> 20` does on the Dart VM, for negative counts too (a room that went
/// below zero after the reserve). Not `>>`: compiled for a browser, Dart's shifts work on 32 bits, so anything from 4 GB up came
/// out wrong in Cache on Linux. A double holds every byte count up to 2^53 exactly.
int mbOf(int bytes) => (bytes / (1 << 20)).floor();

/// Whole kilobytes (KiB) in [bytes], rounded down the same way (see [mbOf]).
int kbOf(int bytes) => (bytes / (1 << 10)).floor();
