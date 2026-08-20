# transcript.jsonl에서 totalTokens 패턴이 나오는 라인 찾기
$path = "C:\Users\ms000\.gemini\antigravity\brain\e41fee41-57f3-4b04-bc9c-3a390fdab6d8\.system_generated\logs\transcript.jsonl"
$lines = [System.IO.File]::ReadAllLines($path)
$rx = [regex]'(?i)totalTokens|totalTokenCount|token_count'
$found = $lines | Where-Object { $rx.IsMatch($_) }
Write-Host "총 매칭 라인 수: $($found.Count)"
foreach ($l in ($found | Select-Object -First 3)) {
    $json = $l | ConvertFrom-Json
    Write-Host "step=$($json.step_index) type=$($json.type)"
    # content에서 totalTokens 주변 100자
    $content = "$($json.content)$($json.tool_calls)"
    $idx = $content.ToLower().IndexOf("totaltoken")
    if ($idx -ge 0) {
        $from = [math]::Max(0, $idx - 20)
        $len  = [math]::Min(200, $content.Length - $from)
        Write-Host "  snippet: $($content.Substring($from, $len))"
    }
}
