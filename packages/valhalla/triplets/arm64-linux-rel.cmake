# Linux aarch64, static libraries, release only (position independent: they are linked into a shared library).
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)
set(VCPKG_C_FLAGS "-fPIC")
set(VCPKG_CXX_FLAGS "-fPIC")
set(VCPKG_BUILD_TYPE release)
