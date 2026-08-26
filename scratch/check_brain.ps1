$brainDir = Join-Path $env:USERPROFILE ".gemini\antigravity\brain"
$dirs = Get-ChildItem $brainDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 5
foreach ($d in $dirs) {
    Write-Host "=== $($d.Name) ==="
    Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 8 | ForEach-Object {
        Write-Host "  $($_.Name)"
    }
}
