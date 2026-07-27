@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\uninstall-context-menu.ps1"
if errorlevel 1 pause
endlocal
