@echo off
setlocal
set "SCRIPT=%~dp0DualVolumeCompressor.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
endlocal
