import 'dart:convert';

/// The cl_configure options for the next load, as JSON. [prefixDir]: where the fixed prompt start (system prompt and tools) is
/// saved between runs; null: not saved. [repackWeights] (Android, measurement only): repack the CPU weights instead of keeping
/// them file-backed in the mmap, which is the Android default; never chosen automatically.
/// [engine]: test builds only (a test APK's launch intent); the "engine" object of cl_configure. With none there is no "engine"
/// key at all, so the options are exactly what every build has always sent.
String llamaLoadOptions({String? prefixDir, bool repackWeights = false, Map<String, dynamic>? engine}) => jsonEncode({
      'prefix_dir': prefixDir ?? '',
      'repack_weights': repackWeights,
      if (engine != null) 'engine': engine,
    });
