@echo off
rem Stub for GNU make: Valhalla runs "make leapseconds" for non-Windows targets (Android) even on a Windows host.
rem The file is pre-generated in ..\tz\leapseconds and copied into the tree, so there is nothing to do.
if exist "%CD%\leapseconds" exit /b 0
echo make stub: leapseconds missing 1>&2
exit /b 1
