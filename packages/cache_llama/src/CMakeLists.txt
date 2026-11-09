# Native layer of Cache: llama.cpp (+ its chat engine) behind a small C ABI.
# Built by the Android Gradle Plugin for apps, or directly with the NDK toolchain for tests.
cmake_minimum_required(VERSION 3.22)

project(cache_llama_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(CACHE_LLAMA_TEST_CLI "Build the cl_test command line test" OFF)
option(CACHE_LLAMA_GEMMA4_PREFILL_OPT "Test the isolated Gemma 4 prefill optimization" OFF)
# Desktop/server x86_64 only (not Android): let ggml use AVX2/FMA/F16C. Off = baseline x86-64, runs anywhere, slower.
option(CACHE_LLAMA_X86_AVX2 "Enable AVX2/FMA/F16C on non-Android x86_64 builds" OFF)
# Tests only (native-libs.yml): build the CPU backend as loadable variants off Android too, so CI runs the phone's
# CL_BACKEND_DL path (load_cpu_backend) on Linux. The variant libraries must sit next to libcache_llama.so
# (CMAKE_LIBRARY_OUTPUT_DIRECTORY), as they do in the APK.
option(CACHE_LLAMA_TEST_BACKEND_DL "Build the CPU backend as loadable variants on a non-Android host, for tests" OFF)

# --- llama.cpp options: static, no tests/tools/server, no network or download code ---
set(LLAMA_BUILD_COMMON   ON  CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_UI       OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL           OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL        OFF CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS     OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS    OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE          OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP          OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE       OFF CACHE BOOL "" FORCE)

if (ANDROID_ABI STREQUAL "x86_64")
  # Only for emulator testing; the emulator CPU must report avx2/fma/f16c.
  set(GGML_AVX2 ON CACHE BOOL "" FORCE)
  set(GGML_FMA  ON CACHE BOOL "" FORCE)
  set(GGML_F16C ON CACHE BOOL "" FORCE)
endif()
if ((ANDROID AND ANDROID_ABI STREQUAL "arm64-v8a") OR CACHE_LLAMA_TEST_BACKEND_DL)
  # Runtime CPU dispatch: the CPU backend is built as one libggml-cpu-*.so per feature level (dotprod,
  # i8mm, sve2 ...) and cache_llama loads the fastest one the phone's CPU supports at startup.
  # This needs shared libraries; the Gradle build packages all of them into the APK.
  set(BUILD_SHARED_LIBS        ON CACHE BOOL "" FORCE)
  set(GGML_BACKEND_DL          ON CACHE BOOL "" FORCE)
  set(GGML_CPU_ALL_VARIANTS    ON CACHE BOOL "" FORCE)
  set(CACHE_LLAMA_BACKEND_DL   ON)
endif()

if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
  # Metal on the GPU; the shader source is embedded in the library and compiled by the system on first use, so the app
  # carries no separate .metallib file.
  set(GGML_METAL               ON  CACHE BOOL "" FORCE)
  set(GGML_METAL_EMBED_LIBRARY ON  CACHE BOOL "" FORCE)
endif()

if (NOT ANDROID AND CACHE_LLAMA_X86_AVX2)
  set(GGML_AVX2 ON CACHE BOOL "" FORCE)
  set(GGML_FMA  ON CACHE BOOL "" FORCE)
  set(GGML_F16C ON CACHE BOOL "" FORCE)
endif()

add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp" llama.cpp)

# Use a checked source overlay instead of changing the engine pin or its working tree.
if (CACHE_LLAMA_GEMMA4_PREFILL_OPT)
  set(_gemma_base "${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp/src/models/gemma4.cpp")
  file(READ "${_gemma_base}" _gemma_base_text)
  string(REPLACE "\r\n" "\n" _gemma_base_text "${_gemma_base_text}")
  string(SHA256 _gemma_base_hash "${_gemma_base_text}")
  if (NOT _gemma_base_hash STREQUAL "247d458f93ddace3091141d7d7e4da0c0b589bc843e5737d3b39f804eb889339")
    message(FATAL_ERROR "Gemma 4 overlay needs review: the pinned base file changed")
  endif()
  set(_gemma_overlay "${CMAKE_CURRENT_BINARY_DIR}/cache-gemma4-prefill/gemma4.cpp")
  configure_file("${CMAKE_CURRENT_LIST_DIR}/../patches/gemma4-prefill/gemma4.cpp"
                 "${_gemma_overlay}" COPYONLY)
  get_target_property(_llama_source_dir llama SOURCE_DIR)
  get_target_property(_llama_sources llama SOURCES)
  set(_llama_patched_sources "")
  set(_gemma_replaced 0)
  foreach (_source IN LISTS _llama_sources)
    get_filename_component(_source_abs "${_source}" ABSOLUTE BASE_DIR "${_llama_source_dir}")
    get_filename_component(_base_abs "${_gemma_base}" ABSOLUTE)
    if (_source_abs STREQUAL _base_abs)
      math(EXPR _gemma_replaced "${_gemma_replaced} + 1")
    else()
      list(APPEND _llama_patched_sources "${_source}")
    endif()
  endforeach()
  if (NOT _gemma_replaced EQUAL 1)
    message(FATAL_ERROR "Expected exactly one Gemma 4 graph source in the llama target")
  endif()
  list(APPEND _llama_patched_sources "${_gemma_overlay}")
  set_property(TARGET llama PROPERTY SOURCES "${_llama_patched_sources}")
  set_source_files_properties("${_gemma_overlay}" TARGET_DIRECTORY llama PROPERTIES
    INCLUDE_DIRECTORIES "${_llama_source_dir};${_llama_source_dir}/models")
  message(STATUS "Cache engine: cache-gemma4-prefill-31356")
endif()


if (CACHE_LLAMA_BACKEND_DL)
  # Keep only the armv8.x CPU variants. On the Pixel 8 (Tensor G3) the SVE2 variant (armv9.*) read
  # prompts at about half the speed of armv8.6_1, and ggml prefers it because it scores higher.
  foreach (v android_armv9.0_1 android_armv9.2_1 android_armv9.2_2)
    if (TARGET ggml-cpu-${v})
      set_target_properties(ggml-cpu-${v} PROPERTIES EXCLUDE_FROM_ALL ON)
    endif()
  endforeach()
endif()

if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
  # iOS: one static library, linked into the app and found with DynamicLibrary.process() (ios/build-native.sh).
  add_library(cache_llama STATIC cache_llama.cpp)
else()
  add_library(cache_llama SHARED cache_llama.cpp)
endif()
target_link_libraries(cache_llama PRIVATE llama llama-common)
if (CACHE_LLAMA_GEMMA4_PREFILL_OPT)
  target_compile_definitions(cache_llama PRIVATE CACHE_GEMMA4_PREFILL_OPT=1)
endif()
# common/ does not export its include path, so add it (chat.h, common.h, sampling.h, json.h ...)
target_include_directories(cache_llama PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}"
  "${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp/common"
  "${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp/vendor")
set_target_properties(cache_llama PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
if (CACHE_LLAMA_BACKEND_DL)
  target_compile_definitions(cache_llama PRIVATE CL_BACKEND_DL=1)
endif()
if (ANDROID)
  target_link_libraries(cache_llama PRIVATE log)  # CPU variant and thread choice go to logcat
endif()

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(cache_llama PRIVATE "-Wl,-z,max-page-size=16384")
endif()

if (CACHE_LLAMA_TEST_CLI)
  add_executable(cl_test "${CMAKE_CURRENT_LIST_DIR}/../test/cl_test.cpp")
  target_include_directories(cl_test PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
  target_link_libraries(cl_test PRIVATE cache_llama)
endif()

if (CACHE_LLAMA_TEST_CLI)
  # Baseline case runner: C API + the JSON library vendored in llama.cpp only.
  add_executable(cl_cases "${CMAKE_CURRENT_LIST_DIR}/../test/cl_cases.cpp")
  target_include_directories(cl_cases PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}"
    "${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp/vendor")
  target_link_libraries(cl_cases PRIVATE cache_llama)

  # Prompt reuse timing (saved prefix, tool_choice "none" rounds): C API + the vendored JSON library.
  add_executable(cl_prefix "${CMAKE_CURRENT_LIST_DIR}/../test/cl_prefix.cpp")
  target_include_directories(cl_prefix PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}"
    "${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp/vendor")
  target_link_libraries(cl_prefix PRIVATE cache_llama)
endif()
