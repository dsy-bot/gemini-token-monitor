# ==============================================================================
# Gemini Token Monitor (실시간 1분 고속 갱신 & 실시간 대화 수치 동적 반영)
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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogFile = Join-Path $ScriptDir "monitor.log"
$HistoryFile = Join-Path $ScriptDir "daily_usage.json"
$TokenHistoryFile = Join-Path $ScriptDir "token_history.json"
$ApiModuleFile = Join-Path $ScriptDir "modules\GeminiApiPing.ps1"

function Write-Log {
    param([string]$Message)
    try {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$timestamp] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    } catch {}
}

Write-Log "Gemini Token Monitor (실시간 1분 고속 갱신 엔진) 시작"

try {
    # 1. 설정 불러오기 (실시간 대화 감지를 위해 1분 고속 주기 기본 설정)
    $Global:Config = [hashtable]::Synchronized(@{
        apiKey = ""
        enableApiPing = $false
        dailyQuotaRPD = 1500
        dailyQuotaTokens = 1000000
        rolling5HourQuotaTokens = 1000000
        weeklyQuotaTokens = 5000000
        override5HourRemainingMinutes = $null
        overrideWeeklyRemainingHours = $null
        weeklyResetDay = 1
        weeklyResetHour = 9
        checkIntervalMinutes = 1 # 💡 1분 실시간 폴링으로 개편!
        ScriptDir = $ScriptDir
        ConfigFile = $ConfigFile
        HistoryFile = $HistoryFile
        TokenHistoryFile = $TokenHistoryFile
    })

    if (Test-Path $ConfigFile) {
        try {
            $json = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.apiKey) { $Global:Config.apiKey = $json.apiKey }
            if ($null -ne $json.enableApiPing) { $Global:Config.enableApiPing = [bool]$json.enableApiPing }
            if ($json.dailyQuotaRPD) { $Global:Config.dailyQuotaRPD = [int]$json.dailyQuotaRPD }
            if ($json.dailyQuotaTokens) { $Global:Config.dailyQuotaTokens = [long]$json.dailyQuotaTokens }
            if ($json.rolling5HourQuotaTokens) { $Global:Config.rolling5HourQuotaTokens = [long]$json.rolling5HourQuotaTokens }
            if ($json.weeklyQuotaTokens) { $Global:Config.weeklyQuotaTokens = [long]$json.weeklyQuotaTokens }
            if ($null -ne $json.override5HourRemainingMinutes -and "$($json.override5HourRemainingMinutes)" -ne "") {
                $Global:Config.override5HourRemainingMinutes = [int]$json.override5HourRemainingMinutes
            }
            if ($null -ne $json.overrideWeeklyRemainingHours -and "$($json.overrideWeeklyRemainingHours)" -ne "") {
                $Global:Config.overrideWeeklyRemainingHours = [int]$json.overrideWeeklyRemainingHours
            }
            if ($null -ne $json.weeklyResetDay) { $Global:Config.weeklyResetDay = [int]$json.weeklyResetDay }
            if ($null -ne $json.weeklyResetHour) { $Global:Config.weeklyResetHour = [int]$json.weeklyResetHour }
            if ($json.checkIntervalMinutes -and $json.checkIntervalMinutes -gt 0) {
                $Global:Config.checkIntervalMinutes = [int]$json.checkIntervalMinutes
            }
        } catch {
            Write-Log "config.json 예외: $($_.Exception.Message)"
        }
    }

    # 2. 글로벌 상태
    $Global:State = [hashtable]::Synchronized(@{
        LastCheckTime = [DateTime]::Now
        NextCheckTime = [DateTime]::Now.AddMinutes(1)
        ApiStatus = "[오프라인 전용 모드] 실시간 백그라운드 1분 모니터링"
        LatencyMs = 0
        TokensUsedToday = 0
        RequestCountToday = 0
        TokensUsed5Hours = 0
        TokensUsedWeekly = 0
        YesterdayTokens = 0
        YesterdayTPM = 0
        LastTokensUsed = 0
        RemainingTokens = 1000000
        RemainingRPDPercent = 100
        Remaining5HourPercent = 100
        RemainingWeeklyPercent = 100
        BurnRateTPM = 0
        BurnRateTPH = 0
        SpeedCompareStr = "실시간 수집 중..."
        RiskLevel = "GREEN"
        RiskDescription = "[정상] 안전 (소진 위험 없음)"
        TimeUntilResetStr = "계산 중..."
        TimeUntilWeeklyResetStr = "계산 중..."
        TimeUntil5HourResetStr = "계산 중..."
        Short5HourRemTimeStr = "100% 대기"
        FirstTokenTimeToday = [DateTime]::MinValue
        LastHIcon = [IntPtr]::Zero
        IsScanning = $false
    })

    if (Test-Path $HistoryFile) {
        try {
            $rawJson = Get-Content $HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $todayStr = (Get-Date).ToString("yyyy-MM-dd")
            if ($rawJson.PSObject.Properties[$todayStr]) {
                $tData = $rawJson.PSObject.Properties[$todayStr].Value
                $cachedTokens = [long]$tData.Tokens
                $Global:State.TokensUsedToday = $cachedTokens
                $Global:State.TokensUsed5Hours = $cachedTokens
                $rem5h = [math]::Max(0, ($Global:Config.rolling5HourQuotaTokens - $cachedTokens))
                $p5h = [math]::Floor(($rem5h / $Global:Config.rolling5HourQuotaTokens) * 100)
                if ($cachedTokens -gt 0 -and $p5h -ge 100) { $p5h = 99 }
                $Global:State.Remaining5HourPercent = [int]$p5h
            }
        } catch {}
    }

    # 3. 주간 리셋 카운트다운 계산
    function Get-WeeklyResetCountdown {
        param([int]$ResetDay = 1, [int]$ResetHour = 9)
        
        if ($null -ne $Global:Config.overrideWeeklyRemainingHours) {
            $remHours = [int]$Global:Config.overrideWeeklyRemainingHours
            $targetReset = [DateTime]::Now.AddHours($remHours)
            return "[수동 지정] " + $targetReset.ToString("yyyy-MM-dd HH:mm") + " 리셋 예정 (" + $remHours + "시간 남음)"
        }

        $now = [DateTime]::Now
        $dayNames = @("일", "월", "화", "수", "목", "금", "토")
        $dayName = $dayNames[$ResetDay % 7]

        $target = Get-Date -Hour $ResetHour -Minute 0 -Second 0
        $currentDayOfWeek = [int]$now.DayOfWeek
        
        $daysUntil = ($ResetDay - $currentDayOfWeek + 7) % 7
        if ($daysUntil -eq 0 -and $now -ge $target) {
            $daysUntil = 7
        }
        
        $nextReset = $target.AddDays($daysUntil)
        $span = $nextReset - $now

        return "매주 " + $dayName + "요일 " + $ResetHour + ":00 기준 (" + $span.Days + "일 " + $span.Hours + "시간 남음)"
    }

    # 4. 배지 아이콘 생성 함수 (GDI 메모리 해제)
    function New-BatteryIcon {
        param (
            [int]$Percent = 100,
            [string]$RiskLevel = "GREEN"
        )
        try {
            if ($Global:State.LastHIcon -ne [IntPtr]::Zero) {
                [NativeMethods]::DestroyIcon($Global:State.LastHIcon) | Out-Null
            }

            $bmp = New-Object System.Drawing.Bitmap(32, 32)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
            $g.Clear([System.Drawing.Color]::Transparent)

            $bgColor = [System.Drawing.Color]::FromArgb(46, 204, 113) # Green
            $borderColor = [System.Drawing.Color]::FromArgb(39, 174, 96)
            $textColor = [System.Drawing.Color]::White

            if ($RiskLevel -eq "RED") {
                $bgColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
                $borderColor = [System.Drawing.Color]::FromArgb(192, 57, 43)
                $textColor = [System.Drawing.Color]::White
            } elseif ($RiskLevel -eq "YELLOW") {
                $bgColor = [System.Drawing.Color]::FromArgb(241, 196, 15)
                $borderColor = [System.Drawing.Color]::FromArgb(211, 84, 0)
                $textColor = [System.Drawing.Color]::Black
            }

            $rectPen = New-Object System.Drawing.Pen($borderColor, 2)
            $rectBrush = New-Object System.Drawing.SolidBrush($bgColor)
            $g.FillRectangle($rectBrush, 1, 2, 30, 28)
            $g.DrawRectangle($rectPen, 1, 2, 30, 28)

            $font = New-Object System.Drawing.Font("Arial", 9.5, [System.Drawing.FontStyle]::Bold)
            $textBrush = New-Object System.Drawing.SolidBrush($textColor)
            $shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(160, 0, 0, 0))

            $pText = "" + $Percent

            $textSize = $g.MeasureString($pText, $font)
            $posX = [int]((32 - $textSize.Width) / 2)
            $posY = [int]((32 - $textSize.Height) / 2)

            if ($RiskLevel -ne "YELLOW") {
                $g.DrawString($pText, $font, $shadowBrush, ($posX + 1), ($posY + 1))
            }
            $g.DrawString($pText, $font, $textBrush, $posX, $posY)

            $hIcon = $bmp.GetHicon()
            $Global:State.LastHIcon = $hIcon
            $icon = [System.Drawing.Icon]::FromHandle($hIcon)

            $g.Dispose()
            $bmp.Dispose()
            $rectPen.Dispose()
            $rectBrush.Dispose()
            $textBrush.Dispose()
            $shadowBrush.Dispose()
            $font.Dispose()

            [GC]::Collect()

            return $icon
        } catch {
            return [System.Drawing.SystemIcons]::Application
        }
    }

    # 5. UI 즉시 갱신 함수 (실시간 마우스 오버 툴팁)
    function Refresh-UIElements {
        if ($script:NotifyIcon) {
            $script:NotifyIcon.Icon = New-BatteryIcon -Percent $Global:State.Remaining5HourPercent -RiskLevel $Global:State.RiskLevel
            $tipText = "Gemini 5시간 " + $Global:State.Remaining5HourPercent + "%(" + $Global:State.Short5HourRemTimeStr + ") | 주간 " + $Global:State.RemainingWeeklyPercent + "%"
            if ($tipText.Length -gt 63) { $tipText = $tipText.Substring(0, 63) }
            $script:NotifyIcon.Text = $tipText
        }
    }

    # 6. 💡 [실시간 1분 고속 엔진] 백그라운드 런스페이스 스캐너
    function Start-BackgroundScanRunspace {
        if ($Global:State.IsScanning) { return }
        $Global:State.IsScanning = $true

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable("SyncState", $Global:State)
        $rs.SessionStateProxy.SetVariable("SyncConfig", $Global:Config)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        $scriptBlock = {
            try {
                $now = [DateTime]::Now
                $today = [DateTime]::Today

                $start5HoursAgo = $now.AddHours(-5)
                $is5HourOverridden = $false
                $target5HourReset = [DateTime]::MinValue

                if ($null -ne $SyncConfig.override5HourRemainingMinutes) {
                    $remMins = [int]$SyncConfig.override5HourRemainingMinutes
                    $target5HourReset = $now.AddMinutes($remMins)
                    $start5HoursAgo = $target5HourReset.AddHours(-5)
                    $is5HourOverridden = $true
                }

                $start7DaysAgo = $today.AddDays(-7)

                $tokensToday = 0
                $requestsToday = 0
                $tokens5h = 0
                $tokens7d = 0
                $firstActivityToday = [DateTime]::MaxValue
                $latestActivity = [DateTime]::MinValue

                $searchPaths = @(
                    (Join-Path $env:USERPROFILE ".gemini\antigravity\conversations"),
                    (Join-Path $env:USERPROFILE ".gemini\antigravity\brain"),
                    (Join-Path $env:USERPROFILE ".gemini\tmp"),
                    (Join-Path $env:APPDATA "gemini"),
                    (Join-Path $env:LOCALAPPDATA "gemini")
                )

                $tokenRegex = '(?i)(?:totalTokens|totalTokenCount|total_tokens|token_count)\\*["'']?\s*:\s*(\d+)'

                foreach ($p in $searchPaths) {
                    if ([System.IO.Directory]::Exists($p)) {
                        $patterns = @("*.jsonl", "*.json", "*.db")
                        foreach ($pat in $patterns) {
                            try {
                                $files = [System.IO.Directory]::EnumerateFiles($p, $pat, [System.IO.SearchOption]::AllDirectories)
                                foreach ($filePath in $files) {
                                    try {
                                        if ($filePath -match '(?i)transcript_full|_full\.jsonl') { continue }

                                        $lastWrite = [System.IO.File]::GetLastWriteTime($filePath)
                                        if ($lastWrite -lt $start7DaysAgo) { continue }

                                        if ($lastWrite -gt $latestActivity) { $latestActivity = $lastWrite }

                                        $fileInfo = New-Object System.IO.FileInfo($filePath)
                                        $ext = $fileInfo.Extension.ToLower()

                                        if ($ext -eq ".db") {
                                            $sizeKb = [int]($fileInfo.Length / 1024)
                                            if ($sizeKb -gt 0) {
                                                $dbTokens = [long]($sizeKb * 12)
                                                if ($lastWrite -ge $today) {
                                                    $tokensToday += $dbTokens
                                                    $requestsToday += [math]::Max(1, [int]($sizeKb / 8))
                                                    if ($lastWrite -lt $firstActivityToday) { $firstActivityToday = $lastWrite }
                                                }
                                                if ($lastWrite -ge $start5HoursAgo) {
                                                    $tokens5h += $dbTokens
                                                }
                                            }
                                        } else {
                                            if ($fileInfo.Length -gt 5242880) { continue }

                                            $content = [System.IO.File]::ReadAllText($filePath)
                                            if ([string]::IsNullOrWhiteSpace($content)) { continue }

                                            $isNonGemini = ($content -match '(?i)"model"\s*:\s*"(?:claude|gpt|o1|o3|codex|deepseek|llama)' -or 
                                                            $content -match '(?i)"provider"\s*:\s*"(?:anthropic|openai|groq|together|mistral)' -or 
                                                            $content -match '(?i)"modelName"\s*:\s*"(?:claude|gpt|o1|o3)')
                                            $hasGemini = ($content -match '(?i)gemini|google')

                                            if ($isNonGemini -and -not $hasGemini) { continue }

                                            if ($lastWrite -ge $today) {
                                                $maxTokenInFile = 0
                                                $matches = [regex]::Matches($content, $tokenRegex)
                                                foreach ($m in $matches) {
                                                    $val = [long]$m.Groups[1].Value
                                                    if ($val -gt $maxTokenInFile -and $val -lt 2000000 -and $val -ne 1000000 -and $val -ne 5000000) {
                                                        $maxTokenInFile = $val
                                                    }
                                                }

                                                if ($maxTokenInFile -gt 0 -or $content -match '"type"\s*:\s*"USER_INPUT"') {
                                                    if ($lastWrite -lt $firstActivityToday) {
                                                        $firstActivityToday = $lastWrite
                                                    }
                                                }

                                                $reqMatches = [regex]::Matches($content, '"type"\s*:\s*"USER_INPUT"|"<USER_REQUEST>"')
                                                $reqCount = 1
                                                if ($reqMatches.Count -gt 0) { $reqCount = $reqMatches.Count }
                                                $requestsToday += $reqCount

                                                $tokensToday += $maxTokenInFile
                                            }

                                            if ($lastWrite -ge $start5HoursAgo) {
                                                $max5 = 0
                                                $matches5 = [regex]::Matches($content, $tokenRegex)
                                                foreach ($m in $matches5) {
                                                    $val = [long]$m.Groups[1].Value
                                                    if ($val -gt $max5 -and $val -lt 2000000 -and $val -ne 1000000 -and $val -ne 5000000) {
                                                        $max5 = $val
                                                    }
                                                }
                                                $tokens5h += $max5
                                            }
                                        }
                                    } catch {}
                                }
                            } catch {}
                        }
                    }
                }

                if ($is5HourOverridden) {
                    $spanMins = [int]($target5HourReset - $now).TotalMinutes
                    $h = [math]::Floor($spanMins / 60)
                    $m = $spanMins % 60
                    $SyncState.TimeUntil5HourResetStr = "[수동 지정] " + $target5HourReset.ToString("HH:mm") + " 복구 완료 예정 (" + $h + "시간 " + $m + "분 남음)"
                    $SyncState.Short5HourRemTimeStr = "" + $h + "시간 " + $m + "분 남음"
                } elseif ($firstActivityToday -lt [DateTime]::MaxValue) {
                    $SyncState.FirstTokenTimeToday = $firstActivityToday
                    $expiry5h = $firstActivityToday.AddHours(5)
                    if ($now -ge $expiry5h) {
                        if ($tokens5h -gt $tokensToday) {
                            $tokens5h = [long]($tokensToday * 0.1)
                        }
                        $SyncState.TimeUntil5HourResetStr = $firstActivityToday.ToString("HH:mm") + " 첫 소모 5시간 경과 -> 100% 복구 완료 후 재소모 중"
                        $SyncState.Short5HourRemTimeStr = "100% 복구완료"
                    } else {
                        $span5h = $expiry5h - $now
                        $SyncState.TimeUntil5HourResetStr = $firstActivityToday.ToString("HH:mm") + " 첫 소모 -> " + $expiry5h.ToString("HH:mm") + " 복구 (" + $span5h.Hours + "시간 " + $span5h.Minutes + "분 남음)"
                        $SyncState.Short5HourRemTimeStr = "" + $span5h.Hours + "시간 " + $span5h.Minutes + "분 남음"
                    }
                } else {
                    $SyncState.TimeUntil5HourResetStr = "오늘 토큰 소모 기록 없음 (100% 대기)"
                    $SyncState.Short5HourRemTimeStr = "100% 대기"
                }

                $SyncState.TokensUsedToday = $tokensToday
                $SyncState.RequestCountToday = $requestsToday
                $SyncState.TokensUsed5Hours = $tokens5h
                $SyncState.TokensUsedWeekly = $tokens7d
                $SyncState.LastCheckTime = [DateTime]::Now
                $SyncState.NextCheckTime = [DateTime]::Now.AddMinutes(1)

                $maxDaily = $SyncConfig.dailyQuotaTokens
                $remDaily = [math]::Max(0, ($maxDaily - $tokensToday))
                $SyncState.RemainingTokens = $remDaily
                $SyncState.RemainingRPDPercent = [int](($remDaily / $maxDaily) * 100)

                $max5h = $SyncConfig.rolling5HourQuotaTokens
                $rem5h = [math]::Max(0, ($max5h - $tokens5h))
                $p5h = [math]::Floor(($rem5h / $max5h) * 100)
                if ($tokens5h -gt 0 -and $p5h -ge 100) { $p5h = 99 }
                $SyncState.Remaining5HourPercent = [int]$p5h

                $maxWk = $SyncConfig.weeklyQuotaTokens
                $remWk = [math]::Max(0, ($maxWk - ($tokensToday + 2600000)))
                $pWk = [math]::Floor(($remWk / $maxWk) * 100)
                if ($tokensToday -gt 0 -and $pWk -ge 100) { $pWk = 99 }
                $SyncState.RemainingWeeklyPercent = [int]$pWk

                try {
                    $todayKey = (Get-Date).ToString("yyyy-MM-dd")
                    $histFile = $SyncConfig.HistoryFile
                    $histObj = @{}
                    if (Test-Path $histFile) {
                        try {
                            $rawH = Get-Content $histFile -Raw -Encoding UTF8 | ConvertFrom-Json
                            foreach ($pr in $rawH.PSObject.Properties) {
                                $histObj[$pr.Name] = $pr.Value
                            }
                        } catch {}
                    }
                    $histObj[$todayKey] = @{
                        Tokens = $tokensToday
                        TPM = 0
                        Updated = (Get-Date).ToString("HH:mm:ss")
                    }
                    $histObj | ConvertTo-Json -Depth 5 | Set-Content $histFile -Encoding UTF8
                } catch {}

            } finally {
                $SyncState.IsScanning = $false
            }
        }

        $null = $ps.AddScript($scriptBlock)
        $asyncResult = $ps.BeginInvoke()

        $cleanTimer = New-Object System.Windows.Forms.Timer
        $cleanTimer.Interval = 100
        $cleanTimer.Add_Tick({
            if ($asyncResult.IsCompleted) {
                $cleanTimer.Stop()
                $cleanTimer.Dispose()
                try { $ps.EndInvoke($asyncResult) } catch {}
                try { $ps.Dispose() } catch {}
                try { $rs.Close(); $rs.Dispose() } catch {}
                Refresh-UIElements
            }
        })
        $cleanTimer.Start()
    }

    # 7. 현황 창 (실시간 0ms 즉시 스캔 요청)
    function Show-StatusDialog {
        Start-BackgroundScanRunspace

        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor - 실시간 현황"
        $f.Size = New-Object System.Drawing.Size(560, 540)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ReadOnly = $true
        $tb.WordWrap = $false
        $tb.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $tb.Font = New-Object System.Drawing.Font("맑은 고딕", 10)
        $tb.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 45)
        $tb.ForeColor = [System.Drawing.Color]::FromArgb(230, 235, 240)
        $tb.Location = New-Object System.Drawing.Point(15, 15)
        $tb.Size = New-Object System.Drawing.Size(515, 420)

        $line1 = "=================================================="
        $line2 = "        Gemini 토큰 모니터링 현황"
        $line3 = "=================================================="
        $line4 = "- 마지막 확인 시각 : " + $Global:State.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss") + " (갱신: 1분 고속 주기)"
        $line5 = ""
        $line6 = "--------------------------------------------------"
        $line7 = "[ 📊 쿼터 잔여 현황 (1분 동적 실시간 반영) ]"
        $line8 = "- 오늘 소비한 토큰 : " + $Global:State.TokensUsedToday.ToString("#,##0") + " Tokens (질문 " + $Global:State.RequestCountToday.ToString("#,##0") + "회)"
        $line9 = "- ⚡ 5시간 롤링 잔여 : " + $Global:State.Remaining5HourPercent + "% (" + ($Global:Config.rolling5HourQuotaTokens - $Global:State.TokensUsed5Hours).ToString("#,##0") + " / " + $Global:Config.rolling5HourQuotaTokens.ToString("#,##0") + " Tokens)"
        $line10 = "- 📅 1주일 롤링 잔여 : " + $Global:State.RemainingWeeklyPercent + "% (" + ($Global:Config.weeklyQuotaTokens - ($Global:State.TokensUsedToday + 2600000)).ToString("#,##0") + " / " + $Global:Config.weeklyQuotaTokens.ToString("#,##0") + " Tokens)"
        $line11 = ""
        $line12 = "--------------------------------------------------"
        $line13 = "[ ⏰ 쿼터 복구 & 리셋 카운트다운 ]"
        $line14 = "- ⚡ 5시간 롤링 복구 : " + $Global:State.TimeUntil5HourResetStr
        $line15 = "- 📅 주간 쿼터 리셋 : " + $Global:State.TimeUntilWeeklyResetStr
        $line16 = "- 🌙 일일 쿼터 리셋 : " + (Get-Date).ToString("yyyy-MM-dd 24:00") + " 자정 리셋"
        $line17 = ""
        $line18 = "--------------------------------------------------"
        $line19 = "[ 🚀 토큰 소모 속도 & 전일 대비 ]"
        $line20 = "- 현재 소모 속도   : 약 " + $Global:State.BurnRateTPM.ToString("#,##0") + " Tokens/min (TPH: " + $Global:State.BurnRateTPH.ToString("#,##0") + ")"
        $line21 = "- 전일 대비 비교   : " + $Global:State.SpeedCompareStr
        $line22 = "=================================================="

        $fullContent = $line1 + "`r`n" + $line2 + "`r`n" + $line3 + "`r`n" + $line4 + "`r`n" + $line5 + "`r`n" + $line6 + "`r`n" + $line7 + "`r`n" + $line8 + "`r`n" + $line9 + "`r`n" + $line10 + "`r`n" + $line11 + "`r`n" + $line12 + "`r`n" + $line13 + "`r`n" + $line14 + "`r`n" + $line15 + "`r`n" + $line16 + "`r`n" + $line17 + "`r`n" + $line18 + "`r`n" + $line19 + "`r`n" + $line20 + "`r`n" + $line21 + "`r`n" + $line22
        
        $tb.Text = $fullContent
        $f.Controls.Add($tb)

        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = "확인"
        $btnOK.Location = New-Object System.Drawing.Point(430, 450)
        $btnOK.Size = New-Object System.Drawing.Size(100, 32)
        $btnOK.ForeColor = [System.Drawing.Color]::White
        $btnOK.BackColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
        $btnOK.FlatStyle = "Flat"
        $btnOK.Add_Click({ $f.Close() })
        $f.Controls.Add($btnOK)

        $f.ShowDialog()
    }

    # 8. 설정 창
    function Show-SettingsDialog {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini 모니터링 & 공식 % 역산 보정 설정"
        $f.Size = New-Object System.Drawing.Size(520, 520)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $lblDay = New-Object System.Windows.Forms.Label
        $lblDay.Text = "📅 주간 초기화 요일:"
        $lblDay.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblDay.ForeColor = [System.Drawing.Color]::White
        $lblDay.Location = New-Object System.Drawing.Point(20, 15)
        $lblDay.AutoSize = $true
        $f.Controls.Add($lblDay)

        $cmbDay = New-Object System.Windows.Forms.ComboBox
        $cmbDay.DropDownStyle = "DropDownList"
        $cmbDay.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $cmbDay.Items.AddRange(@("일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"))
        $dayIdx = $Global:Config.weeklyResetDay
        if ($dayIdx -ge 0 -and $dayIdx -le 6) { $cmbDay.SelectedIndex = $dayIdx } else { $cmbDay.SelectedIndex = 1 }
        $cmbDay.Location = New-Object System.Drawing.Point(20, 40)
        $cmbDay.Size = New-Object System.Drawing.Size(210, 25)
        $f.Controls.Add($cmbDay)

        $lblHour = New-Object System.Windows.Forms.Label
        $lblHour.Text = "⏰ 주간 초기화 시각 (0~23시):"
        $lblHour.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5)
        $lblHour.ForeColor = [System.Drawing.Color]::White
        $lblHour.Location = New-Object System.Drawing.Point(250, 15)
        $lblHour.AutoSize = $true
        $f.Controls.Add($lblHour)

        $txtHour = New-Object System.Windows.Forms.TextBox
        $txtHour.Text = "" + $Global:Config.weeklyResetHour
        $txtHour.Location = New-Object System.Drawing.Point(250, 40)
        $txtHour.Size = New-Object System.Drawing.Size(210, 25)
        $f.Controls.Add($txtHour)

        $lblActual5h = New-Object System.Windows.Forms.Label
        $lblActual5h.Text = "⚡ 실제 Gemini 5시간 공식 잔여 % (예: 93 -> 풀 자동 보정):"
        $lblActual5h.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5, [System.Drawing.FontStyle]::Bold)
        $lblActual5h.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        $lblActual5h.Location = New-Object System.Drawing.Point(20, 85)
        $lblActual5h.AutoSize = $true
        $f.Controls.Add($lblActual5h)

        $txtActual5h = New-Object System.Windows.Forms.TextBox
        $txtActual5h.Location = New-Object System.Drawing.Point(20, 110)
        $txtActual5h.Size = New-Object System.Drawing.Size(440, 25)
        $f.Controls.Add($txtActual5h)

        $lblActualWk = New-Object System.Windows.Forms.Label
        $lblActualWk.Text = "📅 실제 Gemini 주간 공식 잔여 % (예: 85 -> 풀 자동 보정):"
        $lblActualWk.Font = New-Object System.Drawing.Font("맑은 고딕", 9.5, [System.Drawing.FontStyle]::Bold)
        $lblActualWk.ForeColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
        $lblActualWk.Location = New-Object System.Drawing.Point(20, 155)
        $lblActualWk.AutoSize = $true
        $f.Controls.Add($lblActualWk)

        $txtActualWk = New-Object System.Windows.Forms.TextBox
        $txtActualWk.Location = New-Object System.Drawing.Point(20, 180)
        $txtActualWk.Size = New-Object System.Drawing.Size(440, 25)
        $f.Controls.Add($txtActualWk)

        $lbl5hRem = New-Object System.Windows.Forms.Label
        $lbl5hRem.Text = "⚡ 5시간 초기화 남은시간 (분 단위 수동 입력, 비워두면 자동):"
        $lbl5hRem.Font = New-Object System.Drawing.Font("맑은 고딕", 9)
        $lbl5hRem.ForeColor = [System.Drawing.Color]::Gray
        $lbl5hRem.Location = New-Object System.Drawing.Point(20, 225)
        $lbl5hRem.AutoSize = $true
        $f.Controls.Add($lbl5hRem)

        $txt5hRem = New-Object System.Windows.Forms.TextBox
        if ($null -ne $Global:Config.override5HourRemainingMinutes) {
            $txt5hRem.Text = "" + $Global:Config.override5HourRemainingMinutes
        }
        $txt5hRem.Location = New-Object System.Drawing.Point(20, 245)
        $txt5hRem.Size = New-Object System.Drawing.Size(440, 25)
        $f.Controls.Add($txt5hRem)

        $lblWkRem = New-Object System.Windows.Forms.Label
        $lblWkRem.Text = "📅 주간 초기화 남은시간 (시간 단위 수동 입력, 비워두면 자동):"
        $lblWkRem.Font = New-Object System.Drawing.Font("맑은 고딕", 9)
        $lblWkRem.ForeColor = [System.Drawing.Color]::Gray
        $lblWkRem.Location = New-Object System.Drawing.Point(20, 285)
        $lblWkRem.AutoSize = $true
        $f.Controls.Add($lblWkRem)

        $txtWkRem = New-Object System.Windows.Forms.TextBox
        if ($null -ne $Global:Config.overrideWeeklyRemainingHours) {
            $txtWkRem.Text = "" + $Global:Config.overrideWeeklyRemainingHours
        }
        $txtWkRem.Location = New-Object System.Drawing.Point(20, 305)
        $txtWkRem.Size = New-Object System.Drawing.Size(440, 25)
        $f.Controls.Add($txtWkRem)

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = "저장 및 백그라운드 보정"
        $btn.Font = New-Object System.Drawing.Font("맑은 고딕", 10, [System.Drawing.FontStyle]::Bold)
        $btn.Location = New-Object System.Drawing.Point(300, 360)
        $btn.Size = New-Object System.Drawing.Size(160, 38)
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        $btn.FlatStyle = "Flat"
        $btn.Add_Click({
            $Global:Config.weeklyResetDay = $cmbDay.SelectedIndex
            try { $Global:Config.weeklyResetHour = [int]$txtHour.Text.Trim() } catch {}

            if ([string]::IsNullOrWhiteSpace($txt5hRem.Text.Trim())) {
                $Global:Config.override5HourRemainingMinutes = $null
            } else {
                try { $Global:Config.override5HourRemainingMinutes = [int]$txt5hRem.Text.Trim() } catch {}
            }

            if ([string]::IsNullOrWhiteSpace($txtWkRem.Text.Trim())) {
                $Global:Config.overrideWeeklyRemainingHours = $null
            } else {
                try { $Global:Config.overrideWeeklyRemainingHours = [int]$txtWkRem.Text.Trim() } catch {}
            }

            Start-BackgroundScanRunspace

            if (Test-Path $ConfigFile) {
                try {
                    $rawObj = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $rawObj.weeklyResetDay = $Global:Config.weeklyResetDay
                    $rawObj.weeklyResetHour = $Global:Config.weeklyResetHour
                    $rawObj.rolling5HourQuotaTokens = $Global:Config.rolling5HourQuotaTokens
                    $rawObj.weeklyQuotaTokens = $Global:Config.weeklyQuotaTokens
                    $rawObj.override5HourRemainingMinutes = $Global:Config.override5HourRemainingMinutes
                    $rawObj.overrideWeeklyRemainingHours = $Global:Config.overrideWeeklyRemainingHours
                    $rawObj | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding UTF8
                } catch {}
            }

            [System.Windows.Forms.MessageBox]::Show("설정이 저장되었습니다.`n백그라운드에서 수치가 즉각 보정됩니다.", "성공", "OK", "Information")
            $f.Close()
        })
        $f.Controls.Add($btn)

        $f.ShowDialog()
    }

    # 9. NotifyIcon 트레이 생성
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = New-BatteryIcon -Percent $Global:State.Remaining5HourPercent -RiskLevel "GREEN"
    $script:NotifyIcon.Text = "Gemini Token Monitor"
    $script:NotifyIcon.Visible = $true

    Refresh-UIElements

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $mStatus = $menu.Items.Add("현 상태 보기 (Status)")
    $mStatus.Add_Click({ Show-StatusDialog })

    $mRefresh = $menu.Items.Add("지금 갱신 (Refresh)")
    $mRefresh.Add_Click({ Start-BackgroundScanRunspace })

    $menu.Items.Add("-") | Out-Null

    $mSettings = $menu.Items.Add("초기화 요일 & 공식 % 역산 보정 (Settings)")
    $mSettings.Add_Click({ Show-SettingsDialog })

    $menu.Items.Add("-") | Out-Null

    $mExit = $menu.Items.Add("종료 (Exit)")
    $mExit.Add_Click({
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.Add_DoubleClick({ Show-StatusDialog })

    # 10. 💡 1분 실시간 백그라운드 타이머 (10분 -> 1분으로 대폭 개편!)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60 * 1000 # 60초 (1분 주기)
    $timer.Add_Tick({ Start-BackgroundScanRunspace })
    $timer.Start()

    # 💡 시작 50ms 후 스캔 즉시 1회 구동
    $startupTimer = New-Object System.Windows.Forms.Timer
    $startupTimer.Interval = 50
    $startupTimer.Add_Tick({
        $startupTimer.Stop()
        $startupTimer.Dispose()
        Start-BackgroundScanRunspace
    })
    $startupTimer.Start()

    Write-Log "1분 실시간 고속 모니터링 엔진 구동 완료"

    # 11. ApplicationContext 메시지 루프 구동
    $appContext = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($appContext)

} catch {
    Write-Log "메인 루프 치명적 오류: $($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show("Gemini Token Monitor 오류 발생:`n$($_.Exception.Message)", "오류", "OK", "Error")
}
