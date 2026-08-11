# Windows Startup Unregistration Script (Pure ASCII)
$StartupFolder = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
$ShortcutPath = Join-Path $StartupFolder "GeminiTokenMonitor.lnk"

if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
    Write-Host "==================================================" -ForegroundColor Yellow
    Write-Host "[OK] Gemini Token Monitor removed from Windows Startup." -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Yellow
} else {
    Write-Host "Not currently registered in Windows Startup." -ForegroundColor Cyan
}
