# ==============================================================================
# Gemini Token Monitor v2.1
# 목표: 정확한 토큰 추적 / 백그라운드 동작 / 최소 메모리
# 변경: % 직접 입력 보정, calibration_log, 주간 롤링 7일 방식
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
$ConfigFile     = Join-Path $ScriptDir "config.json"
$LogFile        = Join-Path $ScriptDir "monitor.log"
$HistoryFile    = Join-Path $ScriptDir "daily_usage.json"
$StateCacheFile = Join-Path $ScriptDir "state_cache.json"
$CalibLogFile   = Join-Path $ScriptDir "calibration_log.jsonl"

# ==============================================================================
# 로깅 (200KB 초과 시 뒤쪽 절반만 유지)
# ==============================================================================
function Write-Log {
    param([string]$Message)
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$ts] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
        if ((Get-Item $LogFile).Length -gt 204800) {
            $lines = Get-Content $LogFile -Encoding UTF8
            $lines[([int]($lines.Count / 2))..($lines.Count - 1)] | Set-Content $LogFile -Encoding UTF8
        }
    } catch {}
}

# ==============================================================================
# 보정 로그 기록 (calibration_log.jsonl)
# ==============================================================================
function Write-CalibLog {
    param([string]$Type, [double]$InputPct, [long]$Quota, [long]$DerivedUsed, [string]$Note="")
    try {
        $entry = [pscustomobject]@{
            timestamp    = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
            type         = $Type
            inputPercent = $InputPct
            quota        = $Quota
            derivedUsed  = $DerivedUsed
            note         = $Note
        }
        ($entry | ConvertTo-Json -Compress) | Out-File -FilePath $CalibLogFile -Append -Encoding UTF8
        Write-Log "보정 기록: $Type $InputPct% 입력 -> used=$($DerivedUsed.ToString('#,##0')) / $($Quota.ToString('#,##0'))"
    } catch {}
}

# ==============================================================================
# state_cache.json 읽기/쓰기 (주간 첫사용시각, 보정 베이스라인 영구 보존)
# ==============================================================================
function Read-StateCache {
    try {
        if (Test-Path $StateCacheFile) {
            return (Get-Content $StateCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    } catch {}
    return [pscustomobject]@{ weeklyFirstUseTime = $null; calib5h = $null; calibWk = $null }
}

function Save-StateCache {
    param($Cache)
    try {
        ($Cache | ConvertTo-Json -Depth 4) | Out-File -FilePath $StateCacheFile -Encoding UTF8
    } catch {}
}

Write-Log "Gemini Token Monitor v2.1 시작"

try {
    # ==========================================================================
    # 1. 설정 로드
    # ==========================================================================
    $Global:Config = [hashtable]::Synchronized(@{
        apiKey                         = ""
        enableApiPing                  = $false
        dailyQuotaRPD                  = 1500
        dailyQuotaTokens               = 1000000
        rolling5HourQuotaTokens        = 1375304
        weeklyQuotaTokens              = 42565486
        tokensPerKB                    = 12
        checkIntervalSeconds           = 60
        ScriptDir                      = $ScriptDir
        ConfigFile                     = $ConfigFile
        HistoryFile                    = $HistoryFile
        StateCacheFile                 = $StateCacheFile
        CalibLogFile                   = $CalibLogFile
        LogFile                        = $LogFile
    })

    if (Test-Path $ConfigFile) {
        try {
            $json = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @('apiKey','enableApiPing','dailyQuotaRPD','dailyQuotaTokens',
                                'rolling5HourQuotaTokens','weeklyQuotaTokens',
                                'tokensPerKB','checkIntervalSeconds')) {
                if ($null -ne $json.$key) { $Global:Config[$key] = $json.$key }
            }
            if ($json.PSObject.Properties['checkIntervalMinutes'] -and $json.checkIntervalMinutes -gt 0 -and
                -not ($json.PSObject.Properties['checkIntervalSeconds'])) {
                $Global:Config.checkIntervalSeconds = [int]$json.checkIntervalMinutes * 60
            }
        } catch {
            Write-Log "config.json 로드 오류: $($_.Exception.Message)"
        }
    }

    # ==========================================================================
    # 2. 글로벌 상태
    # ==========================================================================
    $Global:State = [hashtable]::Synchronized(@{
        LastCheckTime           = [DateTime]::MinValue
        TokensUsedToday         = 0
        RequestCountToday       = 0
        TokensUsed5Hours        = 0
        TokensThisWeek          = 0
        Remaining5HourPercent   = 100
        RemainingWeeklyPercent  = 100
        RemainingDailyPercent   = 100
        BurnRateTPH             = 0
        RiskLevel               = "GREEN"
        TimeUntilWeeklyResetStr = "계산 중..."
        TimeUntil5HourResetStr  = "계산 중..."
        Short5HourRemTimeStr    = "계산 중..."
        WeeklyFirstUseTime      = [DateTime]::MinValue
        WeeklyExpiryTime        = [DateTime]::MinValue   # 수동 설정된 주간 종료 시각
        FirstTokenTimeToday     = [DateTime]::MinValue
        LastHIcon               = [IntPtr]::Zero
        IsScanning              = $false
        FileOffsetCache         = [hashtable]::Synchronized(@{})
        FileTokenCache          = [hashtable]::Synchronized(@{})
        LastSavedDailyTokens    = -1
        Calib5hUsed             = 0L
        Calib5hTime             = [DateTime]::MinValue
        Calib5hScanKB           = 0L
        CalibWkUsed             = 0L
        CalibWkTime             = [DateTime]::MinValue
        CalibWkScanKB           = 0L
        HasCalib5h              = $false
        HasCalibWk              = $false
        # 오늘 소모 베이스라인 (daily_usage.json에서 복원. 스캔 증분에 더해짐)
        DailyBaselineTokens     = 0L
        DailyBaselineDate       = [DateTime]::Today
    })

    # ==========================================================================
    # 3. 시작 시 복원: state_cache.json + daily_usage.json
    # ==========================================================================
    $sc = Read-StateCache

    # 주간 첫사용 시각 복원 (7일 이내만)
    if ($sc.weeklyFirstUseTime -ne $null -and "$($sc.weeklyFirstUseTime)" -ne "") {
        try {
            $wft = [DateTime]::Parse($sc.weeklyFirstUseTime)
            if (([DateTime]::Now - $wft).TotalDays -le 7) {
                $Global:State.WeeklyFirstUseTime = $wft
            }
        } catch {}
    }

    # 주간 종료 시각 복원 (수동 설정. 미래 시각인 경우만)
    if ($sc.weeklyExpiryTime -ne $null -and "$($sc.weeklyExpiryTime)" -ne "") {
        try {
            $wet = [DateTime]::Parse($sc.weeklyExpiryTime)
            if ($wet -gt [DateTime]::Now) {
                $Global:State.WeeklyExpiryTime = $wet
            }
        } catch {}
    }

    # 5h 보정 복원 (5시간 이내)
    if ($sc.calib5h -ne $null -and "$($sc.calib5h)" -ne "") {
        try {
            $ct = [DateTime]::Parse($sc.calib5h.timestamp)
            if (([DateTime]::Now - $ct).TotalHours -le 5) {
                $Global:State.Calib5hUsed   = [long]$sc.calib5h.usedTokens
                $Global:State.Calib5hTime   = $ct
                $Global:State.Calib5hScanKB = [long]$sc.calib5h.scanKB
                $Global:State.HasCalib5h    = $true
            }
        } catch {}
    }

    # 주간 보정 복원 (7일 이내)
    if ($sc.calibWk -ne $null -and "$($sc.calibWk)" -ne "") {
        try {
            $ct = [DateTime]::Parse($sc.calibWk.timestamp)
            if (([DateTime]::Now - $ct).TotalDays -le 7) {
                $Global:State.CalibWkUsed   = [long]$sc.calibWk.usedTokens
                $Global:State.CalibWkTime   = $ct
                $Global:State.CalibWkScanKB = [long]$sc.calibWk.scanKB
                $Global:State.HasCalibWk    = $true
            }
        } catch {}
    }

    # daily_usage.json 오늘 + 주간 즉시 복원
    if (Test-Path $HistoryFile) {
        try {
            $rawJ     = Get-Content $HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $todayStr = (Get-Date).ToString("yyyy-MM-dd")
            $nowInit  = [DateTime]::Now

            $cachedToday = 0L
            if ($rawJ.PSObject.Properties[$todayStr]) {
                $cachedToday = [long]$rawJ.PSObject.Properties[$todayStr].Value.Tokens
                $Global:State.TokensUsedToday      = $cachedToday
                $Global:State.LastSavedDailyTokens = $cachedToday
                $Global:State.DailyBaselineTokens  = $cachedToday  # 스캔 증분 계산 기준점
                $Global:State.DailyBaselineDate    = [DateTime]::Today
                $max5h = $Global:Config.rolling5HourQuotaTokens
                $p5h   = [int][math]::Floor([math]::Max(0, $max5h - $cachedToday) / $max5h * 100)
                if ($cachedToday -gt 0 -and $p5h -ge 100) { $p5h = 99 }
                $Global:State.Remaining5HourPercent = $p5h
            }

            # 주간 합산 (첫사용 시각 기준)
            $weeklySum = $cachedToday
            $wft2 = $Global:State.WeeklyFirstUseTime
            if ($wft2 -gt [DateTime]::MinValue) {
                foreach ($pr in $rawJ.PSObject.Properties) {
                    if ($pr.Name -eq $todayStr) { continue }
                    try {
                        $ed = [DateTime]::ParseExact($pr.Name, "yyyy-MM-dd", $null)
                        if ($ed.Date -ge $wft2.Date -and $ed.Date -lt $nowInit.Date) {
                            $weeklySum += [long]$pr.Value.Tokens
                        }
                    } catch {}
                }
            }

            $maxWkInit = [long]$Global:Config.weeklyQuotaTokens
            $remWkInit = [math]::Max(0L, $maxWkInit - $weeklySum)
            $pWkInit   = [int][math]::Floor($remWkInit / $maxWkInit * 100)
            if ($weeklySum -gt 0 -and $pWkInit -ge 100) { $pWkInit = 99 }
            $Global:State.RemainingWeeklyPercent = $pWkInit
            $Global:State.TokensThisWeek         = $weeklySum
        } catch {}
    }

    # ==========================================================================
    # 4. 배지 아이콘 생성
    # ==========================================================================
    function New-BatteryIcon {
        param([int]$Percent = 100, [string]$RiskLevel = "GREEN")
        try {
            if ($Global:State.LastHIcon -ne [IntPtr]::Zero) {
                [NativeMethods]::DestroyIcon($Global:State.LastHIcon) | Out-Null
                $Global:State.LastHIcon = [IntPtr]::Zero
            }
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
            $Global:State.LastHIcon = $hIcon
            $icon = [System.Drawing.Icon]::FromHandle($hIcon)
            foreach ($obj in @($g, $bmp, $pen, $fill, $tBrush, $sBrush, $font)) { $obj.Dispose() }
            return $icon
        } catch { return [System.Drawing.SystemIcons]::Application }
    }

    # ==========================================================================
    # 5. UI 갱신
    # ==========================================================================
    function Refresh-UIElements {
        if (-not $script:NotifyIcon) { return }
        $pct  = $Global:State.Remaining5HourPercent
        $risk = $Global:State.RiskLevel
        $script:NotifyIcon.Icon = New-BatteryIcon -Percent $pct -RiskLevel $risk
        $tip = "Gemini 5h $pct%($($Global:State.Short5HourRemTimeStr)) | 주간 $($Global:State.RemainingWeeklyPercent)%"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:NotifyIcon.Text = $tip
    }

    # ==========================================================================
    # 6. 백그라운드 스캔 런스페이스
    # ==========================================================================
    function Start-BackgroundScanRunspace {
        if ($Global:State.IsScanning) { return }
        $Global:State.IsScanning = $true

        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $rs.SessionStateProxy.SetVariable("SyncState",  $Global:State)
        $rs.SessionStateProxy.SetVariable("SyncConfig", $Global:Config)
        $ps = [powershell]::Create(); $ps.Runspace = $rs

        $scanBlock = {
            try {
                $now     = [DateTime]::Now
                $today   = [DateTime]::Today
                $start5h = $now.AddHours(-5)
                $start7d = $today.AddDays(-7)

                # ── 날짜 롤오버 감지: 자정 이후 첫 스캔이면 캐시 초기화 ──
                if ($SyncState.DailyBaselineDate -lt $today) {
                    $SyncState.DailyBaselineTokens = 0L
                    $SyncState.DailyBaselineDate   = $today
                    $SyncState.FileOffsetCache.Clear()
                    $SyncState.FileTokenCache.Clear()
                    $SyncState.LastSavedDailyTokens = -1
                }

                $tokensFromScan = 0L   # 이번 세션 DB 증분 누적
                $tokens5h       = 0L
                $requestsToday  = 0
                $firstActivity  = [DateTime]::MaxValue

                $convDir  = [System.IO.Path]::Combine($env:USERPROFILE, ".gemini", "antigravity", "conversations")
                $tokPerKB = if ($SyncConfig.ContainsKey('tokensPerKB') -and $SyncConfig.tokensPerKB -gt 0) {
                    [long]$SyncConfig.tokensPerKB } else { 12L }

                $totalCurrentKB = 0L

                if ([System.IO.Directory]::Exists($convDir)) {
                    $dbFiles = [System.IO.Directory]::EnumerateFiles($convDir, "*.db")
                    foreach ($dbPath in $dbFiles) {
                        try {
                            $dbInfo = New-Object System.IO.FileInfo($dbPath)
                            $dbLW   = $dbInfo.LastWriteTime
                            if ($dbLW -lt $start7d) { continue }

                            $dbKey      = $dbPath
                            $prevSizeKB = 0L
                            if ($SyncState.FileOffsetCache.ContainsKey($dbKey)) { $prevSizeKB = $SyncState.FileOffsetCache[$dbKey] }
                            $curSizeKB = [long]($dbInfo.Length / 1024)

                            if ($dbLW -ge $today) { $totalCurrentKB += $curSizeKB }

                            $cachedTotal = 0L
                            if ($SyncState.FileTokenCache.ContainsKey($dbKey)) { $cachedTotal = $SyncState.FileTokenCache[$dbKey] }

                            $newTotal = if ($prevSizeKB -eq 0L) {
                                # ✅ 첫 발견: 베이스라인만 기록, 기존 바이트는 세지 않음
                                # (이전 세션 사용량은 DailyBaselineTokens에 이미 반영)
                                0L
                            } elseif ($curSizeKB -gt $prevSizeKB) {
                                $cachedTotal + (($curSizeKB - $prevSizeKB) * $tokPerKB)
                            } else { $cachedTotal }

                            $SyncState.FileOffsetCache[$dbKey] = $curSizeKB
                            $SyncState.FileTokenCache[$dbKey]  = $newTotal
                            if ($newTotal -le 0) { continue }

                            if ($dbLW -ge $today) {
                                $tokensFromScan += $newTotal   # 이번 세션 증분만
                                if ($curSizeKB -gt $prevSizeKB) {
                                    $requestsToday += [math]::Max(1, [int](($curSizeKB - $prevSizeKB) / 8))
                                }
                                if ($dbLW -lt $firstActivity) { $firstActivity = $dbLW }
                            }
                            if ($dbLW -ge $start5h) { $tokens5h += $newTotal }
                        } catch {}
                    }
                }

                # ✅ 오늘 소모 = 이전 세션 저장값(베이스라인) + 이번 세션 증분
                $tokensToday = $SyncState.DailyBaselineTokens + $tokensFromScan

                # 5h 보정 적용 (보정이 있으면 override)
                if ($SyncState.HasCalib5h) {
                    $kbDelta5h = [math]::Max(0L, $totalCurrentKB - $SyncState.Calib5hScanKB)
                    $tokens5h  = $SyncState.Calib5hUsed + ($kbDelta5h * $tokPerKB)
                }

                # 주간 첫사용 시각 감지/저장
                $wft = $SyncState.WeeklyFirstUseTime
                if ($firstActivity -lt [DateTime]::MaxValue) {
                    if ($wft -le [DateTime]::MinValue) {
                        $SyncState.WeeklyFirstUseTime = $firstActivity; $wft = $firstActivity
                        try {
                            $sc2 = if ([System.IO.File]::Exists($SyncConfig.StateCacheFile)) {
                                [System.IO.File]::ReadAllText($SyncConfig.StateCacheFile) | ConvertFrom-Json
                            } else { [pscustomobject]@{} }
                            $wftStr = $firstActivity.ToString("yyyy-MM-ddTHH:mm:ss")
                            $sc2 | Add-Member -MemberType NoteProperty -Name "weeklyFirstUseTime" -Value $wftStr -Force
                            [System.IO.File]::WriteAllText($SyncConfig.StateCacheFile, ($sc2 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                        } catch {}
                    } elseif (($now - $wft).TotalDays -gt 7) {
                        # 7일 경과 -> 주간 리셋
                        $SyncState.WeeklyFirstUseTime = $firstActivity; $wft = $firstActivity
                        $SyncState.HasCalibWk = $false; $SyncState.CalibWkUsed = 0L
                        try {
                            $sc2 = if ([System.IO.File]::Exists($SyncConfig.StateCacheFile)) {
                                [System.IO.File]::ReadAllText($SyncConfig.StateCacheFile) | ConvertFrom-Json
                            } else { [pscustomobject]@{} }
                            $wftStr2 = $firstActivity.ToString("yyyy-MM-ddTHH:mm:ss")
                            $sc2 | Add-Member -MemberType NoteProperty -Name "weeklyFirstUseTime" -Value $wftStr2 -Force
                            $sc2 | Add-Member -MemberType NoteProperty -Name "calibWk"            -Value $null   -Force
                            [System.IO.File]::WriteAllText($SyncConfig.StateCacheFile, ($sc2 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                        } catch {}
                    }
                }

                # 주간 토큰 계산
                $maxWk = [long]$SyncConfig.weeklyQuotaTokens
                $tokensThisWeek = $tokensToday

                if ($SyncState.HasCalibWk) {
                    $kbDeltaWk      = [math]::Max(0L, $totalCurrentKB - $SyncState.CalibWkScanKB)
                    $tokensThisWeek = $SyncState.CalibWkUsed + ($kbDeltaWk * $tokPerKB)
                } else {
                    try {
                        $histFile2 = $SyncConfig.HistoryFile
                        if ([System.IO.File]::Exists($histFile2)) {
                            $histJson  = [System.IO.File]::ReadAllText($histFile2) | ConvertFrom-Json
                            $todayStr2 = $now.ToString("yyyy-MM-dd")
                            $wftDate   = if ($wft -gt [DateTime]::MinValue) { $wft.Date } else { $today.AddDays(-7) }
                            foreach ($pr in $histJson.PSObject.Properties) {
                                if ($pr.Name -eq $todayStr2) { continue }
                                try {
                                    $ed = [DateTime]::ParseExact($pr.Name, "yyyy-MM-dd", $null)
                                    if ($ed.Date -ge $wftDate -and $ed.Date -lt $today) {
                                        $tokensThisWeek += [long]$pr.Value.Tokens
                                    }
                                } catch {}
                            }
                        }
                    } catch {}
                }

                # % 계산
                $max5h = [long]$SyncConfig.rolling5HourQuotaTokens
                $rem5h = [math]::Max(0L, $max5h - $tokens5h)
                $p5h   = [int][math]::Floor($rem5h / $max5h * 100)
                if ($tokens5h -gt 0 -and $p5h -ge 100) { $p5h = 99 }

                $remWk = [math]::Max(0L, $maxWk - $tokensThisWeek)
                $pWk   = [int][math]::Floor($remWk / $maxWk * 100)
                if ($tokensThisWeek -gt 0 -and $pWk -ge 100) { $pWk = 99 }

                $maxD = [long]$SyncConfig.dailyQuotaTokens
                $remD = [math]::Max(0L, $maxD - $tokensToday)
                $pD   = [int][math]::Floor($remD / $maxD * 100)

                # 5h 카운트다운
                if ($firstActivity -lt [DateTime]::MaxValue) {
                    $expiry5h = $firstActivity.AddHours(5)
                    if ($now -ge $expiry5h) {
                        $SyncState.TimeUntil5HourResetStr = $firstActivity.ToString("HH:mm") + " 첫 사용 -> 5h 경과, 쿼터 복구 완료"
                        $SyncState.Short5HourRemTimeStr   = "복구완료"
                    } else {
                        $span5h = $expiry5h - $now
                        $SyncState.TimeUntil5HourResetStr = $firstActivity.ToString("HH:mm") + " 첫 사용 -> " + $expiry5h.ToString("HH:mm") + " 복구 (" + $span5h.Hours + "h " + $span5h.Minutes + "m 남음)"
                        $SyncState.Short5HourRemTimeStr   = $span5h.Hours.ToString() + "h " + $span5h.Minutes.ToString() + "m 남음"
                    }
                } else {
                    $SyncState.TimeUntil5HourResetStr = "오늘 사용 기록 없음"
                    $SyncState.Short5HourRemTimeStr   = "대기 중"
                }

                # 주간 카운트다운 — 수동 종료 시각 우선, 없으면 롤링 7일
                $wet = $SyncState.WeeklyExpiryTime
                if ($wet -gt [DateTime]::MinValue) {
                    # 수동 설정된 종료 시각 기준
                    if ($now -ge $wet) {
                        # 종료 시각 경과 → 주간 리셋
                        $SyncState.WeeklyExpiryTime  = [DateTime]::MinValue
                        $SyncState.WeeklyFirstUseTime = [DateTime]::MinValue
                        $SyncState.HasCalibWk = $false; $SyncState.CalibWkUsed = 0L
                        $SyncState.TimeUntilWeeklyResetStr = "주간 초기화 완료 - 다음 사용 시 새 7일 윈도우 시작"
                        try {
                            $sc2 = if ([System.IO.File]::Exists($SyncConfig.StateCacheFile)) {
                                [System.IO.File]::ReadAllText($SyncConfig.StateCacheFile) | ConvertFrom-Json
                            } else { [pscustomobject]@{} }
                            $sc2 | Add-Member -MemberType NoteProperty -Name "weeklyExpiryTime"   -Value $null -Force
                            $sc2 | Add-Member -MemberType NoteProperty -Name "weeklyFirstUseTime" -Value $null -Force
                            $sc2 | Add-Member -MemberType NoteProperty -Name "calibWk"            -Value $null -Force
                            [System.IO.File]::WriteAllText($SyncConfig.StateCacheFile, ($sc2 | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                        } catch {}
                    } else {
                        $wspan = $wet - $now
                        $dStr  = if ($wspan.Days -gt 0) { $wspan.Days.ToString() + "일 " } else { "" }
                        $SyncState.TimeUntilWeeklyResetStr = "[수동] " + $wet.ToString("MM/dd HH:mm") + " 초기화 (" + $dStr + $wspan.Hours + "h " + $wspan.Minutes + "m 남음)"
                    }
                } elseif ($wft -gt [DateTime]::MinValue) {
                    # 롤링 7일 기준
                    $weekExpiry = $wft.AddDays(7)
                    $wspan = $weekExpiry - $now
                    if ($wspan.TotalSeconds -le 0) {
                        $SyncState.TimeUntilWeeklyResetStr = "7일 경과 - 다음 사용 시 새 주간 윈도우 시작"
                    } else {
                        $dStr2 = if ($wspan.Days -gt 0) { $wspan.Days.ToString() + "일 " } else { "" }
                        $SyncState.TimeUntilWeeklyResetStr = $wft.ToString("MM/dd HH:mm") + " 첫 사용 -> " + $weekExpiry.ToString("MM/dd HH:mm") + " 복구 (" + $dStr2 + $wspan.Hours + "h " + $wspan.Minutes + "m 남음)"
                    }
                } else {
                    $SyncState.TimeUntilWeeklyResetStr = "주간 사용 기록 없음"
                }

                $risk = "GREEN"
                if ($p5h -le 10 -or $pWk -le 10) { $risk = "RED" }
                elseif ($p5h -le 25 -or $pWk -le 25) { $risk = "YELLOW" }

                $SyncState.TokensUsedToday        = $tokensToday
                $SyncState.TokensUsed5Hours       = $tokens5h
                $SyncState.RequestCountToday      = $requestsToday
                $SyncState.Remaining5HourPercent  = $p5h
                $SyncState.RemainingWeeklyPercent = $pWk
                $SyncState.RemainingDailyPercent  = $pD
                $SyncState.TokensThisWeek         = $tokensThisWeek
                $SyncState.FirstTokenTimeToday    = if ($firstActivity -lt [DateTime]::MaxValue) { $firstActivity } else { [DateTime]::MinValue }
                $SyncState.RiskLevel              = $risk
                $SyncState.LastCheckTime          = $now

                # daily_usage.json 저장
                if ($tokensToday -ne $SyncState.LastSavedDailyTokens) {
                    try {
                        $histFile  = $SyncConfig.HistoryFile
                        $todayKey  = $now.ToString("yyyy-MM-dd")
                        $cutoffKey = $now.AddDays(-30).ToString("yyyy-MM-dd")
                        $histObj   = [ordered]@{}
                        if ([System.IO.File]::Exists($histFile)) {
                            try {
                                $parsed = [System.IO.File]::ReadAllText($histFile) | ConvertFrom-Json
                                foreach ($pr in $parsed.PSObject.Properties) {
                                    if ($pr.Name -ge $cutoffKey) { $histObj[$pr.Name] = $pr.Value }
                                }
                            } catch {}
                        }
                        $histObj[$todayKey] = [pscustomobject]@{ Tokens = $tokensToday; TPM = 0; Updated = $now.ToString("HH:mm:ss") }
                        [System.IO.File]::WriteAllText($histFile, ($histObj | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
                        $SyncState.LastSavedDailyTokens = $tokensToday
                    } catch {}
                }
            } catch {}
            $SyncState.IsScanning = $false
        }

        $ps.AddScript($scanBlock) | Out-Null
        $handle = $ps.BeginInvoke()

        $pollTimer = New-Object System.Windows.Forms.Timer
        $pollTimer.Interval = 500
        $pollTimer.Add_Tick({
            if ($handle.IsCompleted) {
                $pollTimer.Stop(); $pollTimer.Dispose()
                try { $ps.EndInvoke($handle) } catch {}
                $ps.Dispose(); $rs.Dispose()
                Refresh-UIElements
            }
        })
        $pollTimer.Start()
    }

    # ==========================================================================
    # 7. 현황 창
    # ==========================================================================
    function Show-StatusDialog {
        Start-BackgroundScanRunspace

        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor v2.1 - 현황"
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
            $c5hStr     = if ($st.HasCalib5h) { "[보정:" + $st.Calib5hTime.ToString("HH:mm") + "]" } else { "[DB추정]" }
            $cWkStr     = if ($st.HasCalibWk) { "[보정:" + $st.CalibWkTime.ToString("HH:mm") + "]" } else { "[daily합산]" }
            @(
                "======================================================",
                "      Gemini Token Monitor  v2.1 - 실시간 현황",
                "======================================================",
                ("  갱신 시각  : " + $(if ($st.LastCheckTime -gt [DateTime]::MinValue) { $st.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "스캔 중..." })),
                "",
                "-- 쿼터 잔여 ----------------------------------------",
                ("  오늘 소모   : " + $st.TokensUsedToday.ToString("#,##0") + " tok  (요청 " + $st.RequestCountToday + "회)"),
                ("  5h  잔여   : " + $st.Remaining5HourPercent + "%  (" + $rem5hTok.ToString("#,##0") + " / " + $cfg.rolling5HourQuotaTokens.ToString("#,##0") + " tok) " + $c5hStr),
                ("  주간 잔여   : " + $st.RemainingWeeklyPercent + "%  (" + $remWkTok.ToString("#,##0") + " / " + $cfg.weeklyQuotaTokens.ToString("#,##0") + " tok) " + $cWkStr),
                ("    이번주 소모: " + $weeklyUsed.ToString("#,##0") + " tok  | 주간 첫사용: " + $wftStr),
                "",
                "-- 리셋 카운트다운 ----------------------------------",
                ("  5h  복구   : " + $st.TimeUntil5HourResetStr),
                ("  주간 복구   : " + $st.TimeUntilWeeklyResetStr),
                ("  일일 리셋   : 자정 - 잔여 " + $st.RemainingDailyPercent + "% (" + $st.TokensUsedToday.ToString("#,##0") + "/" + $cfg.dailyQuotaTokens.ToString("#,##0") + " tok)"),
                "",
                "-- 위험도 -------------------------------------------",
                ("  상태       : " + $(switch ($st.RiskLevel) { "RED" {"[위험] 쿼터 소진 임박"} "YELLOW" {"[주의] 25% 미만 잔여"} default {"[정상] 안전"} })),
                "======================================================"
            ) -join "`r`n"
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

        $f.ShowDialog()
    }

    # ==========================================================================
    # 8. 설정 창
    # ==========================================================================
    function Show-SettingsDialog {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor - 설정"
        $f.Size = New-Object System.Drawing.Size(540, 760)
        $f.StartPosition = "CenterScreen"; $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false; $f.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 40)

        function Add-Label { param($form,$text,$x,$y,[bool]$bold=$false)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $text; $l.ForeColor = [System.Drawing.Color]::White
            $l.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5, $(if ($bold) {[System.Drawing.FontStyle]::Bold} else {[System.Drawing.FontStyle]::Regular}))
            $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
            $form.Controls.Add($l); return $l
        }
        function Add-SubLabel { param($form,$text,$x,$y)
            $l = New-Object System.Windows.Forms.Label; $l.Text = $text
            $l.ForeColor = [System.Drawing.Color]::FromArgb(150,150,150)
            $l.Font = New-Object System.Drawing.Font("맑은 고딕", 8.5)
            $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true; $form.Controls.Add($l)
        }
        function Add-Input { param($form,$x,$y,$w,$val)
            $t = New-Object System.Windows.Forms.TextBox; $t.Text = "$val"
            $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 24)
            $form.Controls.Add($t); return $t
        }

        Add-Label $f "쿼터 설정" 20 15 $true
        Add-Label $f "5시간 롤링 쿼터 (tokens):" 20 38
        $txt5hQ = Add-Input $f 20 56 490 $Global:Config.rolling5HourQuotaTokens

        Add-Label $f "주간 롤링 쿼터 (tokens):" 20 90
        $txtWkQ = Add-Input $f 20 108 490 $Global:Config.weeklyQuotaTokens

        # 구분선
        Add-Label $f "─────────────────────────────────────────────────" 20 143
        Add-Label $f "현재 잔여 % 직접 입력 보정  (Gemini AI Studio에서 확인)" 20 160 $true
        Add-SubLabel $f "비워두면 자동 추정. 입력하면 현재 시각 기준 베이스라인 저장 후 이후 사용량 자동 추적." 20 178

        Add-Label $f "5h 잔여 % 입력:" 20 202
        $txt5hPct = Add-Input $f 170 200 80 ""
        $lblPct1 = New-Object System.Windows.Forms.Label
        $lblPct1.Text = "%  (예: 72.5)"; $lblPct1.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
        $lblPct1.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblPct1.Location = New-Object System.Drawing.Point(258, 204); $lblPct1.AutoSize = $true; $f.Controls.Add($lblPct1)
        Add-SubLabel $f "입력 시 tokensPerKB 비율도 자동으로 역산됩니다." 20 228

        Add-Label $f "주간 잔여 % 입력:" 20 256
        $txtWkPct = Add-Input $f 170 254 80 ""
        $lblPct2 = New-Object System.Windows.Forms.Label
        $lblPct2.Text = "%  (예: 65)"; $lblPct2.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
        $lblPct2.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblPct2.Location = New-Object System.Drawing.Point(258, 258); $lblPct2.AutoSize = $true; $f.Controls.Add($lblPct2)
        Add-SubLabel $f "주간 첫사용 시각부터 7일 롤링. 보정 내역은 calibration_log.jsonl에 기록됩니다." 20 280

        Add-Label $f "⏱️ 주간 초기화까지 남은 시간 (분, 비워두면 자동 7일 롤링):" 20 302
        Add-SubLabel $f "Gemini UI에서 확인한 남은 분(예: 2880 = 2일)을 입력하면 정확한 종료 시각을 계산합니다." 20 320
        $txtWkExpMin = Add-Input $f 20 337 150 $(
            if ($Global:State.WeeklyExpiryTime -gt [DateTime]::Now) {
                [int]($Global:State.WeeklyExpiryTime - [DateTime]::Now).TotalMinutes
            } else { "" }
        )
        $lblWkExpInfo = New-Object System.Windows.Forms.Label
        $lblWkExpInfo.ForeColor = [System.Drawing.Color]::FromArgb(100, 200, 255)
        $lblWkExpInfo.Font = New-Object System.Drawing.Font("맑은 고딕", 8.5)
        $lblWkExpInfo.Location = New-Object System.Drawing.Point(180, 341); $lblWkExpInfo.AutoSize = $true
        $lblWkExpInfo.Text = if ($Global:State.WeeklyExpiryTime -gt [DateTime]::Now) {
            "현재: " + $Global:State.WeeklyExpiryTime.ToString("MM/dd HH:mm") + " 초기화 예정"
        } else { "" }
        $f.Controls.Add($lblWkExpInfo)

        Add-Label $f "─────────────────────────────────────────────────" 20 370
        Add-Label $f "고급 설정" 20 385 $true

        Add-Label $f "갱신 주기 (초, 기본 60):" 20 410
        $txtInterval = Add-Input $f 20 428 200 $Global:Config.checkIntervalSeconds

        Add-Label $f "DB 크기 -> 토큰 비율 (tok/KB, 기본 12):" 20 464
        Add-SubLabel $f "5h % 보정 시 자동 역산. 수동 조정도 가능합니다." 20 482
        $txtTokPerKB = Add-Input $f 20 500 200 $Global:Config.tokensPerKB

        Add-Label $f "─────────────────────────────────────────────────" 20 535
        $chkResetWeekly = New-Object System.Windows.Forms.CheckBox
        $chkResetWeekly.Text = "주간 첫사용 시각 + 수동 종료시각 초기화 (다음 사용부터 새 7일 윈도우 시작)"
        $chkResetWeekly.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
        $chkResetWeekly.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $chkResetWeekly.Location = New-Object System.Drawing.Point(20, 552); $chkResetWeekly.AutoSize = $true
        $f.Controls.Add($chkResetWeekly)

        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text = "저장 및 즉시 갱신"
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
            $sc3 = Read-StateCache
            $scanKBNow = 0L
            foreach ($v in $Global:State.FileOffsetCache.Values) { $scanKBNow += [long]$v }

            # 5h % 보정
            $v5h = $txt5hPct.Text.Trim()
            if ($v5h -ne "" -and $v5h -match '^\d+(\.\d+)?$') {
                $pct5h     = [double]$v5h
                $quota5h   = [long]$Global:Config.rolling5HourQuotaTokens
                $derived5h = [long]($quota5h * (1.0 - $pct5h / 100.0))
                if ($derived5h -lt 0) { $derived5h = 0L }

                Write-CalibLog -Type "5h" -InputPct $pct5h -Quota $quota5h -DerivedUsed $derived5h -Note "user input"
                $Global:State.Calib5hUsed   = $derived5h
                $Global:State.Calib5hTime   = $now
                $Global:State.Calib5hScanKB = $scanKBNow
                $Global:State.HasCalib5h    = $true

                # tokensPerKB 역산
                if ($scanKBNow -gt 0 -and $derived5h -gt 0) {
                    $ratio = [math]::Round($derived5h / $scanKBNow)
                    if ($ratio -ge 1 -and $ratio -le 500) {
                        $Global:Config.tokensPerKB = [int]$ratio
                        Write-Log "tokensPerKB 자동역산: $ratio (5h=$pct5h%)"
                    }
                }

                $calib5hObj = [pscustomobject]@{ timestamp = $now.ToString("yyyy-MM-ddTHH:mm:ss"); usedTokens = $derived5h; scanKB = $scanKBNow; pct = $pct5h }
                $sc3 | Add-Member -MemberType NoteProperty -Name "calib5h" -Value $calib5hObj -Force
            }

            # 주간 % 보정
            $vWk = $txtWkPct.Text.Trim()
            if ($vWk -ne "" -and $vWk -match '^\d+(\.\d+)?$') {
                $pctWk     = [double]$vWk
                $quotaWk   = [long]$Global:Config.weeklyQuotaTokens
                $derivedWk = [long]($quotaWk * (1.0 - $pctWk / 100.0))
                if ($derivedWk -lt 0) { $derivedWk = 0L }

                Write-CalibLog -Type "weekly" -InputPct $pctWk -Quota $quotaWk -DerivedUsed $derivedWk -Note "user input"
                $Global:State.CalibWkUsed   = $derivedWk
                $Global:State.CalibWkTime   = $now
                $Global:State.CalibWkScanKB = $scanKBNow
                $Global:State.HasCalibWk    = $true

                $calibWkObj = [pscustomobject]@{ timestamp = $now.ToString("yyyy-MM-ddTHH:mm:ss"); usedTokens = $derivedWk; scanKB = $scanKBNow; pct = $pctWk }
                $sc3 | Add-Member -MemberType NoteProperty -Name "calibWk" -Value $calibWkObj -Force
            }

            # 주간 첫사용 초기화
            if ($chkResetWeekly.Checked) {
                $Global:State.WeeklyFirstUseTime = [DateTime]::MinValue
                $Global:State.WeeklyExpiryTime   = [DateTime]::MinValue
                $Global:State.HasCalibWk = $false; $Global:State.CalibWkUsed = 0L
                $sc3 | Add-Member -MemberType NoteProperty -Name "weeklyFirstUseTime" -Value $null -Force
                $sc3 | Add-Member -MemberType NoteProperty -Name "weeklyExpiryTime"   -Value $null -Force
                $sc3 | Add-Member -MemberType NoteProperty -Name "calibWk"            -Value $null -Force
                Write-Log "주간 첫사용 시각 + 종료시각 사용자 초기화"
            }

            # 주간 종료 시각 수동 설정 (분 단위 입력)
            $vWkMin = $txtWkExpMin.Text.Trim()
            if ($vWkMin -ne "" -and $vWkMin -match '^\d+$') {
                $expMins = [int]$vWkMin
                if ($expMins -gt 0) {
                    $expiryTime    = $now.AddMinutes($expMins)
                    $expiryTimeStr = $expiryTime.ToString("yyyy-MM-ddTHH:mm:ss")
                    $Global:State.WeeklyExpiryTime = $expiryTime
                    $sc3 | Add-Member -MemberType NoteProperty -Name "weeklyExpiryTime" -Value $expiryTimeStr -Force
                    Write-Log "주간 종료 시각 수동 설정: $($expiryTime.ToString('MM/dd HH:mm')) (${expMins}분 후)"
                }
            }

            Save-StateCache -Cache $sc3

            # config.json 저장
            try {
                $raw = if ([System.IO.File]::Exists($Global:Config.ConfigFile)) {
                    [System.IO.File]::ReadAllText($Global:Config.ConfigFile) | ConvertFrom-Json
                } else { [pscustomobject]@{} }
                $raw | Add-Member -MemberType NoteProperty -Name "rolling5HourQuotaTokens" -Value $Global:Config.rolling5HourQuotaTokens -Force
                $raw | Add-Member -MemberType NoteProperty -Name "weeklyQuotaTokens"       -Value $Global:Config.weeklyQuotaTokens       -Force
                $raw | Add-Member -MemberType NoteProperty -Name "tokensPerKB"             -Value $Global:Config.tokensPerKB             -Force
                $raw | Add-Member -MemberType NoteProperty -Name "checkIntervalSeconds"    -Value $Global:Config.checkIntervalSeconds    -Force
                [System.IO.File]::WriteAllText($Global:Config.ConfigFile, ($raw | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
                Write-Log "설정 저장 완료"
            } catch { Write-Log "설정 저장 오류: $($_.Exception.Message)" }

            if ($script:MainTimer) {
                $script:MainTimer.Interval = [math]::Max(10, $Global:Config.checkIntervalSeconds) * 1000
            }
            $Global:State.FileOffsetCache.Clear()
            $Global:State.FileTokenCache.Clear()
            $Global:State.LastSavedDailyTokens = -1

            Start-BackgroundScanRunspace
            [System.Windows.Forms.MessageBox]::Show("저장 완료!", "Gemini Monitor", "OK", "Information")
            $f.Close()
        })
        $f.Controls.Add($btnSave)
        $f.ShowDialog()
    }

    # ==========================================================================
    # 9. 트레이 초기화
    # ==========================================================================
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = New-BatteryIcon -Percent $Global:State.Remaining5HourPercent -RiskLevel "GREEN"
    $script:NotifyIcon.Text = "Gemini Token Monitor"
    $script:NotifyIcon.Visible = $true
    Refresh-UIElements

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Items.Add("📊 현 상태 보기").Add_Click({ Show-StatusDialog })
    $menu.Items.Add("🔄 지금 갱신").Add_Click({ Start-BackgroundScanRunspace })
    $menu.Items.Add("-") | Out-Null
    $menu.Items.Add("⚙️ 설정").Add_Click({ Show-SettingsDialog })
    $menu.Items.Add("-") | Out-Null
    $menu.Items.Add("❌ 종료").Add_Click({
        $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.Add_DoubleClick({ Show-StatusDialog })

    # ==========================================================================
    # 10. 타이머
    # ==========================================================================
    $script:MainTimer = New-Object System.Windows.Forms.Timer
    $script:MainTimer.Interval = [math]::Max(10, $Global:Config.checkIntervalSeconds) * 1000
    $script:MainTimer.Add_Tick({ Start-BackgroundScanRunspace })
    $script:MainTimer.Start()

    $startTimer = New-Object System.Windows.Forms.Timer
    $startTimer.Interval = 50
    $startTimer.Add_Tick({ $startTimer.Stop(); $startTimer.Dispose(); Start-BackgroundScanRunspace })
    $startTimer.Start()

    Write-Log "v2.1 구동 완료 (갱신: $($Global:Config.checkIntervalSeconds)초)"

    $appCtx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($appCtx)

} catch {
    Write-Log "치명적 오류: $($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show("오류:`n$($_.Exception.Message)", "Gemini Monitor", "OK", "Error")
}
