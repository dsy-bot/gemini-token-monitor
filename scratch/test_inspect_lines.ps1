$file = "C:\Users\ms000\.gemini\antigravity\brain\e41fee41-57f3-4b04-bc9c-3a390fdab6d8\.system_generated\logs\transcript.jsonl"
$lines = Get-Content $file -Tail 15

Write-Host "Tail 15 lines of $file :"
foreach ($line in $lines) {
    if ($line.Length -gt 200) {
        Write-Host ($line.Substring(0, 200) + "...")
    } else {
        Write-Host $line
    }
}
