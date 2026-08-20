$path = Resolve-Path "GeminiTokenMonitor.ps1"
$bytes = [System.IO.File]::ReadAllBytes($path)
# BOM 확인
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host "BOM: OK (UTF-8 BOM)"
} else {
    Write-Host "BOM: MISSING"
}

# PowerShell 5.1: [System.Text.Encoding]::UTF8 으로 읽어서 파싱
$content = [System.Text.Encoding]::UTF8.GetString($bytes)
$errors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Host "Line $($e.Extent.StartLineNumber): $($e.Message)"
    }
} else {
    Write-Host "Syntax OK - 0 errors"
}
