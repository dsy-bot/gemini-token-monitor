# ==============================================================================
# Gemini Token Monitor v2.2
# 목표: 정확한 토큰 추적 / 백그라운드 동작 / 최소 메모리
# 변경: 일일 로그 파일 기반 아키텍처, 기능 A/B 분리, AutoSize 적용
# ==============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ([System.Management.Automation.PSTypeName]'NativeMethods').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NativeMethods {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@
}

$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigDir      = Join-Path $ScriptDir "config"
$ConfigFile     = Join-Path $ConfigDir "config.json"
$StateCacheFile = Join-Path $ConfigDir "state_cache.json"
$LogsDir        = Join-Path $ScriptDir "logs"
$TokenLogsDir   = Join-Path $LogsDir "token"
$SystemLogsDir  = Join-Path $LogsDir "system"

if (-not (Test-Path $ConfigDir))     { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
if (-not (Test-Path $TokenLogsDir))  { New-Item -ItemType Directory -Path $TokenLogsDir | Out-Null }
if (-not (Test-Path $SystemLogsDir)) { New-Item -ItemType Directory -Path $SystemLogsDir | Out-Null }

# ==============================================================================
# 로깅 (일일 시스템 진단 로그)
# ==============================================================================
function Write-Log {
    param([string]$Message)
    try {
        $now = Get-Date
        $ts = $now.ToString("yyyy-MM-dd HH:mm:ss")
        $dailySystemLog = Join-Path $SystemLogsDir "system_$($now.ToString('yyyy-MM-dd')).log"
        "[$ts] $Message" | Out-File -FilePath $dailySystemLog -Append -Encoding UTF8
    } catch {}
}

# ==============================================================================
# state_cache.json 읽기/쓰기
# ==============================================================================
function Read-StateCache {
    try {
        if (Test-Path $StateCacheFile) {
            return (Get-Content $StateCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    } catch {}
    return [pscustomobject]@{ weeklyFirstUseTime = $null; weeklyExpiryTime = $null; fileOffsets = [ordered]@{} }
}

Write-Log "Gemini Token Monitor v2.2 시작"

try {
    # ==========================================================================
    # 1. 설정 로드
    # ==========================================================================
    $Global:Config = [hashtable]::Synchronized(@{
        rolling5HourQuotaTokens = 1375304
        weeklyQuotaTokens       = 42565486
        tokensPerKB             = 12
        checkIntervalSeconds    = 60
        ScriptDir               = $ScriptDir
        ConfigDir               = $ConfigDir
        ConfigFile              = $ConfigFile
        StateCacheFile          = $StateCacheFile
        LogsDir                 = $LogsDir
        TokenLogsDir            = $TokenLogsDir
        SystemLogsDir           = $SystemLogsDir
    })

    if (Test-Path $ConfigFile) {
        try {
            $json = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @('rolling5HourQuotaTokens','weeklyQuotaTokens','tokensPerKB','checkIntervalSeconds')) {
                if ($null -ne $json.$key) { $Global:Config[$key] = $json.$key }
            }
            if ($json.PSObject.Properties['checkIntervalMinutes'] -and $json.checkIntervalMinutes -gt 0 -and
                -not ($json.PSObject.Properties['checkIntervalSeconds'])) {
                $Global:Config.checkIntervalSeconds = [int]$json.checkIntervalMinutes * 60
            }
        } catch {}
    }

    # ==========================================================================
    # 2. 글로벌 상태
    # ==========================================================================
    $Global:State = [hashtable]::Synchronized(@{
        LastCheckTime           = [DateTime]::MinValue
        TokensUsedToday         = 0L
        TokensUsed5Hours        = 0L
        TokensThisWeek          = 0L
        Remaining5HourPercent   = 100
        RemainingWeeklyPercent  = 100
        RiskLevel               = "GREEN"
        TimeUntilWeeklyResetStr = "계산 중..."
        TimeUntil5HourResetStr  = "계산 중..."
        Short5HourRemTimeStr    = "계산 중..."
        WeeklyFirstUseTime      = [DateTime]::MinValue
        WeeklyExpiryTime        = [DateTime]::MinValue
        FirstTokenTimeToday     = [DateTime]::MinValue
        LastHIcon               = [IntPtr]::Zero
        IsScanning              = $false
        FileOffsetCache         = [hashtable]::Synchronized(@{})
    })

    $sc = Read-StateCache
    if ($sc.weeklyFirstUseTime -ne $null -and "$($sc.weeklyFirstUseTime)" -ne "") {
        try {
            $wft = [DateTime]::Parse($sc.weeklyFirstUseTime)
            if (([DateTime]::Now - $wft).TotalDays -le 7) { $Global:State.WeeklyFirstUseTime = $wft }
        } catch {}
    }
    if ($sc.weeklyExpiryTime -ne $null -and "$($sc.weeklyExpiryTime)" -ne "") {
        try {
            $wet = [DateTime]::Parse($sc.weeklyExpiryTime)
            if ($wet -gt [DateTime]::Now) { $Global:State.WeeklyExpiryTime = $wet }
        } catch {}
    }
    if ($null -ne $sc.PSObject.Properties['fileOffsets'] -and $null -ne $sc.fileOffsets) {
        try {
            foreach ($prop in $sc.fileOffsets.PSObject.Properties) {
                $Global:State.FileOffsetCache[$prop.Name] = [long]$prop.Value
            }
        } catch {}
    }

    # ==========================================================================
    # 배지 아이콘 생성 함수 (생략 없이 유지)
    # ==========================================================================
    function New-BatteryIcon {
        param([int]$Percent = 100, [string]$RiskLevel = "GREEN")
        try {
            $bmp = New-Object System.Drawing.Bitmap(32, 32)
            $g   = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
            $g.Clear([System.Drawing.Color]::Transparent)
            switch ($RiskLevel) {
                "RED"    { $bg = [System.Drawing.Color]::FromArgb(231, 76, 60);  $bd = [System.Drawing.Color]::FromArgb(192, 57, 43); $tc = [System.Drawing.Color]::White }
                "YELLOW" { $bg = [System.Drawing.Color]::FromArgb(241, 196, 15); $bd = [System.Drawing.Color]::FromArgb(211, 84,  0); $tc = [System.Drawing.Color]::Black }
                default  { $bg = [System.Drawing.Color]::FromArgb(46, 204, 113); $bd = [System.Drawing.Color]::FromArgb(39, 174, 96); $tc = [System.Drawing.Color]::White }
            }
            $pen  = New-Object System.Drawing.Pen($bd, 2)
            $fill = New-Object System.Drawing.SolidBrush($bg)
            $g.FillRectangle($fill, 1, 2, 30, 28); $g.DrawRectangle($pen, 1, 2, 30, 28)
            $font   = New-Object System.Drawing.Font("Arial", 9.5, [System.Drawing.FontStyle]::Bold)
            $tBrush = New-Object System.Drawing.SolidBrush($tc)
            $sBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
            $txt  = "$Percent"; $sz = $g.MeasureString($txt, $font)
            $px = [int]((32 - $sz.Width) / 2); $py = [int]((32 - $sz.Height) / 2)
            if ($RiskLevel -ne "YELLOW") { $g.DrawString($txt, $font, $sBrush, ($px+1), ($py+1)) }
            $g.DrawString($txt, $font, $tBrush, $px, $py)
            
            $hIcon = $bmp.GetHicon()
            $tempIcon = [System.Drawing.Icon]::FromHandle($hIcon)
            $icon = $tempIcon.Clone()
            $tempIcon.Dispose()
            [NativeMethods]::DestroyIcon($hIcon) | Out-Null
            
            foreach ($obj in @($g, $bmp, $pen, $fill, $tBrush, $sBrush, $font)) { $obj.Dispose() }
            return $icon
        } catch { return [System.Drawing.SystemIcons]::Application }
    }

    function Refresh-UIElements {
        if (-not $script:NotifyIcon) { return }
        $pct  = [int]$Global:State.Remaining5HourPercent
        $risk = $Global:State.RiskLevel
        $script:NotifyIcon.Icon = New-BatteryIcon -Percent $pct -RiskLevel $risk
        $tip = "Gemini 5h $pct%($($Global:State.Short5HourRemTimeStr)) | 주간 $($Global:State.RemainingWeeklyPercent)%"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:NotifyIcon.Text = $tip
    }

    # ==========================================================================
    # 백그라운드 런스페이스 스캔
    # ==========================================================================
    function Start-BackgroundScanRunspace {
        if ($Global:State.IsScanning) { return }
        $Global:State.IsScanning = $true

        $script:ScanRunspace = [runspacefactory]::CreateRunspace(); $script:ScanRunspace.Open()
        $script:ScanRunspace.SessionStateProxy.SetVariable("SyncState",  $Global:State)
        $script:ScanRunspace.SessionStateProxy.SetVariable("SyncConfig", $Global:Config)
        $script:ScanPS = [powershell]::Create(); $script:ScanPS.Runspace = $script:ScanRunspace

        $scanBlock = {
            try {
                $now     = [DateTime]::Now
                $today   = [DateTime]::Today
                $start5h = $now.AddHours(-5)

                $convDir  = [System.IO.Path]::Combine($env:USERPROFILE, ".gemini", "antigravity", "conversations")
                $tokPerKB = if ($SyncConfig.ContainsKey('tokensPerKB') -and $SyncConfig.tokensPerKB -gt 0) { [long]$SyncConfig.tokensPerKB } else { 12L }
                
                $cycleDelta = 0L
                $cycleDeltaKB = 0L
                $totalCurrentKB = 0L

                # 1. 파일 크기 변경 감지
                if ([System.IO.Directory]::Exists($convDir)) {
                    foreach ($dbPath in [System.IO.Directory]::EnumerateFiles($convDir, "*.db")) {
                        try {
                            $dbInfo = New-Object System.IO.FileInfo($dbPath)
                            $curSizeKB = [long]($dbInfo.Length / 1024)
                            $totalCurrentKB += $curSizeKB
                            $prevSizeKB = 0L
                            $isNewFile = $true

                            if ($SyncState.FileOffsetCache.ContainsKey($dbPath)) {
                                $prevSizeKB = $SyncState.FileOffsetCache[$dbPath]
                                $isNewFile = $false
                            }
                            
                            if ($isNewFile) {
                                $SyncState.FileOffsetCache[$dbPath] = $curSizeKB
                            } elseif ($curSizeKB -gt $prevSizeKB) {
                                $deltaKB = $curSizeKB - $prevSizeKB
                                $cycleDeltaKB += $deltaKB
                                $cycleDelta += ($deltaKB * $tokPerKB)
                                $SyncState.FileOffsetCache[$dbPath] = $curSizeKB
                            }
                        } catch {}
                    }
                }

                # 2. 증분 CSV 로그 기록
                $csvHeader = "Timestamp,Type,DeltaTokens,DeltaKB,TotalDB_KB,UserPercent,TokensPerKB,Rem5hPct,RemWkPct,Note"
                $csvFile = [System.IO.Path]::Combine($SyncConfig.TokenLogsDir, "usage_$($now.ToString('yyyy-MM-dd')).csv")
                
                if (-not [System.IO.File]::Exists($csvFile)) {
                    try { [System.IO.File]::WriteAllLines($csvFile, @($csvHeader), [System.Text.Encoding]::UTF8) } catch {}
                }

                if ($cycleDelta -gt 0) {
                    $csvRow = "$($now.ToString('HH:mm:ss')),SCAN,$cycleDelta,$cycleDeltaKB,$totalCurrentKB,,$tokPerKB,,,"
                    try { [System.IO.File]::AppendAllLines($csvFile, @($csvRow), [System.Text.Encoding]::UTF8) } catch {}
                }

                # 3. CSV 로그 통합 정산
                $wft = $SyncState.WeeklyFirstUseTime
                if ($wft -eq [DateTime]::MinValue) { $wft = $today.AddDays(-7) }
                
                $tokensToday = 0L
                $tokens5h = 0L
                $tokensThisWeek = 0L
                $firstActivityToday = [DateTime]::MaxValue

                if ([System.IO.Directory]::Exists($SyncConfig.TokenLogsDir)) {
                    # CSV 파일 집계
                    foreach ($file in [System.IO.Directory]::EnumerateFiles($SyncConfig.TokenLogsDir, "usage_*.csv")) {
                        try {
                            $dateStr = [System.IO.Path]::GetFileNameWithoutExtension($file).Substring(6)
                            $fileDate = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
                            
                            if ($fileDate -ge $wft.Date -and $fileDate -le $today) {
                                foreach ($line in [System.IO.File]::ReadLines($file)) {
                                    if ($line.Trim() -eq "" -or $line.StartsWith("Timestamp")) { continue }
                                    $cols = $line.Split(',')
                                    if ($cols.Length -ge 3) {
                                        $v = [long]$cols[2]
                                        $entryTime = $fileDate.Date.Add([TimeSpan]::Parse($cols[0]))
                                        
                                        $tokensThisWeek += $v
                                        if ($fileDate -eq $today) {
                                            $tokensToday += $v
                                            if ($entryTime -lt $firstActivityToday) { $firstActivityToday = $entryTime }
                                        }
                                        if ($entryTime -ge $start5h) { $tokens5h += $v }
                                    }
                                }
                            }
                        } catch {}
                    }
                    # 기존 JSONL 파일 호환 (있을 경우)
                    foreach ($file in [System.IO.Directory]::EnumerateFiles($SyncConfig.TokenLogsDir, "usage_*.jsonl")) {
                        try {
                            $dateStr = [System.IO.Path]::GetFileNameWithoutExtension($file).Substring(6)
                            $csvEquivalent = [System.IO.Path]::Combine($SyncConfig.TokenLogsDir, "usage_$dateStr.csv")
                            if ([System.IO.File]::Exists($csvEquivalent)) { continue } # CSV가 이미 있으면 스킵
                            
                            $fileDate = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
                            if ($fileDate -ge $wft.Date -and $fileDate -le $today) {
                                foreach ($line in [System.IO.File]::ReadLines($file)) {
                                    if ($line.Trim() -eq "") { continue }
                                    $entry = $line | ConvertFrom-Json
                                    $v = [long]$entry.v
                                    $entryTime = $fileDate.Date.Add([TimeSpan]::Parse($entry.t))
                                    
                                    $tokensThisWeek += $v
                                    if ($fileDate -eq $today) {
                                        $tokensToday += $v
                                        if ($entryTime -lt $firstActivityToday) { $firstActivityToday = $entryTime }
                                    }
                                    if ($entryTime -ge $start5h) { $tokens5h += $v }
                                }
                            }
                        } catch {}
                    }
                }

                # 주간 첫사용 기록 업데이트
                if ($SyncState.WeeklyFirstUseTime -eq [DateTime]::MinValue -and $tokensThisWeek -gt 0) {
                    $SyncState.WeeklyFirstUseTime = $now
                    try {
                        $sc2 = if ([System.IO.File]::Exists($SyncConfig.StateCacheFile)) {
                            [System.IO.File]::ReadAllText($SyncConfig.StateCacheFile) | ConvertFrom-Json
                        } else { [pscustomobject]@{} }
                        $sc2 | Add-Member -MemberType NoteProperty -Name "weeklyFirstUseTime" -Value $now.ToString("yyyy-MM-ddTHH:mm:ss") -Force
                        [System.IO.File]::WriteAllText($SyncConfig.StateCacheFile, ($sc2 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                    } catch {}
                }

                # 퍼센트 계산
                $max5h = [long]$SyncConfig.rolling5HourQuotaTokens
                $rem5h = [math]::Max(0L, $max5h - $tokens5h)
                $p5h   = [int][math]::Floor($rem5h / $max5h * 100)
                if ($tokens5h -gt 0 -and $p5h -ge 100) { $p5h = 99 }

                $maxWk = [long]$SyncConfig.weeklyQuotaTokens
                $remWk = [math]::Max(0L, $maxWk - $tokensThisWeek)
                $pWk   = [int][math]::Floor($remWk / $maxWk * 100)
                if ($tokensThisWeek -gt 0 -and $pWk -ge 100) { $pWk = 99 }

                # 5h 카운트다운
                if ($firstActivityToday -lt [DateTime]::MaxValue) {
                    $expiry5h = $firstActivityToday.AddHours(5)
                    if ($now -ge $expiry5h) {
                        $SyncState.TimeUntil5HourResetStr = "복구 완료"
                        $SyncState.Short5HourRemTimeStr   = "복구완료"
                    } else {
                        $span5h = $expiry5h - $now
                        $SyncState.TimeUntil5HourResetStr = $firstActivityToday.ToString("HH:mm") + " 첫 사용 -> " + $expiry5h.ToString("HH:mm") + " 복구 (" + $span5h.Hours + "h " + $span5h.Minutes + "m 남음)"
                        $SyncState.Short5HourRemTimeStr   = $span5h.Hours.ToString() + "h " + $span5h.Minutes.ToString() + "m 남음"
                    }
                } else {
                    $SyncState.TimeUntil5HourResetStr = "오늘 사용 기록 없음"
                    $SyncState.Short5HourRemTimeStr   = "대기 중"
                }

                # 주간 카운트다운
                $wet = $SyncState.WeeklyExpiryTime
                if ($wet -gt [DateTime]::MinValue) {
                    if ($now -ge $wet) {
                        $SyncState.WeeklyExpiryTime = [DateTime]::MinValue
                        $SyncState.WeeklyFirstUseTime = [DateTime]::MinValue
                        $SyncState.TimeUntilWeeklyResetStr = "주간 초기화 완료"
                        try {
                            $sc2 = if ([System.IO.File]::Exists($SyncConfig.StateCacheFile)) {
                                [System.IO.File]::ReadAllText($SyncConfig.StateCacheFile) | ConvertFrom-Json
                            } else { [pscustomobject]@{} }
                            $sc2 | Add-Member -MemberType NoteProperty -Name "weeklyExpiryTime"   -Value $null -Force
                            $sc2 | Add-Member -MemberType NoteProperty -Name "weeklyFirstUseTime" -Value $null -Force
                            [System.IO.File]::WriteAllText($SyncConfig.StateCacheFile, ($sc2 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                        } catch {}
                    } else {
                        $wspan = $wet - $now
                        $dStr  = if ($wspan.Days -gt 0) { $wspan.Days.ToString() + "일 " } else { "" }
                        $SyncState.TimeUntilWeeklyResetStr = "[수동] " + $wet.ToString("MM/dd HH:mm") + " 초기화 (" + $dStr + $wspan.Hours + "h " + $wspan.Minutes + "m 남음)"
                    }
                } elseif ($SyncState.WeeklyFirstUseTime -gt [DateTime]::MinValue) {
                    $weekExpiry = $SyncState.WeeklyFirstUseTime.AddDays(7)
                    $wspan = $weekExpiry - $now
                    if ($wspan.TotalSeconds -le 0) {
                        $SyncState.TimeUntilWeeklyResetStr = "7일 경과 - 다음 사용 시 새 주간 시작"
                        $SyncState.WeeklyFirstUseTime = [DateTime]::MinValue
                    } else {
                        $dStr2 = if ($wspan.Days -gt 0) { $wspan.Days.ToString() + "일 " } else { "" }
                        $SyncState.TimeUntilWeeklyResetStr = $weekExpiry.ToString("MM/dd HH:mm") + " 복구 (" + $dStr2 + $wspan.Hours + "h " + $wspan.Minutes + "m 남음)"
                    }
                } else {
                    $SyncState.TimeUntilWeeklyResetStr = "주간 사용 기록 없음"
                }

                $risk = "GREEN"
                if ($p5h -le 10 -or $pWk -le 10) { $risk = "RED" }
                elseif ($p5h -le 25 -or $pWk -le 25) { $risk = "YELLOW" }

                $SyncState.TokensUsedToday        = $tokensToday
                $SyncState.TokensUsed5Hours       = $tokens5h
                $SyncState.Remaining5HourPercent  = $p5h
                $SyncState.RemainingWeeklyPercent = $pWk
                $SyncState.TokensThisWeek         = $tokensThisWeek
                $SyncState.RiskLevel              = $risk
                $SyncState.LastCheckTime          = $now

                # state_cache.json 저장
                try {
                    $sc3 = if ([System.IO.File]::Exists($SyncConfig.StateCacheFile)) {
                        [System.IO.File]::ReadAllText($SyncConfig.StateCacheFile) | ConvertFrom-Json
                    } else { [pscustomobject]@{} }
                    
                    $cloneOffsets = [ordered]@{}
                    foreach ($k in $SyncState.FileOffsetCache.Keys) { $cloneOffsets[$k] = $SyncState.FileOffsetCache[$k] }
                    
                    $sc3 | Add-Member -MemberType NoteProperty -Name "fileOffsets" -Value $cloneOffsets -Force
                    [System.IO.File]::WriteAllText($SyncConfig.StateCacheFile, ($sc3 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                } catch {}

            } catch {}
            $SyncState.IsScanning = $false
        }

        $script:ScanPS.AddScript($scanBlock) | Out-Null
        $script:ScanHandle = $script:ScanPS.BeginInvoke()

        if ($script:ScanPollTimer) {
            $script:ScanPollTimer.Stop()
            $script:ScanPollTimer.Dispose()
        }
        $script:ScanPollTimer = New-Object System.Windows.Forms.Timer
        $script:ScanPollTimer.Interval = 300
        $script:ScanPollTimer.Add_Tick({
            if ($script:ScanHandle -and $script:ScanHandle.IsCompleted) {
                $script:ScanPollTimer.Stop()
                try { $script:ScanPS.EndInvoke($script:ScanHandle) } catch {}
                if ($script:ScanPS) { $script:ScanPS.Dispose() }
                if ($script:ScanRunspace) { $script:ScanRunspace.Dispose() }
                $script:ScanHandle = $null
                Refresh-UIElements
            }
        })
        $script:ScanPollTimer.Start()
    }

    # ==========================================================================
    # 현황 창
    # ==========================================================================
    function Show-StatusDialog {
        Start-BackgroundScanRunspace

        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor v2.2 - 현황"
        $f.Size = New-Object System.Drawing.Size(620, 540)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true; $tb.ReadOnly = $true
        $tb.WordWrap = $false; $tb.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $tb.Font = New-Object System.Drawing.Font("Consolas", 10)
        $tb.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 40)
        $tb.ForeColor = [System.Drawing.Color]::FromArgb(220, 230, 240)
        $tb.Location = New-Object System.Drawing.Point(12, 12)
        $tb.Size = New-Object System.Drawing.Size(582, 460)

        function Build-StatusText {
            $st  = $Global:State; $cfg = $Global:Config
            $rem5hTok   = [math]::Max(0, $cfg.rolling5HourQuotaTokens - $st.TokensUsed5Hours)
            $weeklyUsed = [math]::Max(0L, $st.TokensThisWeek)
            $remWkTok   = [math]::Max(0, $cfg.weeklyQuotaTokens - $weeklyUsed)
            $wftStr     = if ($st.WeeklyFirstUseTime -gt [DateTime]::MinValue) { $st.WeeklyFirstUseTime.ToString("MM/dd HH:mm") } else { "기록없음" }
            
            $lines = @(
                "======================================================",
                "      Gemini Token Monitor  v2.2 - 실시간 현황",
                "======================================================",
                ("  갱신 시각  : " + $(if ($st.LastCheckTime -gt [DateTime]::MinValue) { $st.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "스캔 중..." })),
                "",
                "-- 쿼터 잔여 ----------------------------------------",
                ("  오늘 소모   : " + $st.TokensUsedToday.ToString("#,##0") + " tok"),
                ("  5h  잔여   : " + $st.Remaining5HourPercent + "%  (" + $rem5hTok.ToString("#,##0") + " / " + $cfg.rolling5HourQuotaTokens.ToString("#,##0") + " tok)"),
                ("  주간 잔여   : " + $st.RemainingWeeklyPercent + "%  (" + $remWkTok.ToString("#,##0") + " / " + $cfg.weeklyQuotaTokens.ToString("#,##0") + " tok)"),
                ("    이번주 소모: " + $weeklyUsed.ToString("#,##0") + " tok  | 주간 첫사용: " + $wftStr),
                "",
                "-- 리셋 카운트다운 ----------------------------------",
                ("  5h  복구   : " + $st.TimeUntil5HourResetStr),
                ("  주간 복구   : " + $st.TimeUntilWeeklyResetStr),
                "",
                "-- 위험도 -------------------------------------------",
                ("  상태       : " + $(switch ($st.RiskLevel) { "RED" {"[위험] 쿼터 소진 임박"} "YELLOW" {"[주의] 25% 미만 잔여"} default {"[정상] 안전"} })),
                "======================================================",
                ""
            )

            # 오늘 로그 표시 (최근 5건)
            try {
                $todayCsv = [System.IO.Path]::Combine($cfg.TokenLogsDir, "usage_$([DateTime]::Now.ToString('yyyy-MM-dd')).csv")
                if ([System.IO.File]::Exists($todayCsv)) {
                    $logLines = [System.IO.File]::ReadAllLines($todayCsv) | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("Timestamp") }
                    if ($logLines.Length -gt 0) {
                        $lines += "-- 최근 소모 로그 (오늘, 최대 5건) ----------------"
                        $startIdx = [math]::Max(0, $logLines.Length - 5)
                        for ($i = $logLines.Length - 1; $i -ge $startIdx; $i--) {
                            $cols = $logLines[$i].Split(',')
                            if ($cols.Length -ge 3) {
                                $t = $cols[0]
                                $type = $cols[1]
                                $v = [long]$cols[2]
                                $extra = if ($cols.Length -ge 10 -and $cols[9]) { " (" + $cols[9] + ")" } else { "" }
                                $lines += "  [$t] [$type]  $v tok $extra"
                            }
                        }
                    }
                }
            } catch {}

            $lines -join "`r`n"
        }

        $tb.Text = Build-StatusText
        $f.Controls.Add($tb)

        $btnR = New-Object System.Windows.Forms.Button
        $btnR.Text = "새로고침"; $btnR.Location = New-Object System.Drawing.Point(12, 482)
        $btnR.Size = New-Object System.Drawing.Size(110, 30); $btnR.FlatStyle = "Flat"
        $btnR.ForeColor = [System.Drawing.Color]::White; $btnR.BackColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
        $btnR.Add_Click({ $tb.Text = Build-StatusText }); $f.Controls.Add($btnR)

        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = "닫기"; $btnOK.Location = New-Object System.Drawing.Point(498, 482)
        $btnOK.Size = New-Object System.Drawing.Size(90, 30); $btnOK.FlatStyle = "Flat"
        $btnOK.ForeColor = [System.Drawing.Color]::White; $btnOK.BackColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
        $btnOK.Add_Click({ $f.Close() }); $f.Controls.Add($btnOK)

        $statusTimer = New-Object System.Windows.Forms.Timer
        $statusTimer.Interval = 1000
        $statusTimer.Add_Tick({
            if ($tb -and -not $tb.IsDisposed) {
                $tb.Text = Build-StatusText
            }
        })
        $f.Add_Shown({ $statusTimer.Start() })
        $f.Add_FormClosed({
            $statusTimer.Stop()
            $statusTimer.Dispose()
        })

        $f.ShowDialog()
    }

    # ==========================================================================
    # 설정 창
    # ==========================================================================
    function Show-SettingsDialog {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor - 설정"
        $f.AutoSize = $true
        $f.AutoSizeMode = "GrowAndShrink"
        $f.Padding = New-Object System.Windows.Forms.Padding(10)
        $f.StartPosition = "CenterScreen"; $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false; $f.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 40)
        
        $pnl = New-Object System.Windows.Forms.Panel
        $pnl.AutoSize = $true
        $pnl.Location = New-Object System.Drawing.Point(0,0)
        $f.Controls.Add($pnl)

        function Add-Label { param($panel,$text,$x,$y,[bool]$bold=$false)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $text; $l.ForeColor = [System.Drawing.Color]::White
            $l.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5, $(if ($bold) {[System.Drawing.FontStyle]::Bold} else {[System.Drawing.FontStyle]::Regular}))
            $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
            $panel.Controls.Add($l); return $l
        }
        function Add-SubLabel { param($panel,$text,$x,$y)
            $l = New-Object System.Windows.Forms.Label; $l.Text = $text
            $l.ForeColor = [System.Drawing.Color]::FromArgb(150,150,150)
            $l.Font = New-Object System.Drawing.Font("맑은 고딕", 8.5)
            $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true; $panel.Controls.Add($l)
        }
        function Add-Input { param($panel,$x,$y,$w,$val)
            $t = New-Object System.Windows.Forms.TextBox; $t.Text = "$val"
            $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 24)
            $panel.Controls.Add($t); return $t
        }

        Add-Label $pnl "쿼터 설정" 20 15 $true
        Add-Label $pnl "5시간 롤링 쿼터 (tokens):" 20 38
        $txt5hQ = Add-Input $pnl 20 56 490 $Global:Config.rolling5HourQuotaTokens

        Add-Label $pnl "주간 롤링 쿼터 (tokens):" 20 90
        $txtWkQ = Add-Input $pnl 20 108 490 $Global:Config.weeklyQuotaTokens

        Add-Label $pnl "─────────────────────────────────────────────────" 20 143
        Add-Label $pnl "[기능 A] 쿼터 전체량 역산 (모델 변경 시)" 20 160 $true
        Add-SubLabel $pnl "사용량 기록은 유지하고, 전체 한도(Quota)만 자동으로 다시 계산합니다." 20 178

        Add-Label $pnl "5h 잔여 % 입력:" 20 202
        $txt5hPct = Add-Input $pnl 170 200 80 ""
        $lblPct1 = New-Object System.Windows.Forms.Label
        $lblPct1.Text = "%"; $lblPct1.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
        $lblPct1.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblPct1.Location = New-Object System.Drawing.Point(258, 204); $lblPct1.AutoSize = $true; $pnl.Controls.Add($lblPct1)

        Add-Label $pnl "주간 잔여 % 입력:" 20 236
        $txtWkPct = Add-Input $pnl 170 234 80 ""
        $lblPct2 = New-Object System.Windows.Forms.Label
        $lblPct2.Text = "%"; $lblPct2.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
        $lblPct2.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblPct2.Location = New-Object System.Drawing.Point(258, 238); $lblPct2.AutoSize = $true; $pnl.Controls.Add($lblPct2)

        Add-Label $pnl "─────────────────────────────────────────────────" 20 270
        Add-Label $pnl "[기능 B] 사용량(%) 강제 동기화 (타 기기 사용 시)" 20 287 $true
        Add-SubLabel $pnl "쿼터 한도는 유지하고, 일일 로그 파일에 가상 차이값을 쑤셔넣어 잔여 %를 맞춥니다." 20 305

        Add-Label $pnl "5h 잔여 % 동기화:" 20 329
        $txt5hSyncPct = Add-Input $pnl 170 327 80 ""
        $lblPct3 = New-Object System.Windows.Forms.Label
        $lblPct3.Text = "%"; $lblPct3.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
        $lblPct3.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblPct3.Location = New-Object System.Drawing.Point(258, 331); $lblPct3.AutoSize = $true; $pnl.Controls.Add($lblPct3)

        Add-Label $pnl "주간 잔여 % 동기화:" 20 363
        $txtWkSyncPct = Add-Input $pnl 170 361 80 ""
        $lblPct4 = New-Object System.Windows.Forms.Label
        $lblPct4.Text = "%"; $lblPct4.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
        $lblPct4.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblPct4.Location = New-Object System.Drawing.Point(258, 365); $lblPct4.AutoSize = $true; $pnl.Controls.Add($lblPct4)

        Add-Label $pnl "─────────────────────────────────────────────────" 20 400
        Add-Label $pnl "⏱️ 주간 초기화 남은 분 (비워두면 롤링 7일):" 20 417
        $txtWkExpMin = Add-Input $pnl 20 435 150 $(
            if ($Global:State.WeeklyExpiryTime -gt [DateTime]::Now) {
                [int]($Global:State.WeeklyExpiryTime - [DateTime]::Now).TotalMinutes
            } else { "" }
        )
        $lblWkExpInfo = New-Object System.Windows.Forms.Label
        $lblWkExpInfo.ForeColor = [System.Drawing.Color]::FromArgb(100, 200, 255)
        $lblWkExpInfo.Font = New-Object System.Drawing.Font("맑은 고딕", 8.5)
        $lblWkExpInfo.Location = New-Object System.Drawing.Point(180, 439); $lblWkExpInfo.AutoSize = $true
        $lblWkExpInfo.Text = if ($Global:State.WeeklyExpiryTime -gt [DateTime]::Now) {
            "현재: " + $Global:State.WeeklyExpiryTime.ToString("MM/dd HH:mm") + " 초기화 예정"
        } else { "" }
        $pnl.Controls.Add($lblWkExpInfo)

        Add-Label $pnl "─────────────────────────────────────────────────" 20 470
        Add-Label $pnl "고급 설정" 20 485 $true

        Add-Label $pnl "갱신 주기 (초):" 20 510
        $txtInterval = Add-Input $pnl 20 528 200 $Global:Config.checkIntervalSeconds

        Add-Label $pnl "비율 (tok/KB, 기본 12):" 20 564
        $txtTokPerKB = Add-Input $pnl 20 582 200 $Global:Config.tokensPerKB

        $chkAutoTokPerKB = New-Object System.Windows.Forms.CheckBox
        $chkAutoTokPerKB.Text = "5h 보정 시 DB크기 대비 tok/KB 비율 자동 최적화"
        $chkAutoTokPerKB.ForeColor = [System.Drawing.Color]::FromArgb(100, 220, 255)
        $chkAutoTokPerKB.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $chkAutoTokPerKB.Location = New-Object System.Drawing.Point(20, 622); $chkAutoTokPerKB.AutoSize = $true
        $pnl.Controls.Add($chkAutoTokPerKB)

        $chkResetWeekly = New-Object System.Windows.Forms.CheckBox
        $chkResetWeekly.Text = "주간 첫사용 시각 + 수동 종료시각 초기화"
        $chkResetWeekly.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
        $chkResetWeekly.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $chkResetWeekly.Location = New-Object System.Drawing.Point(20, 646); $chkResetWeekly.AutoSize = $true
        $pnl.Controls.Add($chkResetWeekly)

        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text = "저장 및 갱신"
        $btnSave.Font = New-Object System.Drawing.Font("맑은 고딕", 10, [System.Drawing.FontStyle]::Bold)
        $btnSave.Location = New-Object System.Drawing.Point(340, 680)
        $btnSave.Size = New-Object System.Drawing.Size(160, 36)
        $btnSave.ForeColor = [System.Drawing.Color]::White
        $btnSave.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        $btnSave.FlatStyle = "Flat"
        $btnSave.Add_Click({
            try { $Global:Config.rolling5HourQuotaTokens = [long]$txt5hQ.Text.Trim() } catch {}
            try { $Global:Config.weeklyQuotaTokens       = [long]$txtWkQ.Text.Trim()  } catch {}
            try { $Global:Config.checkIntervalSeconds    = [int]$txtInterval.Text.Trim() } catch {}
            try { $Global:Config.tokensPerKB             = [int]$txtTokPerKB.Text.Trim() } catch {}

            $now = [DateTime]::Now
            $csvHeader = "Timestamp,Type,DeltaTokens,DeltaKB,TotalDB_KB,UserPercent,TokensPerKB,Rem5hPct,RemWkPct,Note"
            $todayCsv = [System.IO.Path]::Combine($Global:Config.TokenLogsDir, "usage_$($now.ToString('yyyy-MM-dd')).csv")
            if (-not [System.IO.File]::Exists($todayCsv)) {
                try { [System.IO.File]::WriteAllLines($todayCsv, @($csvHeader), [System.Text.Encoding]::UTF8) } catch {}
            }

            # 현재 전체 DB 용량 계산
            $totKB = 0L
            $convDir = [System.IO.Path]::Combine($env:USERPROFILE, ".gemini", "antigravity", "conversations")
            if ([System.IO.Directory]::Exists($convDir)) {
                foreach ($db in [System.IO.Directory]::EnumerateFiles($convDir, "*.db")) {
                    try { $totKB += [long]((New-Object System.IO.FileInfo($db)).Length / 1024) } catch {}
                }
            }

            # 기능 A: 5h 쿼터 역산
            $v5hQ = $txt5hPct.Text.Trim()
            if ($v5hQ -match '^\d+(\.\d+)?$') {
                $pct = [double]$v5hQ
                $usedPct = 1.0 - ($pct / 100.0)
                if ($usedPct -gt 0 -and $Global:State.TokensUsed5Hours -gt 0) {
                    $newQuota = [long]($Global:State.TokensUsed5Hours / $usedPct)
                    $Global:Config.rolling5HourQuotaTokens = $newQuota
                    $txt5hQ.Text = $newQuota.ToString()
                    $csvRow = "$($now.ToString('HH:mm:ss')),CALIB_A,0,0,$totKB,$pct,$($Global:Config.tokensPerKB),$pct,$($Global:State.RemainingWeeklyPercent),5h_quota_calib"
                    try { [System.IO.File]::AppendAllLines($todayCsv, @($csvRow), [System.Text.Encoding]::UTF8) } catch {}
                }
            }
            # 기능 A: 주간 쿼터 역산
            $vWkQ = $txtWkPct.Text.Trim()
            if ($vWkQ -match '^\d+(\.\d+)?$') {
                $pct = [double]$vWkQ
                $usedPct = 1.0 - ($pct / 100.0)
                if ($usedPct -gt 0 -and $Global:State.TokensThisWeek -gt 0) {
                    $newQuota = [long]($Global:State.TokensThisWeek / $usedPct)
                    $Global:Config.weeklyQuotaTokens = $newQuota
                    $txtWkQ.Text = $newQuota.ToString()
                    $csvRow = "$($now.ToString('HH:mm:ss')),CALIB_A,0,0,$totKB,$pct,$($Global:Config.tokensPerKB),$($Global:State.Remaining5HourPercent),$pct,wk_quota_calib"
                    try { [System.IO.File]::AppendAllLines($todayCsv, @($csvRow), [System.Text.Encoding]::UTF8) } catch {}
                }
            }

            # 기능 B: 5h 사용량 강제 동기화 (Diff CSV 로그 기록)
            $v5hSync = $txt5hSyncPct.Text.Trim()
            if ($v5hSync -match '^\d+(\.\d+)?$') {
                $pct = [double]$v5hSync
                $targetUsed = [long]($Global:Config.rolling5HourQuotaTokens * (1.0 - ($pct / 100.0)))
                $diff = $targetUsed - $Global:State.TokensUsed5Hours
                
                # tok/KB 자동 최적화
                if ($chkAutoTokPerKB.Checked -and $totKB -gt 0 -and $targetUsed -gt 0) {
                    $optTokPerKB = [int][math]::Round($targetUsed / $totKB)
                    if ($optTokPerKB -gt 0) {
                        $Global:Config.tokensPerKB = $optTokPerKB
                        $txtTokPerKB.Text = $optTokPerKB.ToString()
                    }
                }

                if ($diff -ne 0) {
                    $csvRow = "$($now.ToString('HH:mm:ss')),SYNC_5H,$diff,0,$totKB,$pct,$($Global:Config.tokensPerKB),$pct,$($Global:State.RemainingWeeklyPercent),5h_sync"
                    try { [System.IO.File]::AppendAllLines($todayCsv, @($csvRow), [System.Text.Encoding]::UTF8) } catch {}
                }
            }

            # 기능 B: 주간 사용량 강제 동기화 (6시간 전 타임스탬프 CSV 기록)
            $vWkSync = $txtWkSyncPct.Text.Trim()
            if ($vWkSync -match '^\d+(\.\d+)?$') {
                $pct = [double]$vWkSync
                $targetUsed = [long]($Global:Config.weeklyQuotaTokens * (1.0 - ($pct / 100.0)))
                $diff = $targetUsed - $Global:State.TokensThisWeek
                if ($diff -ne 0) {
                    $fakeTime = $now.AddHours(-6)
                    $fakeCsv = [System.IO.Path]::Combine($Global:Config.TokenLogsDir, "usage_$($fakeTime.ToString('yyyy-MM-dd')).csv")
                    if (-not [System.IO.File]::Exists($fakeCsv)) {
                        try { [System.IO.File]::WriteAllLines($fakeCsv, @($csvHeader), [System.Text.Encoding]::UTF8) } catch {}
                    }
                    $csvRow = "$($fakeTime.ToString('HH:mm:ss')),SYNC_WK,$diff,0,$totKB,$pct,$($Global:Config.tokensPerKB),$($Global:State.Remaining5HourPercent),$pct,wk_sync"
                    try { [System.IO.File]::AppendAllLines($fakeCsv, @($csvRow), [System.Text.Encoding]::UTF8) } catch {}
                }
            }

            if ($chkResetWeekly.Checked) {
                $Global:State.WeeklyFirstUseTime = [DateTime]::MinValue
                $Global:State.WeeklyExpiryTime   = [DateTime]::MinValue
                $sc3 = Read-StateCache
                $sc3 | Add-Member -MemberType NoteProperty -Name "weeklyFirstUseTime" -Value $null -Force
                $sc3 | Add-Member -MemberType NoteProperty -Name "weeklyExpiryTime"   -Value $null -Force
                [System.IO.File]::WriteAllText($Global:Config.StateCacheFile, ($sc3 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
            }

            $vWkMin = $txtWkExpMin.Text.Trim()
            if ($vWkMin -match '^\d+$') {
                $expMins = [int]$vWkMin
                if ($expMins -gt 0) {
                    $expiryTime = $now.AddMinutes($expMins)
                    $Global:State.WeeklyExpiryTime = $expiryTime
                    $sc3 = Read-StateCache
                    $sc3 | Add-Member -MemberType NoteProperty -Name "weeklyExpiryTime" -Value $expiryTime.ToString("yyyy-MM-ddTHH:mm:ss") -Force
                    [System.IO.File]::WriteAllText($Global:Config.StateCacheFile, ($sc3 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                }
            }

            $json = [ordered]@{}
            foreach ($key in @('rolling5HourQuotaTokens','weeklyQuotaTokens','tokensPerKB','checkIntervalSeconds')) {
                $json[$key] = $Global:Config[$key]
            }
            ($json | ConvertTo-Json) | Out-File -FilePath $Global:Config.ConfigFile -Encoding UTF8

            # 백그라운드 스캔 강제 재호출
            Start-BackgroundScanRunspace

            $f.Close()
        })
        $pnl.Controls.Add($btnSave)

        # 폼 하단 여백 추가
        Add-Label $pnl "" 20 710
        
        $f.ShowDialog()
    }

    # ==========================================================================
    # 9. 트레이 아이콘 및 컨텍스트 메뉴
    # ==========================================================================
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = (New-BatteryIcon -Percent 100 -RiskLevel "GREEN")
    $script:NotifyIcon.Visible = $true

    $ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemStatus = $ctxMenu.Items.Add("현황 확인")
    $itemStatus.Font = New-Object System.Drawing.Font("맑은 고딕", 9, [System.Drawing.FontStyle]::Bold)
    $itemStatus.Add_Click({ Show-StatusDialog })

    $itemScan = $ctxMenu.Items.Add("지금 갱신")
    $itemScan.Add_Click({ Start-BackgroundScanRunspace })

    $itemSettings = $ctxMenu.Items.Add("설정")
    $itemSettings.Add_Click({ Show-SettingsDialog })

    $itemExit = $ctxMenu.Items.Add("종료")
    $itemExit.Add_Click({
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    $script:NotifyIcon.ContextMenuStrip = $ctxMenu
    $script:NotifyIcon.Add_DoubleClick({ Show-StatusDialog })

        $script:MainTimer = New-Object System.Windows.Forms.Timer
    $script:MainTimer.Interval = $Global:Config.checkIntervalSeconds * 1000
    $script:MainTimer.Add_Tick({ Start-BackgroundScanRunspace })
    $script:MainTimer.Start()

    Start-BackgroundScanRunspace

    [System.Windows.Forms.Application]::Run()

} catch {
    Write-Log "오류 발생: $($_.Exception.Message)"
} finally {
    if ($script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() }
}

