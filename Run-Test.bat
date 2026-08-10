@echo off
title Gemini Token Monitor Debug Test
echo Ensuring UTF-8 BOM encoding for Korean text...
cscript //nologo "%~dp0Fix-Encoding.vbs"
echo.
echo Starting Gemini Token Monitor...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File "%~dp0GeminiTokenMonitor.ps1"
echo.
echo Process ended.
pause
