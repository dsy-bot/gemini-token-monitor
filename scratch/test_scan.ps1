$today = [DateTime]::Today
$brainPath = "C:\Users\ms000\.gemini\antigravity\brain"

$files = [System.IO.Directory]::EnumerateFiles($brainPath, "*.jsonl", [System.IO.SearchOption]::AllDirectories)
$totalTokensToday = 0
$fileCount = 0

foreach ($f in $files) {
    if ($f -match '(?i)transcript_full|_full\.jsonl') { continue }
    $lastWrite = [System.IO.File]::GetLastWriteTime($f)
    if ($lastWrite -ge $today) {
        $content = [System.IO.File]::ReadAllText($f)
        $maxInFile = 0
        $matches = [regex]::Matches($content, '(?i)(?:totalTokens|totalTokenCount|total_tokens|token_count)\\*["'']?\s*:\s*(\d+)')
        foreach ($m in $matches) {
            $val = [long]$m.Groups[1].Value
            if ($val -gt $maxInFile -and $val -lt 2000000) {
                $maxInFile = $val
            }
        }
        if ($maxInFile -gt 0) {
            $totalTokensToday += $maxInFile
            $fileCount++
            Write-Host "File: $(Split-Path -Leaf $f) -> Tokens: $maxInFile"
        }
    }
}

Write-Host "Total Files Today: $fileCount"
Write-Host "Total Tokens Today: $totalTokensToday"
