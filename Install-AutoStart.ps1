# Windows 시작 프로그램 자동 등록 스크립트
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
Write-Host "✅ Gemini Token Monitor 가 시작 프로그램에 정상 등록되었습니다!" -ForegroundColor Green
Write-Host "   등록 경로: $ShortcutPath" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Green
