@echo off
title Register Antigravity Token Monitor to Windows Startup
echo Registering AntigravityTokenMonitor.exe to Windows Startup...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "$dir='%~dp0'; $exe=Join-Path $dir 'AntigravityTokenMonitor.exe'; $s=[System.Environment]::GetFolderPath('Startup'); $lnk=Join-Path $s 'AntigravityTokenMonitor.lnk'; $w=New-Object -ComObject WScript.Shell; $sc=$w.CreateShortcut($lnk); $sc.TargetPath=$exe; $sc.WorkingDirectory=$dir; $sc.Description='Antigravity Token Monitor v3.0'; $sc.Save(); Write-Host '==================================================' -ForegroundColor Green; Write-Host '[OK] Antigravity Token Monitor v3.0 registered to Startup successfully!' -ForegroundColor Green; Write-Host '     Shortcut Path: ' $lnk -ForegroundColor Yellow; Write-Host '==================================================' -ForegroundColor Green"
echo.
pause
