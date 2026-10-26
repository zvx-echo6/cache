@echo off
rem Cross-build Valhalla 3.7.0 + valhalla_shim for Android arm64-v8a (API 24) from a Windows host.
rem Output: %WORK%\build-android\libvalhalla_shim.so (+ valhalla_shim_test executable).
rem Usage: build-android.bat [work dir, default C:\src\valhalla-build]
rem NDK: r28 (28.2.13676358), the version Flutter's Android build uses. Override with ANDROID_NDK_HOME.
setlocal
set "WORK=%~1"
if "%WORK%"=="" set "WORK=C:\src\valhalla-build"
if "%CACHE_VCPKG%"=="" set "CACHE_VCPKG=C:\src\vcpkg"
if "%ANDROID_NDK_HOME%"=="" set "ANDROID_NDK_HOME=%LOCALAPPDATA%\Android\Sdk\ndk\28.2.13676358"
set "HERE=%~dp0.."
set "VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
if not exist "%VS%\VC\Auxiliary\Build\vcvars64.bat" set "VS=C:\Program Files\Microsoft Visual Studio\2022\Community"
rem vcvars is needed only so vcpkg can build its HOST tools (protoc) with MSVC; the target uses the NDK clang.
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1
set "VCPKG_ROOT=%CACHE_VCPKG%"
set "PATH=%HERE%\scripts\stubs;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
if not exist "%ANDROID_NDK_HOME%\build\cmake\android.toolchain.cmake" (echo NDK not found: %ANDROID_NDK_HOME% & exit /b 1)

if not exist "%WORK%\src\CMakeLists.txt" (
  git clone --branch 3.7.0 --depth 1 --recurse-submodules --shallow-submodules https://github.com/valhalla/valhalla.git "%WORK%\src" || exit /b 1
)
copy /y "%HERE%\tz\leapseconds" "%WORK%\src\third_party\tz\leapseconds" >nul || exit /b 1
powershell -NoProfile -Command "(Get-Item '%WORK%\src\third_party\tz\leapseconds').LastWriteTime = Get-Date"

cmake -S "%HERE%" -B "%WORK%\build-android" -G Ninja -DCMAKE_BUILD_TYPE=Release ^
  -DVALHALLA_SRC="%WORK%\src" ^
  -DCMAKE_TOOLCHAIN_FILE="%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake" ^
  -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE="%ANDROID_NDK_HOME%\build\cmake\android.toolchain.cmake" ^
  -DVCPKG_TARGET_TRIPLET=arm64-android-rel -DVCPKG_HOST_TRIPLET=x64-windows-static-md-rel ^
  -DVCPKG_OVERLAY_TRIPLETS="%HERE%\triplets" -DVCPKG_INSTALL_OPTIONS=--x-abi-tools-use-exact-versions ^
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static || exit /b 1
cmake --build "%WORK%\build-android" || exit /b 1
"%ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe" -o "%WORK%\build-android\libvalhalla_shim.stripped.so" "%WORK%\build-android\libvalhalla_shim.so"
echo BUILD OK: %WORK%\build-android\libvalhalla_shim.so
