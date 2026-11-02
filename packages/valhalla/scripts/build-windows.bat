@echo off
rem Build Valhalla 3.7.0 + valhalla_shim for Windows x64 (MSVC, vcpkg manifest, release).
rem Usage: build-windows.bat  [work dir, default C:\src\valhalla-build]
rem Needs: Visual Studio 2022 (or Build Tools) with the C++ workload (bundled cmake + ninja are used),
rem        git, and a vcpkg checkout at %CACHE_VCPKG% (default C:\src\vcpkg, commit 0e39c10, bootstrapped).
setlocal
set "WORK=%~1"
if "%WORK%"=="" set "WORK=C:\src\valhalla-build"
if "%CACHE_VCPKG%"=="" set "CACHE_VCPKG=C:\src\vcpkg"
set "HERE=%~dp0.."
set "VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
if not exist "%VS%\VC\Auxiliary\Build\vcvars64.bat" set "VS=C:\Program Files\Microsoft Visual Studio\2022\Community"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1
set "VCPKG_ROOT=%CACHE_VCPKG%"
set "PATH=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"

rem 1. pinned Valhalla source
if not exist "%WORK%\src\CMakeLists.txt" (
  git clone --branch 3.7.0 --depth 1 --recurse-submodules --shallow-submodules https://github.com/valhalla/valhalla.git "%WORK%\src" || exit /b 1
)
rem 2. tz leapseconds: Valhalla generates it with nmake+awk, which Windows lacks. Use the pre-generated copy
rem    (output of `make leapseconds` from the same tz commit); newer timestamp stops the rule from running.
copy /y "%HERE%\tz\leapseconds" "%WORK%\src\third_party\tz\leapseconds" >nul || exit /b 1
powershell -NoProfile -Command "(Get-Item '%WORK%\src\third_party\tz\leapseconds').LastWriteTime = Get-Date"

rem 3. configure (vcpkg installs the manifest deps during configure) + build
cmake -S "%HERE%" -B "%WORK%\build-win" -G Ninja -DCMAKE_BUILD_TYPE=Release ^
  -DVALHALLA_SRC="%WORK%\src" ^
  -DCMAKE_TOOLCHAIN_FILE="%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake" ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static-md-rel -DVCPKG_HOST_TRIPLET=x64-windows-static-md-rel ^
  -DVCPKG_OVERLAY_TRIPLETS="%HERE%\triplets" -DVCPKG_INSTALL_OPTIONS=--x-abi-tools-use-exact-versions || exit /b 1
cmake --build "%WORK%\build-win" || exit /b 1
echo BUILD OK: %WORK%\build-win\valhalla_shim.dll
