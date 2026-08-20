# transcript_full.jsonl에서 실제 토큰 필드 찾기
$fullPath = "C:\Users\ms000\.gemini\antigravity\brain\e41fee41-57f3-4b04-bc9c-3a390fdab6d8\.system_generated\logs\transcript_full.jsonl"
$tPath    = "C:\Users\ms000\.gemini\antigravity\brain\e41fee41-57f3-4b04-bc9c-3a390fdab6d8\.system_generated\logs\transcript.jsonl"

Write-Host "=== transcript.jsonl 크기: $([int]((Get-Item $tPath).Length/1024)) KB ==="
Write-Host "=== transcript_full.jsonl 크기: $([int]((Get-Item $fullPath).Length/1024)) KB ==="
Write-Host ""

# transcript_full에서 마지막 줄(최신 스텝)만 읽어 구조 파악
$lastLine = Get-Content $fullPath -Tail 1
if ($lastLine.Length -gt 500) { $lastLine = $lastLine.Substring(0, 500) }
Write-Host "transcript_full 마지막 줄 (첫 500자):"
Write-Host $lastLine
Write-Host ""

# totalTokens 검색
$fs2 = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$fullSize = $fs2.Length
# 마지막 100KB만 읽기
$readSize = [int][math]::Min($fullSize, 100KB)
$null = $fs2.Seek($fullSize - $readSize, [System.IO.SeekOrigin]::Begin)
$buf = New-Object byte[] $readSize
$null = $fs2.Read($buf, 0, $readSize)
$fs2.Close()
$chunk = [System.Text.Encoding]::UTF8.GetString($buf)

$tokenRx = [regex]::Matches($chunk, '(?i)"(?:totalTokens|totalTokenCount|total_tokens|token_count|inputTokens|outputTokens|promptTokenCount|candidatesTokenCount|cachedContentTokenCount)"\s*:\s*(\d+)')
Write-Host "token 관련 필드 검색 결과 (마지막 100KB):"
if ($tokenRx.Count -gt 0) {
    foreach ($m in ($tokenRx | Select-Object -Last 20)) {
        Write-Host "  $($m.Value)"
    }
} else {
    Write-Host "  없음"
}

# 어떤 키들이 있는지 더 넓게
Write-Host ""
Write-Host "--- usage 관련 JSON 키 ---"
$usageRx = [regex]::Matches($chunk, '"[^"]{0,20}(?:usage|token|count|cost)[^"]{0,20}"\s*:')
$ukeys = $usageRx | ForEach-Object { $_.Value } | Select-Object -Unique
foreach ($k in $ukeys) { Write-Host "  $k" }
