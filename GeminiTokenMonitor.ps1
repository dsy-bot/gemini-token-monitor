# ==============================================================================
# Gemini Token Monitor v2.0
# 목표: 정확한 토큰 추적 / 백그라운드 동작 / 최소 메모리
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

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile  = Join-Path $ScriptDir "config.json"
$LogFile     = Join-Path $ScriptDir "monitor.log"
$HistoryFile = Join-Path $ScriptDir "daily_usage.json"

# ==============================================================================
# 로깅 (파일 크기 제한: 200KB 초과 시 절반 잘라냄)
# ==============================================================================
function Write-Log {
    param([string]$Message)
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$ts] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
        # 로그 파일 200KB 초과 시 뒤쪽 절반만 유지
        if ((Get-Item $LogFile).Length -gt 204800) {
            $lines = Get-Content $LogFile -Encoding UTF8
            $lines[([int]($lines.Count / 2))..($lines.Count - 1)] | Set-Content $LogFile -Encoding UTF8
        }
    } catch {}
}

Write-Log "Gemini Token Monitor v2.0 시작"

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
        # 주간 계산 시 이전 누적 사용량 오프셋 (수동 보정)
        weeklyPrevUsedTokens           = 0
        # DB 파일 크기 → 토큰 추정 비율 (기본 12 tok/KB, 실측 후 보정)
        tokensPerKB                    = 12
        override5HourRemainingMinutes  = $null
        overrideWeeklyRemainingHours   = $null
        weeklyResetDay                 = 1
        weeklyResetHour                = 9
        checkIntervalSeconds           = 60   # 기본 60초 (1분)
        ScriptDir                      = $ScriptDir
        ConfigFile                     = $ConfigFile
        HistoryFile                    = $HistoryFile
    })

    if (Test-Path $ConfigFile) {
        try {
            $json = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @('apiKey','enableApiPing','dailyQuotaRPD','dailyQuotaTokens',
                                'rolling5HourQuotaTokens','weeklyQuotaTokens','weeklyPrevUsedTokens',
                                'tokensPerKB','weeklyResetDay','weeklyResetHour')) {
                if ($null -ne $json.$key) { $Global:Config[$key] = $json.$key }
            }
            # 오버라이드 (null 허용)
            if ($json.PSObject.Properties['override5HourRemainingMinutes']) {
                $v = $json.override5HourRemainingMinutes
                $Global:Config.override5HourRemainingMinutes = if ($v -ne $null -and "$v" -ne "") { [int]$v } else { $null }
            }
            if ($json.PSObject.Properties['overrideWeeklyRemainingHours']) {
                $v = $json.overrideWeeklyRemainingHours
                $Global:Config.overrideWeeklyRemainingHours = if ($v -ne $null -and "$v" -ne "") { [int]$v } else { $null }
            }
            # 갱신 주기 (초 단위. 기존 minutes 키도 호환)
            if ($json.PSObject.Properties['checkIntervalSeconds'] -and $json.checkIntervalSeconds -gt 0) {
                $Global:Config.checkIntervalSeconds = [int]$json.checkIntervalSeconds
            } elseif ($json.PSObject.Properties['checkIntervalMinutes'] -and $json.checkIntervalMinutes -gt 0) {
                $Global:Config.checkIntervalSeconds = [int]$json.checkIntervalMinutes * 60
            }
        } catch {
            Write-Log "config.json 로드 오류: $($_.Exception.Message)"
        }
    }

    # ==========================================================================
    # 2. 글로벌 상태 (증분 스캔용 파일별 마지막 처리 타임스탬프 캐시 포함)
    # ==========================================================================
    $Global:State = [hashtable]::Synchronized(@{
        LastCheckTime          = [DateTime]::MinValue
        TokensUsedToday        = 0
        RequestCountToday      = 0
        TokensUsed5Hours       = 0
        Remaining5HourPercent  = 100
        RemainingWeeklyPercent = 100
        RemainingDailyPercent  = 100
        BurnRateTPH            = 0
        RiskLevel              = "GREEN"
        TimeUntilWeeklyResetStr = "계산 중..."
        TimeUntil5HourResetStr  = "계산 중..."
        Short5HourRemTimeStr    = "계산 중..."
        FirstTokenTimeToday    = [DateTime]::MinValue
        LastHIcon              = [IntPtr]::Zero
        IsScanning             = $false
        # 증분 스캔: 파일경로 → 마지막 처리 크기 (바이트)
        FileOffsetCache        = [hashtable]::Synchronized(@{})
        # 증분 스캔: 파일경로 → 해당 파일의 현재 최대 토큰
        FileTokenCache         = [hashtable]::Synchronized(@{})
        # 이전 저장된 daily tokens (불필요한 쓰기 방지용)
        LastSavedDailyTokens   = -1
    })

    # startup: daily_usage.json 에서 오늘 캐시 값 복원
    if (Test-Path $HistoryFile) {
        try {
            $rawJ = Get-Content $HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $todayStr = (Get-Date).ToString("yyyy-MM-dd")
            if ($rawJ.PSObject.Properties[$todayStr]) {
                $cached = [long]$rawJ.PSObject.Properties[$todayStr].Value.Tokens
                $Global:State.TokensUsedToday   = $cached
                $Global:State.TokensUsed5Hours  = $cached
                $max5h = $Global:Config.rolling5HourQuotaTokens
                $p5h   = [int][math]::Floor([math]::Max(0, $max5h - $cached) / $max5h * 100)
                if ($cached -gt 0 -and $p5h -ge 100) { $p5h = 99 }
                $Global:State.Remaining5HourPercent = $p5h
                $Global:State.LastSavedDailyTokens  = $cached
            }
        } catch {}
    }

    # ==========================================================================
    # 3. 유틸 함수: 주간 리셋 카운트다운 문자열 반환
    # ==========================================================================
    function Get-WeeklyResetStr {
        if ($null -ne $Global:Config.overrideWeeklyRemainingHours) {
            $h   = [int]$Global:Config.overrideWeeklyRemainingHours
            $eta = [DateTime]::Now.AddHours($h)
            return "[수동] " + $eta.ToString("MM/dd HH:mm") + " 리셋 (" + $h + "h 남음)"
        }
        $now         = [DateTime]::Now
        $resetDow    = $Global:Config.weeklyResetDay   # 0=Sun..6=Sat
        $resetHour   = $Global:Config.weeklyResetHour
        $todayBase   = (Get-Date -Hour $resetHour -Minute 0 -Second 0 -Millisecond 0)
        $curDow      = [int]$now.DayOfWeek
        $daysUntil   = ($resetDow - $curDow + 7) % 7
        if ($daysUntil -eq 0 -and $now -ge $todayBase) { $daysUntil = 7 }
        $nextReset   = $todayBase.AddDays($daysUntil)
        $span        = $nextReset - $now
        $dayNames    = @("일","월","화","수","목","금","토")
        return "매주 " + $dayNames[$resetDow % 7] + "요일 " + $resetHour + ":00 (" + $span.Days + "일 " + $span.Hours + "시간 남음)"
    }

    # ==========================================================================
    # 4. 배지 아이콘 생성 (GDI 핸들 해제, GC::Collect 제거)
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
                "RED"    { $bg = [System.Drawing.Color]::FromArgb(231, 76, 60);  $bd = [System.Drawing.Color]::FromArgb(192, 57, 43);  $tc = [System.Drawing.Color]::White }
                "YELLOW" { $bg = [System.Drawing.Color]::FromArgb(241, 196, 15); $bd = [System.Drawing.Color]::FromArgb(211, 84,  0);  $tc = [System.Drawing.Color]::Black }
                default  { $bg = [System.Drawing.Color]::FromArgb(46, 204, 113); $bd = [System.Drawing.Color]::FromArgb(39, 174, 96);  $tc = [System.Drawing.Color]::White }
            }

            $pen  = New-Object System.Drawing.Pen($bd, 2)
            $fill = New-Object System.Drawing.SolidBrush($bg)
            $g.FillRectangle($fill, 1, 2, 30, 28)
            $g.DrawRectangle($pen,  1, 2, 30, 28)

            $font   = New-Object System.Drawing.Font("Arial", 9.5, [System.Drawing.FontStyle]::Bold)
            $tBrush = New-Object System.Drawing.SolidBrush($tc)
            $sBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
            $txt    = "$Percent"
            $sz     = $g.MeasureString($txt, $font)
            $px     = [int]((32 - $sz.Width)  / 2)
            $py     = [int]((32 - $sz.Height) / 2)
            if ($RiskLevel -ne "YELLOW") { $g.DrawString($txt, $font, $sBrush, ($px+1), ($py+1)) }
            $g.DrawString($txt, $font, $tBrush, $px, $py)

            $hIcon = $bmp.GetHicon()
            $Global:State.LastHIcon = $hIcon
            $icon  = [System.Drawing.Icon]::FromHandle($hIcon)

            foreach ($obj in @($g, $bmp, $pen, $fill, $tBrush, $sBrush, $font)) { $obj.Dispose() }
            return $icon
        } catch { return [System.Drawing.SystemIcons]::Application }
    }

    # ==========================================================================
    # 5. UI 갱신 (트레이 아이콘 + 툴팁)
    # ==========================================================================
    function Refresh-UIElements {
        if (-not $script:NotifyIcon) { return }
        $pct     = $Global:State.Remaining5HourPercent
        $risk    = $Global:State.RiskLevel
        $script:NotifyIcon.Icon = New-BatteryIcon -Percent $pct -RiskLevel $risk
        $tip = "Gemini 5h $pct%($($Global:State.Short5HourRemTimeStr)) | 주간 $($Global:State.RemainingWeeklyPercent)%"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:NotifyIcon.Text = $tip
    }

    # ==========================================================================
    # 6. [핵심] 백그라운드 증분 스캔 런스페이스
    #    - DB 파일 크기 추정 완전 제거
    #    - 변경된 파일만 재처리 (증분 스캔)
    #    - 파일 전체가 아닌 추가된 바이트만 읽기
    #    - GC::Collect 제거
    # ==========================================================================
    function Start-BackgroundScanRunspace {
        if ($Global:State.IsScanning) { return }
        $Global:State.IsScanning = $true

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable("SyncState",  $Global:State)
        $rs.SessionStateProxy.SetVariable("SyncConfig", $Global:Config)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        $scanBlock = {
            try {
                $now       = [DateTime]::Now
                $today     = [DateTime]::Today
                $start5h   = $now.AddHours(-5)
                $start7d   = $today.AddDays(-7)

                # 오버라이드 5시간 리셋 윈도우
                $is5hOverride    = $false
                $target5hReset   = [DateTime]::MinValue
                if ($null -ne $SyncConfig.override5HourRemainingMinutes) {
                    $remMins       = [int]$SyncConfig.override5HourRemainingMinutes
                    $target5hReset = $now.AddMinutes($remMins)
                    $start5h       = $target5hReset.AddHours(-5)
                    $is5hOverride  = $true
                }

                # 토큰 집계 변수
                $tokensToday      = 0L
                $tokens5h         = 0L
                $requestsToday    = 0
                $firstActivity    = [DateTime]::MaxValue

                # =============================================================
                # DB 파일 크기 기반 토큰 추정 (증분: 전 스캔 대비 증가분만 계산)
                # tokensPerKB: 설정에서 조정 가능 (기본 12, 실측값에 따라 보정)
                # =============================================================
                $convDir  = [System.IO.Path]::Combine($env:USERPROFILE, ".gemini", "antigravity", "conversations")
                $tokPerKB = if ($SyncConfig.ContainsKey('tokensPerKB') -and $SyncConfig.tokensPerKB -gt 0) {
                    [long]$SyncConfig.tokensPerKB
                } else { 12L }

                if ([System.IO.Directory]::Exists($convDir)) {
                    $dbFiles = [System.IO.Directory]::EnumerateFiles($convDir, "*.db")
                    foreach ($dbPath in $dbFiles) {
                        try {
                            $dbInfo = New-Object System.IO.FileInfo($dbPath)
                            $dbLW   = $dbInfo.LastWriteTime
                            if ($dbLW -lt $start7d) { continue }

                            $dbKey     = $dbPath
                            $prevSizeKB = 0L
                            if ($SyncState.FileOffsetCache.ContainsKey($dbKey)) {
                                $prevSizeKB = $SyncState.FileOffsetCache[$dbKey]
                            }
                            $curSizeKB = [long]($dbInfo.Length / 1024)

                            # 이전 누적 토큰 캐시 읽기
                            $cachedTotal = 0L
                            if ($SyncState.FileTokenCache.ContainsKey($dbKey)) {
                                $cachedTotal = $SyncState.FileTokenCache[$dbKey]
                            }

                            # 새 토큰 합계 계산 (증분 방식)
                            $newTotal = if ($prevSizeKB -eq 0L) {
                                # 첫 스캔: 오늘 수정된 파일만 전체 크기 반영
                                if ($dbLW -ge $today) { $curSizeKB * $tokPerKB } else { 0L }
                            } elseif ($curSizeKB -gt $prevSizeKB) {
                                # 파일이 커진 경우: 이전 누적 + 증분
                                $cachedTotal + (($curSizeKB - $prevSizeKB) * $tokPerKB)
                            } else {
                                # 파일 크기 변화 없음: 캐시된 누적값 그대로 유지
                                $cachedTotal
                            }

                            # 캐시 업데이트 (항상)
                            $SyncState.FileOffsetCache[$dbKey] = $curSizeKB
                            $SyncState.FileTokenCache[$dbKey]  = $newTotal

                            # 토큰이 0이면 집계 생략
                            if ($newTotal -le 0) { continue }

                            # ✅ 오늘 활동 집계 (파일 변화 여부와 무관하게 누적 합산)
                            if ($dbLW -ge $today) {
                                $tokensToday += $newTotal
                                if ($curSizeKB -gt $prevSizeKB) {
                                    $requestsToday += [math]::Max(1, [int](($curSizeKB - $prevSizeKB) / 8))
                                }
                                if ($dbLW -lt $firstActivity) { $firstActivity = $dbLW }
                            }

                            # ✅ 5시간 롤링 집계 (최근 5시간 내 수정된 파일)
                            if ($dbLW -ge $start5h) {
                                $tokens5h += $newTotal
                            }
                        } catch {}
                    }
                }


                # 5시간 리셋 문자열 계산
                if ($is5hOverride) {
                    $spanMins = [int]($target5hReset - $now).TotalMinutes
                    $hh = [math]::Floor($spanMins / 60); $mm = $spanMins % 60
                    $SyncState.TimeUntil5HourResetStr = "[수동] $($target5hReset.ToString('HH:mm')) 복구 예정 ($($hh)h $($mm)m 남음)"
                    $SyncState.Short5HourRemTimeStr   = "$($hh)h $($mm)m 남음"
                } elseif ($firstActivity -lt [DateTime]::MaxValue) {
                    $expiry5h = $firstActivity.AddHours(5)
                    if ($now -ge $expiry5h) {
                        $SyncState.TimeUntil5HourResetStr = $firstActivity.ToString("HH:mm") + " 첫 사용 → 5h 경과, 쿼터 복구 완료"
                        $SyncState.Short5HourRemTimeStr   = "복구완료"
                    } else {
                        $span5h = $expiry5h - $now
                        $SyncState.TimeUntil5HourResetStr = $firstActivity.ToString("HH:mm") + " 첫 사용 → " + $expiry5h.ToString("HH:mm") + " 복구 (" + $span5h.Hours + "h " + $span5h.Minutes + "m 남음)"
                        $SyncState.Short5HourRemTimeStr   = $span5h.Hours.ToString() + "h " + $span5h.Minutes.ToString() + "m 남음"
                    }
                } else {
                    $SyncState.TimeUntil5HourResetStr = "오늘 사용 기록 없음"
                    $SyncState.Short5HourRemTimeStr   = "대기 중"
                }

                # 주간 리셋 문자열 계산
                if ($null -ne $SyncConfig.overrideWeeklyRemainingHours) {
                    $wh   = [int]$SyncConfig.overrideWeeklyRemainingHours
                    $weta = $now.AddHours($wh)
                    $SyncState.TimeUntilWeeklyResetStr = "[수동] " + $weta.ToString("MM/dd HH:mm") + " 리셋 (" + $wh + "h 남음)"
                } else {
                    $resetDow  = $SyncConfig.weeklyResetDay
                    $resetHour = $SyncConfig.weeklyResetHour
                    $base      = (Get-Date -Hour $resetHour -Minute 0 -Second 0 -Millisecond 0)
                    $curDow    = [int]$now.DayOfWeek
                    $du        = ($resetDow - $curDow + 7) % 7
                    if ($du -eq 0 -and $now -ge $base) { $du = 7 }
                    $nextReset = $base.AddDays($du)
                    $wspan     = $nextReset - $now
                    $dn        = @("일","월","화","수","목","금","토")
                    $SyncState.TimeUntilWeeklyResetStr = "매주 " + $dn[$resetDow % 7] + "요일 " + $resetHour + ":00 (" + $wspan.Days + "일 " + $wspan.Hours + "h 남음)"
                }

                # % 계산
                $max5h   = [long]$SyncConfig.rolling5HourQuotaTokens
                $rem5h   = [math]::Max(0L, $max5h - $tokens5h)
                $p5h     = [int][math]::Floor($rem5h / $max5h * 100)
                if ($tokens5h -gt 0 -and $p5h -ge 100) { $p5h = 99 }

                $maxWk   = [long]$SyncConfig.weeklyQuotaTokens
                $prevWk  = [long]$SyncConfig.weeklyPrevUsedTokens   # 사용자 설정 이전 누적
                $remWk   = [math]::Max(0L, $maxWk - $tokensToday - $prevWk)
                $pWk     = [int][math]::Floor($remWk / $maxWk * 100)
                if (($tokensToday + $prevWk) -gt 0 -and $pWk -ge 100) { $pWk = 99 }

                $maxD    = [long]$SyncConfig.dailyQuotaTokens
                $remD    = [math]::Max(0L, $maxD - $tokensToday)
                $pD      = [int][math]::Floor($remD / $maxD * 100)

                # Risk Level
                $risk = "GREEN"
                if ($p5h -le 10 -or $pWk -le 10) { $risk = "RED" }
                elseif ($p5h -le 25 -or $pWk -le 25) { $risk = "YELLOW" }

                # 상태 업데이트 (원자적)
                $SyncState.TokensUsedToday        = $tokensToday
                $SyncState.TokensUsed5Hours        = $tokens5h
                $SyncState.RequestCountToday       = $requestsToday
                $SyncState.Remaining5HourPercent   = $p5h
                $SyncState.RemainingWeeklyPercent  = $pWk
                $SyncState.RemainingDailyPercent   = $pD
                $SyncState.FirstTokenTimeToday     = if ($firstActivity -lt [DateTime]::MaxValue) { $firstActivity } else { [DateTime]::MinValue }
                $SyncState.RiskLevel               = $risk
                $SyncState.LastCheckTime           = $now

                # daily_usage.json 저장 (값이 변경되었을 때만)
                if ($tokensToday -ne $SyncState.LastSavedDailyTokens) {
                    try {
                        $histFile  = $SyncConfig.HistoryFile
                        $todayKey  = $now.ToString("yyyy-MM-dd")
                        $cutoffKey = $now.AddDays(-30).ToString("yyyy-MM-dd")
                        $histObj   = [ordered]@{}

                        if ([System.IO.File]::Exists($histFile)) {
                            try {
                                $raw = [System.IO.File]::ReadAllText($histFile)
                                $parsed = $raw | ConvertFrom-Json
                                foreach ($pr in $parsed.PSObject.Properties) {
                                    # 30일 이상 오래된 항목 자동 제거
                                    if ($pr.Name -ge $cutoffKey) {
                                        $histObj[$pr.Name] = $pr.Value
                                    }
                                }
                            } catch {}
                        }

                        $histObj[$todayKey] = [pscustomobject]@{
                            Tokens  = $tokensToday
                            TPM     = 0
                            Updated = $now.ToString("HH:mm:ss")
                        }
                        $jsonOut = ($histObj | ConvertTo-Json -Depth 4)
                        [System.IO.File]::WriteAllText($histFile, $jsonOut, [System.Text.Encoding]::UTF8)
                        $SyncState.LastSavedDailyTokens = $tokensToday
                    } catch {}
                }

            } finally {
                $SyncState.IsScanning = $false
            }
        }

        $null = $ps.AddScript($scanBlock)
        $asyncResult = $ps.BeginInvoke()

        # 완료 감지 타이머 (100ms 폴링)
        $cleanTimer = New-Object System.Windows.Forms.Timer
        $cleanTimer.Interval = 100
        $cleanTimer.Add_Tick({
            if ($asyncResult.IsCompleted) {
                $cleanTimer.Stop(); $cleanTimer.Dispose()
                try { $ps.EndInvoke($asyncResult) } catch {}
                try { $ps.Dispose()               } catch {}
                try { $rs.Close(); $rs.Dispose()  } catch {}
                Refresh-UIElements
            }
        })
        $cleanTimer.Start()
    }

    # ==========================================================================
    # 7. 현황 창
    # ==========================================================================
    function Show-StatusDialog {
        Start-BackgroundScanRunspace   # 창 열 때마다 즉시 최신 스캔

        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor — 실시간 현황"
        $f.Size = New-Object System.Drawing.Size(580, 480)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true; $tb.ReadOnly = $true
        $tb.WordWrap = $false
        $tb.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $tb.Font = New-Object System.Drawing.Font("Consolas", 10)
        $tb.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 40)
        $tb.ForeColor = [System.Drawing.Color]::FromArgb(220, 230, 240)
        $tb.Location = New-Object System.Drawing.Point(12, 12)
        $tb.Size = New-Object System.Drawing.Size(544, 390)

        $st = $Global:State
        $cfg = $Global:Config

        $rem5hTok  = [math]::Max(0, $cfg.rolling5HourQuotaTokens - $st.TokensUsed5Hours)
        $prevWk    = $cfg.weeklyPrevUsedTokens
        $remWkTok  = [math]::Max(0, $cfg.weeklyQuotaTokens - $st.TokensUsedToday - $prevWk)

        $lines = @(
            "══════════════════════════════════════════════════════",
            "        Gemini Token Monitor  — 실시간 현황",
            "══════════════════════════════════════════════════════",
            ("  갱신 시각  : " + $(if ($st.LastCheckTime -gt [DateTime]::MinValue) { $st.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "스캔 중..." })),
            "",
            "── 📊 쿼터 잔여 ─────────────────────────────────────",
            ("  오늘 소모   : " + $st.TokensUsedToday.ToString("#,##0") + " tokens  (요청 " + $st.RequestCountToday + "회)"),
            ("  ⚡ 5h 잔여  : " + $st.Remaining5HourPercent + "%  (" + $rem5hTok.ToString("#,##0") + " / " + $cfg.rolling5HourQuotaTokens.ToString("#,##0") + " tok)"),
            ("  📅 주간 잔여: " + $st.RemainingWeeklyPercent + "%  (" + $remWkTok.ToString("#,##0") + " / " + $cfg.weeklyQuotaTokens.ToString("#,##0") + " tok)"),
            $(if ($prevWk -gt 0) { "      (주간: 이전 누적 오프셋 " + $prevWk.ToString("#,##0") + " tok 포함)" } else { "" }),
            "",
            "── ⏰ 리셋 카운트다운 ──────────────────────────────",
            ("  ⚡ 5h  복구 : " + $st.TimeUntil5HourResetStr),
            ("  📅 주간 리셋: " + $st.TimeUntilWeeklyResetStr),
            ("  🌙 일일 리셋: 자정 (00:00) — 잔여 " + $st.RemainingDailyPercent + "% (" + $st.TokensUsedToday.ToString("#,##0") + "/" + $cfg.dailyQuotaTokens.ToString("#,##0") + " tok)"),
            "",
            "── 🚦 위험도 ────────────────────────────────────────",
            ("  상태      : " + $(switch ($st.RiskLevel) { "RED" {"🔴 위험 — 쿼터 소진 임박"} "YELLOW" {"🟡 주의 — 25% 미만 잔여"} default {"🟢 정상 — 안전"} })),
            "══════════════════════════════════════════════════════"
        )

        $tb.Text = ($lines | Where-Object { $null -ne $_ }) -join "`r`n"
        $f.Controls.Add($tb)

        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = "확인"
        $btnOK.Location = New-Object System.Drawing.Point(460, 415)
        $btnOK.Size = New-Object System.Drawing.Size(90, 30)
        $btnOK.ForeColor = [System.Drawing.Color]::White
        $btnOK.BackColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
        $btnOK.FlatStyle = "Flat"
        $btnOK.Add_Click({ $f.Close() })
        $f.Controls.Add($btnOK)
        $f.ShowDialog()
    }

    # ==========================================================================
    # 8. 설정 창 (weeklyPrevUsedTokens, checkIntervalSeconds 필드 추가)
    # ==========================================================================
    function Show-SettingsDialog {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor — 설정"
        $f.Size = New-Object System.Drawing.Size(520, 640)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        function Add-Label { param($form,$text,$x,$y,$bold=$false)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $text; $l.ForeColor = [System.Drawing.Color]::White
            $l.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5, $(if ($bold) {[System.Drawing.FontStyle]::Bold} else {[System.Drawing.FontStyle]::Regular}))
            $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
            $form.Controls.Add($l); return $l
        }
        function Add-Input { param($form,$x,$y,$w,$val)
            $t = New-Object System.Windows.Forms.TextBox
            $t.Text = "$val"; $t.Location = New-Object System.Drawing.Point($x, $y)
            $t.Size = New-Object System.Drawing.Size($w, 24)
            $form.Controls.Add($t); return $t
        }

        Add-Label $f "📅 주간 초기화 요일 (0=일~6=토):" 20 15
        $cmbDay = New-Object System.Windows.Forms.ComboBox
        $cmbDay.DropDownStyle = "DropDownList"; $cmbDay.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $cmbDay.Items.AddRange(@("일요일","월요일","화요일","수요일","목요일","금요일","토요일"))
        $idx = [int]$Global:Config.weeklyResetDay
        $cmbDay.SelectedIndex = if ($idx -ge 0 -and $idx -le 6) { $idx } else { 1 }
        $cmbDay.Location = New-Object System.Drawing.Point(20, 38); $cmbDay.Size = New-Object System.Drawing.Size(180, 24)
        $f.Controls.Add($cmbDay)

        Add-Label $f "⏰ 초기화 시각 (0~23):" 220 15
        $txtHour = Add-Input $f 220 38 120 $Global:Config.weeklyResetHour

        Add-Label $f "⚡ 5시간 롤링 쿼터 (tokens):" 20 80 $true
        $txt5hQ = Add-Input $f 20 100 450 $Global:Config.rolling5HourQuotaTokens

        Add-Label $f "📅 주간 롤링 쿼터 (tokens):" 20 140 $true
        $txtWkQ = Add-Input $f 20 160 450 $Global:Config.weeklyQuotaTokens

        Add-Label $f "📦 주간: 이전 누적 사용량 오프셋 (tokens, 기본 0):" 20 200 $true
        $l2 = New-Object System.Windows.Forms.Label
        $l2.Text = "이전 주의 사용량이 쌓였다면 여기에 입력하세요 (공식 Gemini UI에서 확인)."
        $l2.ForeColor = [System.Drawing.Color]::Gray; $l2.Font = New-Object System.Drawing.Font("맑은 고딕", 8.5)
        $l2.Location = New-Object System.Drawing.Point(20, 220); $l2.AutoSize = $true; $f.Controls.Add($l2)
        $txtPrevWk = Add-Input $f 20 240 450 $Global:Config.weeklyPrevUsedTokens

        Add-Label $f "🔄 갱신 주기 (초, 기본 60):" 20 280
        $txtInterval = Add-Input $f 20 300 200 $Global:Config.checkIntervalSeconds

        Add-Label $f "⚡ 5h 초기화 남은 시간 (분 단위, 비워두면 자동):" 20 340
        $txt5hRem = Add-Input $f 20 360 450 $(if ($null -ne $Global:Config.override5HourRemainingMinutes) { $Global:Config.override5HourRemainingMinutes } else { "" })

        Add-Label $f "📅 주간 초기화 남은 시간 (시간 단위, 비워두면 자동):" 20 400
        $txtWkRem = Add-Input $f 20 420 450 $(if ($null -ne $Global:Config.overrideWeeklyRemainingHours) { $Global:Config.overrideWeeklyRemainingHours } else { "" })

        Add-Label $f "📐 DB 크기 → 토큰 비율 (tok/KB, 기본 12):" 20 455
        $l3 = New-Object System.Windows.Forms.Label
        $l3.Text = "공식 Gemini % 기반으로 역산 보정 후 맞는 값으로 조정하세요."
        $l3.ForeColor = [System.Drawing.Color]::Gray; $l3.Font = New-Object System.Drawing.Font("맑은 고딕", 8.5)
        $l3.Location = New-Object System.Drawing.Point(20, 473); $l3.AutoSize = $true; $f.Controls.Add($l3)
        $txtTokPerKB = Add-Input $f 20 492 200 $Global:Config.tokensPerKB

        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text = "저장 및 즉시 갱신"
        $btnSave.Font = New-Object System.Drawing.Font("맑은 고딕", 10, [System.Drawing.FontStyle]::Bold)
        $btnSave.Location = New-Object System.Drawing.Point(300, 540)
        $btnSave.Size = New-Object System.Drawing.Size(165, 36)
        $btnSave.ForeColor = [System.Drawing.Color]::White
        $btnSave.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        $btnSave.FlatStyle = "Flat"
        $btnSave.Add_Click({
            $Global:Config.weeklyResetDay   = $cmbDay.SelectedIndex
            try { $Global:Config.weeklyResetHour = [int]$txtHour.Text.Trim() } catch {}

            try { $Global:Config.rolling5HourQuotaTokens = [long]$txt5hQ.Text.Trim()  } catch {}
            try { $Global:Config.weeklyQuotaTokens       = [long]$txtWkQ.Text.Trim()  } catch {}
            try { $Global:Config.weeklyPrevUsedTokens    = [long]$txtPrevWk.Text.Trim() } catch {}
            try { $Global:Config.checkIntervalSeconds    = [int]$txtInterval.Text.Trim() } catch {}
            try { $Global:Config.tokensPerKB             = [int]$txtTokPerKB.Text.Trim() } catch {}

            $v5h = $txt5hRem.Text.Trim()
            $Global:Config.override5HourRemainingMinutes = if ($v5h -ne "") { try { [int]$v5h } catch { $null } } else { $null }
            $vWk = $txtWkRem.Text.Trim()
            $Global:Config.overrideWeeklyRemainingHours  = if ($vWk -ne "") { try { [int]$vWk } catch { $null } } else { $null }

            # config.json 저장
            try {
                $raw = if ([System.IO.File]::Exists($Global:Config.ConfigFile)) {
                    [System.IO.File]::ReadAllText($Global:Config.ConfigFile) | ConvertFrom-Json
                } else { [pscustomobject]@{} }

                $raw | Add-Member -Force NotePropertyName weeklyResetDay              -NotePropertyValue $Global:Config.weeklyResetDay
                $raw | Add-Member -Force NotePropertyName weeklyResetHour             -NotePropertyValue $Global:Config.weeklyResetHour
                $raw | Add-Member -Force NotePropertyName rolling5HourQuotaTokens     -NotePropertyValue $Global:Config.rolling5HourQuotaTokens
                $raw | Add-Member -Force NotePropertyName weeklyQuotaTokens           -NotePropertyValue $Global:Config.weeklyQuotaTokens
                $raw | Add-Member -Force NotePropertyName weeklyPrevUsedTokens        -NotePropertyValue $Global:Config.weeklyPrevUsedTokens
                $raw | Add-Member -Force NotePropertyName tokensPerKB                  -NotePropertyValue $Global:Config.tokensPerKB
                $raw | Add-Member -Force NotePropertyName checkIntervalSeconds        -NotePropertyValue $Global:Config.checkIntervalSeconds
                $raw | Add-Member -Force NotePropertyName override5HourRemainingMinutes -NotePropertyValue $Global:Config.override5HourRemainingMinutes
                $raw | Add-Member -Force NotePropertyName overrideWeeklyRemainingHours  -NotePropertyValue $Global:Config.overrideWeeklyRemainingHours

                $cfgJson = ($raw | ConvertTo-Json -Depth 5)
                [System.IO.File]::WriteAllText($Global:Config.ConfigFile, $cfgJson, [System.Text.Encoding]::UTF8)
            } catch {}

            # 타이머 간격 즉시 반영
            if ($script:MainTimer) {
                $script:MainTimer.Interval = [math]::Max(10, $Global:Config.checkIntervalSeconds) * 1000
            }

            # 오프셋 캐시 리셋 (쿼터 변경 시 전체 재계산)
            $Global:State.FileOffsetCache.Clear()
            $Global:State.FileTokenCache.Clear()
            $Global:State.LastSavedDailyTokens = -1

            Start-BackgroundScanRunspace
            [System.Windows.Forms.MessageBox]::Show("설정이 저장되었습니다!", "완료", "OK", "Information")
            $f.Close()
        })
        $f.Controls.Add($btnSave)
        $f.ShowDialog()
    }

    # ==========================================================================
    # 9. NotifyIcon 트레이 초기화
    # ==========================================================================
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = New-BatteryIcon -Percent $Global:State.Remaining5HourPercent -RiskLevel "GREEN"
    $script:NotifyIcon.Text = "Gemini Token Monitor"
    $script:NotifyIcon.Visible = $true

    Refresh-UIElements

    $menu     = New-Object System.Windows.Forms.ContextMenuStrip
    $mStatus  = $menu.Items.Add("📊 현 상태 보기")
    $mStatus.Add_Click({ Show-StatusDialog })
    $mRefresh = $menu.Items.Add("🔄 지금 갱신")
    $mRefresh.Add_Click({ Start-BackgroundScanRunspace })
    $menu.Items.Add("-") | Out-Null
    $mSettings = $menu.Items.Add("⚙️ 설정")
    $mSettings.Add_Click({ Show-SettingsDialog })
    $menu.Items.Add("-") | Out-Null
    $mExit = $menu.Items.Add("❌ 종료")
    $mExit.Add_Click({
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.Add_DoubleClick({ Show-StatusDialog })

    # ==========================================================================
    # 10. 메인 폴링 타이머
    # ==========================================================================
    $script:MainTimer = New-Object System.Windows.Forms.Timer
    $script:MainTimer.Interval = [math]::Max(10, $Global:Config.checkIntervalSeconds) * 1000
    $script:MainTimer.Add_Tick({ Start-BackgroundScanRunspace })
    $script:MainTimer.Start()

    # 시작 즉시 1회 스캔
    $startTimer = New-Object System.Windows.Forms.Timer
    $startTimer.Interval = 50
    $startTimer.Add_Tick({
        $startTimer.Stop(); $startTimer.Dispose()
        Start-BackgroundScanRunspace
    })
    $startTimer.Start()

    Write-Log "v2.0 증분 스캔 엔진 구동 완료 (갱신: $($Global:Config.checkIntervalSeconds)초)"

    # ==========================================================================
    # 11. 메시지 루프
    # ==========================================================================
    $appCtx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($appCtx)

} catch {
    Write-Log "치명적 오류: $($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show("오류 발생:`n$($_.Exception.Message)", "Gemini Token Monitor", "OK", "Error")
}
