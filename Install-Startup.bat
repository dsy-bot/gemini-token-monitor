@echo off
title Register Gemini Token Monitor to Windows Startup
echo Registering to Windows Startup...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Install-AutoStart.ps1"
echo.
echo Complete! Check your shell:startup folder or Task Manager.
pause
