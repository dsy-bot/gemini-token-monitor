# 증분 스캔 로직 검증: conversations/*.db → 대응 transcript.jsonl에서 토큰 추출
$brainDir = "C:\Users\ms000\.gemini\antigravity\brain"
$convDir  = "C:\Users\ms000\.gemini\antigravity\conversations"
$tokenRegex = [regex]'(?i)(?:totalTokens|totalTokenCount|total_tokens|token_count)\\*["'']?\s*:\s*(\d+)'
$today = [DateTime]::Today

Write-Host "=== DB → transcript.jsonl 매핑 검증 ==="
$total = 0L
$dbFiles = Get-ChildItem $convDir -Filter *.db | Sort-Object LastWriteTime -Descending
foreach ($db in $dbFiles) {
    $convId = [System.IO.Path]::GetFileNameWithoutExtension($db.Name)
    $transcriptPath = "$brainDir\$convId\.system_generated\logs\transcript.jsonl"
    $exists = [System.IO.File]::Exists($transcriptPath)
    $maxTok = 0L
    $sizeKB = [int]($db.Length / 1024)
    if ($exists) {
        try {
            $content = [System.IO.File]::ReadAllText($transcriptPath)
            $ms = $tokenRegex.Matches($content)
            foreach ($m in $ms) {
                $v = [long]$m.Groups[1].Value
                if ($v -gt $maxTok -and $v -lt 5000000 -and $v -ne 1000000) { $maxTok = $v }
            }
        } catch {}
    }
    $isToday = $db.LastWriteTime -ge $today
    $flag = if ($isToday) {"[TODAY]"} else {""}
    Write-Host "$flag DB: $($db.Name.Substring(0,8))... SizeKB=$sizeKB | transcript.jsonl=$exists | MaxToken=$($maxTok.ToString('#,##0'))"
    if ($isToday -and $exists) { $total += $maxTok }
}
Write-Host ""
Write-Host "=== 오늘 토큰 합계 (transcript.jsonl 직접 파싱): $($total.ToString('#,##0')) ==="
Write-Host "비교 — config.json rolling5HourQuota: 1,375,304"
Write-Host "  => 5h 잔여 %: $([int][math]::Floor([math]::Max(0, 1375304 - $total) / 1375304 * 100))%"
