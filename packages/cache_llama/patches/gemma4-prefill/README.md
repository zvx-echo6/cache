# Gemma 4 prefill experiment

This is a source overlay for the Gemma 4 graph optimization in
https://github.com/ggml-org/llama.cpp/pull/31356 (merged as
6cb3e672e8d10fd4feab1a048bf2967c40623133).

The base remains llama.cpp 620d2225cc436ab0b001e3200e590e3b286ef9ab.
The PR's src/models/gemma4.cpp diff is applied with mask access adapted
to the pinned self_kq_mask_cnv fields and their original dtypes.
Cache does not use
speculative decoding, so common/speculative.cpp is left unchanged.
The upstream MIT license is included.

Base file SHA-256, with LF newlines:
247d458f93ddace3091141d7d7e4da0c0b589bc843e5737d3b39f804eb889339

Overlay SHA-256, with LF newlines:
cfaa5c46cc3949551c79f59a6fa15f74e7d398e6a02dbab24b8503b788d3bd0a

Configure with -DCACHE_LLAMA_GEMMA4_PREFILL_OPT=ON to test the overlay.
The default is OFF. CMake checks the base file and replaces only that
source in the llama target. It does not modify the pinned submodule.
cl_info reports engine_build=cache-gemma4-prefill-31356 when enabled.

For review, compare the pinned src/models/gemma4.cpp with this gemma4.cpp.
Models, tokenization, templates, sampling, tools, and Cache request handling
are not changed by this overlay.
