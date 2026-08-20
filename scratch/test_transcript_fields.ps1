# transcript.jsonl 내 실제 토큰 관련 필드가 무엇인지 직접 확인
$files = @(
    "C:\Users\ms000\.gemini\antigravity\brain\e41fee41-57f3-4b04-bc9c-3a390fdab6d8\.system_generated\logs\transcript.jsonl",
    "C:\Users\ms000\.gemini\antigravity\brain\d5b838c2-274c-482d-b742-77926677bb2d\.system_generated\logs\transcript.jsonl"
)

$patterns = @(
    'token',
    'usage',
    'cost',
    'count'
)

foreach ($f in $files) {
    if (-not [System.IO.File]::Exists($f)) { Write-Host "NOT FOUND: $f"; continue }
    $info = New-Object System.IO.FileInfo($f)
    Write-Host "=== $([System.IO.Path]::GetDirectoryName($f).Split('\')[-4]) ($([int]($info.Length/1024)) KB) ==="
    
    # 마지막 3줄만 읽어서 구조 파악
    $lines = Get-Content $f -Tail 3
    foreach ($line in $lines) {
        if ($line.Length -gt 300) { Write-Host $line.Substring(0, 300) } else { Write-Host $line }
    }
    
    # 토큰 관련 키워드 검색
    $content = [System.IO.File]::ReadAllText($f)
    Write-Host "--- 토큰 관련 키워드 검색 ---"
    foreach ($pat in $patterns) {
        $rx = [regex]::Matches($content, "(?i)""[^""]*$pat[^""]*""\s*:")
        if ($rx.Count -gt 0) {
            $unique = $rx | ForEach-Object { $_.Value } | Select-Object -Unique | Select-Object -First 5
            Write-Host "  [$pat]: $($unique -join ', ')"
        }
    }
    Write-Host ""
}
