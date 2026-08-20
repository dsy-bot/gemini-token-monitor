$paths = @(
    "C:\Users\ms000\.gemini\antigravity\brain",
    "C:\Users\ms000\.gemini\antigravity\conversations",
    "C:\Users\ms000\.gemini\tmp"
)

$today = [DateTime]::Today
$tokenRegex = '(?i)(?:totalTokens|totalTokenCount|total_tokens|token_count)\\*["'']?\s*:\s*(\d+)'

$totalTokensToday = 0

foreach ($p in $paths) {
    if (Test-Path $p) {
        $files = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $_.LastWriteTime -ge $today -and ($_.Extension -eq ".jsonl" -or $_.Extension -eq ".json" -or $_.Extension -eq ".db")
        }
        
        foreach ($file in $files) {
            if ($file.FullName -match '(?i)transcript_full|_full\.jsonl') { continue }
            
            if ($file.Extension -eq ".db") {
                $sizeKb = [int]($file.Length / 1024)
                # SQLite DB token estimation: ~12 tokens per KB
                $dbTokens = $sizeKb * 12
                Write-Host "DB File: $($file.Name) ($sizeKb KB) -> Estimated Tokens: $dbTokens"
                $totalTokensToday += $dbTokens
            } else {
                $content = [System.IO.File]::ReadAllText($file.FullName)
                $maxInFile = 0
                $matches = [regex]::Matches($content, $tokenRegex)
                foreach ($m in $matches) {
                    $val = [long]$m.Groups[1].Value
                    if ($val -gt $maxInFile -and $val -lt 2000000 -and $val -ne 1000000 -and $val -ne 5000000) {
                        $maxInFile = $val
                    }
                }
                if ($maxInFile -gt 0) {
                    Write-Host "JSON File: $($file.Name) -> Tokens: $maxInFile"
                    $totalTokensToday += $maxInFile
                }
            }
        }
    }
}

Write-Host "=========================================="
Write-Host "Total Extracted Tokens Today: $totalTokensToday"
