$paths = @(
    "C:\Users\ms000\.gemini\antigravity\brain"
)

$today = [DateTime]::Today
$tokenRegex = '(?i)(?:totalTokens|totalTokenCount|total_tokens|token_count)\\*["'']?\s*:\s*(\d+)'

$files = Get-ChildItem -Path "C:\Users\ms000\.gemini\antigravity\brain" -Recurse -File -Include *.jsonl | Where-Object {
    $_.FullName -notmatch 'transcript_full' -and $_.LastWriteTime -ge $today
}

Write-Host "Found $($files.Count) active jsonl log files today:"
$totalRealtimeTokens = 0
foreach ($f in $files) {
    $content = [System.IO.File]::ReadAllText($f.FullName)
    $maxInFile = 0
    $matches = [regex]::Matches($content, $tokenRegex)
    foreach ($m in $matches) {
        $val = [long]$m.Groups[1].Value
        if ($val -gt $maxInFile -and $val -lt 2000000 -and $val -ne 1000000 -and $val -ne 5000000) {
            $maxInFile = $val
        }
    }
    Write-Host "File: $($f.Name) | LastWrite: $($f.LastWriteTime.ToString('HH:mm:ss')) | Max Token: $maxInFile | Matches Count: $($matches.Count)"
    $totalRealtimeTokens += $maxInFile
}

Write-Host "Total Realtime Extracted Tokens: $totalRealtimeTokens"
