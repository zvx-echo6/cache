# Cache: Valhalla 3.7.0 as a library plus a small C shim (valhalla_shim).
# Route follows Valhalla's documented vcpkg build and the valhalla-mobile layout:
# routing-only modules (no data tools, services, HTTP, Python), Valhalla pulled in
# with add_subdirectory, everything linked into one shared library.
cmake_minimum_required(VERSION 3.21)
project(valhalla_shim LANGUAGES C CXX)

set(VALHALLA_SRC "" CACHE PATH "Path to the Valhalla 3.7.0 source tree (with submodules)")
if(NOT VALHALLA_SRC OR NOT EXISTS "${VALHALLA_SRC}/CMakeLists.txt")
  message(FATAL_ERROR "Set -DVALHALLA_SRC=<valhalla 3.7.0 checkout>")
endif()

# Routing-only configuration (same switches valhalla-mobile uses).
foreach(opt ENABLE_TOOLS ENABLE_DATA_TOOLS ENABLE_PYTHON_BINDINGS ENABLE_NODE_BINDINGS ENABLE_HTTP
            ENABLE_SERVICES ENABLE_TESTS ENABLE_BENCHMARKS ENABLE_GEOTIFF ENABLE_LZ4 ENABLE_CCACHE
            ENABLE_SINGLE_FILES_WERROR)
  set(${opt} OFF CACHE BOOL "" FORCE)
endforeach()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

add_subdirectory("${VALHALLA_SRC}" valhalla)

add_library(valhalla_shim SHARED shim/valhalla_shim.cc shim/valhalla_shim.h)
target_include_directories(valhalla_shim PUBLIC shim)
target_compile_definitions(valhalla_shim PRIVATE VALHALLA_SHIM_BUILDING)
target_link_libraries(valhalla_shim PRIVATE valhalla)
if(ANDROID)
  target_link_options(valhalla_shim PRIVATE -Wl,--exclude-libs,ALL -Wl,--gc-sections -Wl,-z,max-page-size=16384)
endif()

# C test program (also what is pushed to the phone).
add_executable(valhalla_shim_test test/shim_test.c)
target_link_libraries(valhalla_shim_test PRIVATE valhalla_shim)
