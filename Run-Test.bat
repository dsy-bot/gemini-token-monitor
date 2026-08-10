@echo off
title Gemini Token Monitor Debug Test
echo Starting Gemini Token Monitor Debug Test...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File "%~dp0GeminiTokenMonitor.ps1"
echo.
echo Process ended.
pause
