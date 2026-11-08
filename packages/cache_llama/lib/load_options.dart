import 'dart:convert';

/// The cl_configure options for the next load, as JSON. [prefixDir]: where the fixed prompt start (system prompt and tools) is
/// saved between runs; null: not saved. [repackWeights] (Android, measurement only): repack the CPU weights instead of keeping
/// them file-backed in the mmap, which is the Android default; never chosen automatically.
String llamaLoadOptions({String? prefixDir, bool repackWeights = false}) =>
    jsonEncode({'prefix_dir': prefixDir ?? '', 'repack_weights': repackWeights});
