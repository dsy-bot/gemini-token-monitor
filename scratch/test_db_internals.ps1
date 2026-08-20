# DB 파일 내부 구조 확인 — 다른 DB로 (닫혀있는 오래된 것으로)
$dbPath = "C:\Users\ms000\.gemini\antigravity\conversations\d6150033-1c26-4740-89fe-98fc673a30e6.db"

# 공유 읽기 허용으로 열기
$fs = [System.IO.File]::Open($dbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$size = $fs.Length
Write-Host "DB 파일 크기: $([int]($size/1024)) KB"

# 처음 16바이트 헤더
$hdr = New-Object byte[] 16
$null = $fs.Read($hdr, 0, 16)
Write-Host "Header: '$([System.Text.Encoding]::ASCII.GetString($hdr, 0, 15))'"

# 처음 8KB 읽어서 텍스트 필드 탐색
$null = $fs.Seek(0, [System.IO.SeekOrigin]::Begin)
$bufSize = [int][math]::Min($size, 64KB)
$buf = New-Object byte[] $bufSize
$null = $fs.Read($buf, 0, $bufSize)
$fs.Close()

$text = [System.Text.Encoding]::UTF8.GetString($buf)

# 필드명 추출
$fieldRx = [regex]::Matches($text, '(?i)\b(?:[a-z_]{2,20}[Tt]oken[a-z_]{0,10}|[a-z_]{2,20}[Uu]sage[a-z_]{0,10}|[a-z_]{2,20}[Cc]ount[a-z_]{0,10})\b')
$fields = $fieldRx | ForEach-Object { $_.Value } | Where-Object { $_ -match '^[a-zA-Z_]+$' } | Select-Object -Unique
Write-Host "관련 필드명: $($fields -join ', ')"

# JSON 스니펫 찾기
$jsonRx = [regex]::Matches($text, '\{[^}]{10,200}\}')
$jsonSamples = $jsonRx | Select-Object -First 5
Write-Host "JSON 샘플들:"
foreach ($j in $jsonSamples) {
    Write-Host "  $($j.Value.Substring(0, [math]::Min(150, $j.Value.Length)))"
}
