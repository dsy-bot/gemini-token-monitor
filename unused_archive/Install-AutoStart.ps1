# Windows Startup Registration Script (Pure ASCII)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$VbsPath = Join-Path $ScriptDir "Launch-Silent.vbs"

$StartupFolder = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
$ShortcutPath = Join-Path $StartupFolder "GeminiTokenMonitor.lnk"

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = "wscript.exe"
$Shortcut.Arguments = "`"$VbsPath`""
$Shortcut.WorkingDirectory = $ScriptDir
$Shortcut.Description = "Gemini Token Monitor - Auto Start"
$Shortcut.Save()

Write-Host "==================================================" -ForegroundColor Green
Write-Host "[OK] Gemini Token Monitor registered to Windows Startup successfully!" -ForegroundColor Green
Write-Host "     Shortcut Path: $ShortcutPath" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Green
