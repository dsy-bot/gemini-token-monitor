@echo off
title Unregister Antigravity Token Monitor from Windows Startup
echo Unregistering from Windows Startup...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "$s=[System.Environment]::GetFolderPath('Startup'); $lnk=Join-Path $s 'AntigravityTokenMonitor.lnk'; if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host '==================================================' -ForegroundColor Green; Write-Host '[OK] Shortcut removed from Startup folder successfully!' -ForegroundColor Green; Write-Host '==================================================' -ForegroundColor Green } else { Write-Host '[INFO] No startup shortcut found.' -ForegroundColor Yellow }"
echo.
pause
