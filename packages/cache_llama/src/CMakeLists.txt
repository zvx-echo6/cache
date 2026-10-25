# Native layer of Cache: llama.cpp (+ its chat engine) behind a small C ABI.
# Built by the Android Gradle Plugin for apps, or directly with the NDK toolchain for tests.
cmake_minimum_required(VERSION 3.22)

project(cache_llama_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(CACHE_LLAMA_TEST_CLI "Build the cl_test command line test" OFF)

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
if (ANDROID AND ANDROID_ABI STREQUAL "arm64-v8a")
  # Runtime CPU dispatch: the CPU backend is built as one libggml-cpu-*.so per feature level (dotprod,
  # i8mm, sve2 ...) and cache_llama loads the fastest one the phone's CPU supports at startup.
  # This needs shared libraries; the Gradle build packages all of them into the APK.
  set(BUILD_SHARED_LIBS        ON CACHE BOOL "" FORCE)
  set(GGML_BACKEND_DL          ON CACHE BOOL "" FORCE)
  set(GGML_CPU_ALL_VARIANTS    ON CACHE BOOL "" FORCE)
  set(CACHE_LLAMA_BACKEND_DL   ON)
endif()

add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp" llama.cpp)

add_library(cache_llama SHARED cache_llama.cpp)
target_link_libraries(cache_llama PRIVATE llama llama-common)
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
endif()
