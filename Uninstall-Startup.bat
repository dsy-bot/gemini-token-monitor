@echo off
title Unregister Gemini Token Monitor from Windows Startup
echo Unregistering from Windows Startup...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Uninstall-AutoStart.ps1"
echo.
echo Complete!
pause
