@echo off
title Unregister Gemini Token Monitor from Windows Startup
echo Unregistering from Windows Startup...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "$s=[System.Environment]::GetFolderPath('Startup'); $lnk=Join-Path $s 'GeminiTokenMonitor.lnk'; if(Test-Path $lnk){Remove-Item $lnk -Force; Write-Host '==================================================' -ForegroundColor Yellow; Write-Host '[OK] Gemini Token Monitor removed from Windows Startup.' -ForegroundColor Yellow; Write-Host '==================================================' -ForegroundColor Yellow}else{Write-Host 'Not currently registered in Windows Startup.' -ForegroundColor Cyan}"
echo.
echo Complete!
pause
