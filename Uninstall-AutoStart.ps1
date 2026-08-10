# Windows 시작 프로그램 등록 해제 스크립트
$StartupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$ShortcutPath = Join-Path $StartupFolder "GeminiTokenMonitor.lnk"

if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
    Write-Host "==================================================" -ForegroundColor Yellow
    Write-Host "🗑️ Gemini Token Monitor 가 시작 프로그램에서 제거되었습니다." -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Yellow
} else {
    Write-Host "시작 프로그램에 등록되어 있지 않습니다." -ForegroundColor Cyan
}
