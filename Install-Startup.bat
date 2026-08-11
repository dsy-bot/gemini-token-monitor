@echo off
title Register Gemini Token Monitor to Windows Startup
echo Registering to Windows Startup...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "$dir='%~dp0'; $vbs=Join-Path $dir 'Launch-Silent.vbs'; $s=[System.Environment]::GetFolderPath('Startup'); $lnk=Join-Path $s 'GeminiTokenMonitor.lnk'; $w=New-Object -ComObject WScript.Shell; $sc=$w.CreateShortcut($lnk); $sc.TargetPath='wscript.exe'; $sc.Arguments='\"'+$vbs+'\"'; $sc.WorkingDirectory=$dir; $sc.Description='Gemini Token Monitor - Auto Start'; $sc.Save(); Write-Host '==================================================' -ForegroundColor Green; Write-Host '[OK] Gemini Token Monitor registered to Windows Startup successfully!' -ForegroundColor Green; Write-Host '     Shortcut Path: '$lnk -ForegroundColor Yellow; Write-Host '==================================================' -ForegroundColor Green"
echo.
echo Complete! Check your shell:startup folder or Task Manager.
pause
