import 'dart:convert';

/// The gentle pre-read's rate in MB/s when nothing says otherwise: 0, off.
const int kDefaultPrereadMbps = 0;

/// The cl_configure options for the next load, as JSON. [prefixDir]: where the fixed prompt start (system prompt and tools) is
/// saved between runs; null: not saved. [repackWeights] (Android, measurement only): repack the CPU weights instead of keeping
/// them file-backed in the mmap, which is the Android default; never chosen automatically. [prereadMbps]: after the load, the
/// native layer reads the model file into the page cache at this many MB/s ([kDefaultPrereadMbps]; 0: off).
/// [nUbatch] (test builds, measurement): the context's n_ubatch; 0 leaves llama.cpp's default.
String llamaLoadOptions({String? prefixDir, bool repackWeights = false, int prereadMbps = kDefaultPrereadMbps, int nUbatch = 0}) => jsonEncode({
      'prefix_dir': prefixDir ?? '',
      'repack_weights': repackWeights,
      'preread_mbps': prereadMbps < 0 ? 0 : prereadMbps,
      // Only when asked for (a test build): a normal build's options are as they were, and the native side reads a missing key as 0.
      if (nUbatch > 0) 'n_ubatch': nUbatch,
    });
