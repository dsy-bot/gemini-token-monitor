# transcript.jsonl 파일이 실제 존재하는 대화의 구조 확인
$brainDir = Join-Path $env:USERPROFILE ".gemini\antigravity\brain"

# 유효한 transcript 찾기
$validT = $null
foreach ($d in (Get-ChildItem $brainDir -Directory -ErrorAction SilentlyContinue)) {
    $t = Join-Path $d.FullName ".system_generated\logs\transcript.jsonl"
    if (Test-Path $t) { $validT = $t; Write-Host "Found: $t"; break }
    $t2 = Join-Path $d.FullName "transcript.jsonl"
    if (Test-Path $t2) { $validT = $t2; Write-Host "Found: $t2"; break }
}

if ($validT) {
    $line1 = Get-Content $validT -TotalCount 1 -Encoding UTF8
    $obj = $line1 | ConvertFrom-Json -ErrorAction SilentlyContinue
    Write-Host "Top-level fields: $($obj.PSObject.Properties.Name -join ', ')"
}

# 모든 대화에서 model 키 grep
Write-Host ""
Write-Host "=== model 키워드 검색 ==="
foreach ($d in (Get-ChildItem $brainDir -Directory -ErrorAction SilentlyContinue)) {
    foreach ($pattern in @("transcript.jsonl", ".system_generated\logs\transcript.jsonl")) {
        $t = Join-Path $d.FullName $pattern
        if (-not (Test-Path $t)) { continue }
        try {
            $hit = Select-String -Path $t -Pattern '"model"' -SimpleMatch | Select-Object -First 1
            if ($hit) {
                Write-Host "$($d.Name): $($hit.Line.Substring(0, [math]::Min(200, $hit.Line.Length)))"
                break
            }
        } catch {}
    }
}
