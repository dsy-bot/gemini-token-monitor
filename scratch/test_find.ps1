$paths = @(
    "C:\Users\ms000\.gemini",
    "C:\Users\ms000\AppData\Roaming\gemini",
    "C:\Users\ms000\AppData\Local\gemini"
)

$today = [DateTime]::Today
foreach ($p in $paths) {
    if (Test-Path $p) {
        Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $_.LastWriteTime -ge $today -and ($_.Extension -eq ".jsonl" -or $_.Extension -eq ".json" -or $_.Extension -eq ".db")
        } | ForEach-Object {
            Write-Host "$($_.FullName) | Time: $($_.LastWriteTime) | Size: $($_.Length)"
        }
    }
}
