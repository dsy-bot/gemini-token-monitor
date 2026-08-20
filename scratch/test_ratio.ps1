# 날짜별 DB 크기와 daily_usage.json 토큰 비율 측정
$convDir = "C:\Users\ms000\.gemini\antigravity\conversations"
$histPath = "C:\Users\ms000\.gemini\antigravity\scratch\gemini-token-monitor\daily_usage.json"
$hist = [System.IO.File]::ReadAllText($histPath) | ConvertFrom-Json

$dbFiles = Get-ChildItem $convDir -Filter *.db
Write-Host "=== 날짜별 DB 크기 합산 vs daily_usage.json 토큰 ==="

$dateGroups = @{}
foreach ($db in $dbFiles) {
    $dateKey = $db.LastWriteTime.ToString("yyyy-MM-dd")
    if (-not $dateGroups.ContainsKey($dateKey)) { $dateGroups[$dateKey] = 0L }
    $dateGroups[$dateKey] += [long]($db.Length / 1024)
}

foreach ($d in ($dateGroups.Keys | Sort-Object)) {
    $totalKB = $dateGroups[$d]
    $savedTok = 0L
    if ($hist.PSObject.Properties[$d]) {
        $savedTok = [long]$hist.PSObject.Properties[$d].Value.Tokens
    }
    $ratio = if ($totalKB -gt 0 -and $savedTok -gt 0) { [math]::Round($savedTok / $totalKB, 1) } else { "N/A" }
    Write-Host "$d : DB=$totalKB KB | Tokens=$($savedTok.ToString('#,##0')) | ratio=$ratio tok/KB"
}
