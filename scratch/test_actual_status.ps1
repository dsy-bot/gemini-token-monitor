$searchPaths = @(
    (Join-Path $env:USERPROFILE ".gemini\antigravity\conversations"),
    (Join-Path $env:USERPROFILE ".gemini\antigravity\brain"),
    (Join-Path $env:USERPROFILE ".gemini\tmp"),
    (Join-Path $env:APPDATA "gemini"),
    (Join-Path $env:LOCALAPPDATA "gemini")
)

$today = [DateTime]::Today
$now = [DateTime]::Now
$start5HoursAgo = $now.AddHours(-5)

$tokensToday = 0
$tokens5h = 0

foreach ($p in $searchPaths) {
    if ([System.IO.Directory]::Exists($p)) {
        $patterns = @("*.jsonl", "*.json", "*.db")
        foreach ($pat in $patterns) {
            $files = [System.IO.Directory]::EnumerateFiles($p, $pat, [System.IO.SearchOption]::AllDirectories)
            foreach ($filePath in $files) {
                if ($filePath -match '(?i)transcript_full|_full\.jsonl') { continue }
                $lastWrite = [System.IO.File]::GetLastWriteTime($filePath)
                $fileInfo = New-Object System.IO.FileInfo($filePath)
                $ext = $fileInfo.Extension.ToLower()

                if ($ext -eq ".db") {
                    $sizeKb = [int]($fileInfo.Length / 1024)
                    if ($sizeKb -gt 0) {
                        $dbTokens = [long]($sizeKb * 12)
                        if ($lastWrite -ge $today) {
                            $tokensToday += $dbTokens
                            Write-Host "Today DB File: $($fileInfo.Name) | Size: $sizeKb KB | Tokens: $dbTokens | LastWrite: $lastWrite"
                        }
                        if ($lastWrite -ge $start5HoursAgo) {
                            $tokens5h += $dbTokens
                            Write-Host "5H DB File: $($fileInfo.Name) | Size: $sizeKb KB | Tokens: $dbTokens | LastWrite: $lastWrite"
                        }
                    }
                }
            }
        }
    }
}

Write-Host "=========================================="
Write-Host "Tokens Today: $tokensToday"
Write-Host "Tokens 5H: $tokens5h"
