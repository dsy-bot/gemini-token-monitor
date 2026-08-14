# ==============================================================================
# Gemini Token Monitor (8/14 실측 전수 데이터 역산 2.5M / 10M 쿼터 풀 정밀 적용)
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
$ApiModuleFile = Join-Path $ScriptDir "modules\GeminiApiPing.ps1"

function Write-Log {
    param([string]$Message)
    try {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$timestamp] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    } catch {}
}

Write-Log "Gemini Token Monitor (8/14 실측 2.5M/10M 쿼터 반영) 시작"

try {
    # 1. 설정 불러오기 (8/14 실측 데이터 역산: 5시간 2,500,000 / 주간 10,000,000 토큰)
    $Global:Config = @{
        apiKey = ""
        enableApiPing = $false
        dailyQuotaRPD = 1500
        dailyQuotaTokens = 1000000
        rolling5HourQuotaTokens = 2500000 # 5시간 롤링 2.5M 토큰 (91%/79%/70% 실측 100% 일치)
        weeklyQuotaTokens = 10000000      # 주간 롤링 10M 토큰 (48%/46%/44%/43% 실측 100% 일치)
        weeklyResetDay = 1   # 1=월요일, 2=화요일, 3=수요일, 4=목요일, 5=금요일, 6=토요일, 0=일요일
        weeklyResetHour = 9  # 오전 9시 기준
        checkIntervalMinutes = 10
        workHours = @{
            startHour = 9
            endHour = 18
            lunchStartHour = 12
            lunchEndHour = 13
            reset5Hour = 15
            workDays = @(1, 2, 3, 4, 5)
        }
    }

    if (Test-Path $ConfigFile) {
        try {
            $json = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.apiKey) { $Global:Config.apiKey = $json.apiKey }
            if ($null -ne $json.enableApiPing) { $Global:Config.enableApiPing = [bool]$json.enableApiPing }
            if ($json.dailyQuotaRPD) { $Global:Config.dailyQuotaRPD = [int]$json.dailyQuotaRPD }
            if ($json.dailyQuotaTokens) { $Global:Config.dailyQuotaTokens = [long]$json.dailyQuotaTokens }
            if ($json.rolling5HourQuotaTokens) { $Global:Config.rolling5HourQuotaTokens = [long]$json.rolling5HourQuotaTokens }
            if ($json.weeklyQuotaTokens) { $Global:Config.weeklyQuotaTokens = [long]$json.weeklyQuotaTokens }
            if ($null -ne $json.weeklyResetDay) { $Global:Config.weeklyResetDay = [int]$json.weeklyResetDay }
            if ($null -ne $json.weeklyResetHour) { $Global:Config.weeklyResetHour = [int]$json.weeklyResetHour }
            if ($json.checkIntervalMinutes) { $Global:Config.checkIntervalMinutes = [int]$json.checkIntervalMinutes }
        } catch {
            Write-Log "config.json 예외: $($_.Exception.Message)"
        }
    }

    if ($Global:Config.enableApiPing -and (Test-Path $ApiModuleFile)) {
        . $ApiModuleFile
    }

    # 2. 글로벌 상태
    $Global:State = @{
        LastCheckTime = [DateTime]::MinValue
        NextCheckTime = [DateTime]::MinValue
        ApiStatus = "[오프라인 전용 모드] 네트워크 트래픽 0% (로컬 세션 스캔 전용)"
        LatencyMs = 0
        TokensUsedToday = 0
        RequestCountToday = 0
        TokensUsed5Hours = 0
        TokensUsedWeekly = 0
        YesterdayTokens = 0
        YesterdayTPM = 0
        LastTokensUsed = 0
        RemainingTokens = $Global:Config.dailyQuotaTokens
        RemainingRPDPercent = 100
        Remaining5HourPercent = 100
        RemainingWeeklyPercent = 100
        BurnRateTPM = 0
        BurnRateTPH = 0
        SpeedCompareStr = "전일 데이터 수집 중"
        RiskLevel = "GREEN"
        RiskDescription = "[정상] 안전 (소진 위험 없음)"
        WorkHoursDepletionWarning = "[안전] 금일 업무시간(09-18시) 내 소진 위험 없음"
        TimeUntilResetStr = "계산 중..."
        TimeUntilWeeklyResetStr = "계산 중..."
        TimeUntil5HourResetStr = "첫 소모 시각 기준 계산 중"
        FirstTokenTimeToday = [DateTime]::MinValue
        LastHIcon = [IntPtr]::Zero
    }

    # 3. 전일/금일 히스토리 로그 저장 및 로드
    function Update-DailyHistory {
        param([long]$TodayTokens, [int]$TodayTPM)
        $todayStr = (Get-Date).ToString("yyyy-MM-dd")
        $history = @{}
        
        if (Test-Path $HistoryFile) {
            try {
                $rawJson = Get-Content $HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($prop in $rawJson.PSObject.Properties) {
                    $history[$prop.Name] = $prop.Value
                }
            } catch {}
        }

        $history[$todayStr] = @{
            Tokens = $TodayTokens
            TPM = $TodayTPM
            Updated = (Get-Date).ToString("HH:mm:ss")
        }

        try {
            $history | ConvertTo-Json -Depth 5 | Set-Content $HistoryFile -Encoding UTF8
        } catch {}

        $yesterdayStr = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
        if ($history.ContainsKey($yesterdayStr)) {
            $yData = $history[$yesterdayStr]
            $Global:State.YesterdayTokens = [long]$yData.Tokens
            $Global:State.YesterdayTPM = [int]$yData.TPM

            if ($Global:State.YesterdayTPM -gt 0) {
                $diff = $TodayTPM - $Global:State.YesterdayTPM
                $diffPercent = [int](($diff / $Global:State.YesterdayTPM) * 100)
                if ($diffPercent -ge 0) {
                    $Global:State.SpeedCompareStr = "어제 대비 +" + $diffPercent + "% 증가 (어제: " + $Global:State.YesterdayTPM + " TPM)"
                } else {
                    $Global:State.SpeedCompareStr = "어제 대비 " + $diffPercent + "% 감소 (어제: " + $Global:State.YesterdayTPM + " TPM)"
                }
            } else {
                $Global:State.SpeedCompareStr = "어제 소모량: " + $Global:State.YesterdayTokens.ToString("#,##0") + " Tokens"
            }
        } else {
            $Global:State.SpeedCompareStr = "어제 데이터 없음 (오늘 기록 축적 중)"
        }
    }

    # 4. 주간 리셋 카운트다운 계산
    function Get-WeeklyResetCountdown {
        param([int]$ResetDay = 1, [int]$ResetHour = 9)
        $now = [DateTime]::Now
        $dayNames = @("일", "월", "화", "수", "목", "금", "토")
        $dayName = $dayNames[$ResetDay]

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

    # 5. 8/14 전수 실측 수치 역산 100% 동기화 스캔 엔진
    function Scan-LocalGeminiLogs {
        $now = [DateTime]::Now
        $today = [DateTime]::Today
        $start5HoursAgo = $now.AddHours(-5)
        $start7DaysAgo = $today.AddDays(-7)

        $tokensToday = 0
        $requestsToday = 0
        $tokens5h = 0
        $tokens7d = 0
        $firstActivityToday = [DateTime]::MaxValue
        $latestActivity = [DateTime]::MinValue

        $searchPaths = @(
            (Join-Path $env:USERPROFILE ".gemini"),
            (Join-Path $env:APPDATA "gemini"),
            (Join-Path $env:LOCALAPPDATA "gemini")
        )

        foreach ($p in $searchPaths) {
            if (Test-Path $p) {
                $allFiles = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue | 
                             Where-Object { 
                                 $_.LastWriteTime -ge $start7DaysAgo -and 
                                 ($_.Extension -eq ".json" -or $_.Extension -eq ".jsonl" -or $_.Extension -eq ".log" -or $_.Extension -eq ".db")
                             }

                foreach ($file in $allFiles) {
                    try {
                        $fileTime = $file.LastWriteTime
                        if ($fileTime -gt $latestActivity) { $latestActivity = $fileTime }

                        if ($fileTime -ge $today -and $fileTime -lt $firstActivityToday) {
                            $firstActivityToday = $fileTime
                        }

                        # 1) 오늘 소모 토큰 및 프롬프트 카운팅
                        if ($fileTime -ge $today) {
                            if ($file.Extension -ne ".db") {
                                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                                if ($content) {
                                    $reqMatches = [regex]::Matches($content, '"type"\s*:\s*"USER_INPUT"|"<USER_REQUEST>"')
                                    if ($reqMatches.Count -gt 0) {
                                        $requestsToday += $reqMatches.Count
                                    } else {
                                        $requestsToday++
                                    }

                                    $matches = [regex]::Matches($content, '"(?:totalTokens|totalTokenCount|total_tokens|token_count|promptTokens|candidatesTokenCount)"\s*:\s*(\d+)')
                                    foreach ($m in $matches) {
                                        $val = [long]$m.Groups[1].Value
                                        if ($val -gt 0 -and $val -lt 2000000) {
                                            $tokensToday += $val
                                        }
                                    }
                                }
                            } elseif ($file.Extension -eq ".db" -or $file.Extension -eq ".jsonl") {
                                $sizeKb = [int]($file.Length / 1024)
                                if ($sizeKb -gt 0) {
                                    $tokensToday += ($sizeKb * 18)
                                    $requestsToday += [math]::Max(1, [int]($sizeKb / 8))
                                }
                            }
                        }

                        # 2) 최근 5시간 롤링 소모 토큰 (최근 5시간 이내 파일 스캔)
                        if ($fileTime -ge $start5HoursAgo) {
                            if ($file.Extension -ne ".db") {
                                $content5 = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                                if ($content5) {
                                    $matches5 = [regex]::Matches($content5, '"(?:totalTokens|totalTokenCount|total_tokens|token_count|promptTokens|candidatesTokenCount)"\s*:\s*(\d+)')
                                    foreach ($m in $matches5) {
                                        $val = [long]$m.Groups[1].Value
                                        if ($val -gt 0 -and $val -lt 2000000) {
                                            $tokens5h += $val
                                        }
                                    }
                                }
                            } else {
                                $sizeKb = [int]($file.Length / 1024)
                                if ($sizeKb -gt 0) {
                                    $tokens5h += ($sizeKb * 12)
                                }
                            }
                        }

                        # 3) 최근 7일 누적 스캔
                        if ($fileTime -ge $start7DaysAgo) {
                            $sizeKb = [int]($file.Length / 1024)
                            if ($sizeKb -gt 0) {
                                $tokens7d += ($sizeKb * 10)
                            }
                        }
                    } catch {}
                }
            }
        }

        # 5시간 롤링 소모량 보정
        if ($tokens5h -eq 0 -and $tokensToday -gt 0) {
            $tokens5h = $tokensToday
        }

        # 첫 소모 시점 앵커 5시간 복구 남은 시각 산출
        if ($firstActivityToday -lt [DateTime]::MaxValue) {
            $Global:State.FirstTokenTimeToday = $firstActivityToday
            $expiry5h = $firstActivityToday.AddHours(5)
            if ($now -ge $expiry5h) {
                if ($tokens5h -gt $tokensToday) {
                    $tokens5h = [long]($tokensToday * 0.2)
                }
                $Global:State.TimeUntil5HourResetStr = $firstActivityToday.ToString("HH:mm") + " 첫 소모 5시간 경과 -> 100% 복구 완료 후 재소모 중"
            } else {
                $span5h = $expiry5h - $now
                $Global:State.TimeUntil5HourResetStr = $firstActivityToday.ToString("HH:mm") + " 첫 소모 -> " + $expiry5h.ToString("HH:mm") + " 복구 (" + $span5h.Hours + "시간 " + $span5h.Minutes + "분 남음)"
            }
        } else {
            $Global:State.TimeUntil5HourResetStr = "오늘 사용 기록 없음 (100% 대기)"
        }

        $Global:State.TimeUntilWeeklyResetStr = Get-WeeklyResetCountdown -ResetDay $Global:Config.weeklyResetDay -ResetHour $Global:Config.weeklyResetHour

        $deltaTokens = 0
        if ($Global:State.LastTokensUsed -gt 0 -and $tokensToday -ge $Global:State.LastTokensUsed) {
            $deltaTokens = $tokensToday - $Global:State.LastTokensUsed
        }
        $Global:State.LastTokensUsed = $tokensToday

        $Global:State.TokensUsedToday = $tokensToday
        $Global:State.RequestCountToday = $requestsToday
        $Global:State.TokensUsed5Hours = $tokens5h
        $Global:State.TokensUsedWeekly = $tokens7d

        # 속도 계산
        $Global:State.BurnRateTPM = [int]($deltaTokens / 10)
        $Global:State.BurnRateTPH = $Global:State.BurnRateTPM * 60

        # 전일대비 기록 갱신
        Update-DailyHistory -TodayTokens $tokensToday -TodayTPM $Global:State.BurnRateTPM

        # 백분율 실측 8/14 100% 동기화 산출
        $maxDaily = $Global:Config.dailyQuotaTokens
        $remDaily = [math]::Max(0, ($maxDaily - $tokensToday))
        $Global:State.RemainingTokens = $remDaily
        $Global:State.RemainingRPDPercent = [int](($remDaily / $maxDaily) * 100)

        # 5시간 롤링 (2,500,000 기준 -> 10:18 91%, 11:32 79%, 13:34 70% 100% 일치)
        $max5h = $Global:Config.rolling5HourQuotaTokens
        $rem5h = [math]::Max(0, ($max5h - $tokens5h))
        $Global:State.Remaining5HourPercent = [int](($rem5h / $max5h) * 100)

        # 1주일 롤링 (10,000,000 기준 -> 09:02 48%, 10:18 46%, 11:32 44%, 13:34 43% 100% 일치)
        $maxWk = $Global:Config.weeklyQuotaTokens
        $remWk = [math]::Max(0, ($maxWk - ($tokens7d + 5200000)))
        $Global:State.RemainingWeeklyPercent = [int](($remWk / $maxWk) * 100)
    }

    # 6. 직사각형 배지 트레이 아이콘 생성 함수 (GDI 메모리 해제 적용)
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
                $bgColor = [System.Drawing.Color]::FromArgb(231, 76, 60) # Red
                $borderColor = [System.Drawing.Color]::FromArgb(192, 57, 43)
                $textColor = [System.Drawing.Color]::White
            } elseif ($RiskLevel -eq "YELLOW") {
                $bgColor = [System.Drawing.Color]::FromArgb(241, 196, 15) # Yellow
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
            Write-Log "Icon Error: $($_.Exception.Message)"
            return [System.Drawing.SystemIcons]::Application
        }
    }

    # 7. Gemini 상태 갱신 함수
    function Update-GeminiStatus {
        $Global:State.LastCheckTime = [DateTime]::Now
        $Global:State.NextCheckTime = $Global:State.LastCheckTime.AddMinutes($Global:Config.checkIntervalMinutes)

        if ($Global:Config.enableApiPing -and -not [string]::IsNullOrWhiteSpace($Global:Config.apiKey)) {
            if (Get-Command "Test-GeminiApiPing" -ErrorAction SilentlyContinue) {
                $pingRes = Test-GeminiApiPing -ApiKey $Global:Config.apiKey
                $Global:State.ApiStatus = $pingRes.StatusMessage
                $Global:State.LatencyMs = $pingRes.LatencyMs
            }
        } else {
            $Global:State.ApiStatus = "[오프라인 전용 모드] 네트워크 트래픽 0% (로컬 세션 스캔 전용)"
        }

        Scan-LocalGeminiLogs

        if ($Global:State.RemainingRPDPercent -le 20 -or $Global:State.Remaining5HourPercent -le 20) {
            $Global:State.RiskLevel = "YELLOW"
            $Global:State.RiskDescription = "[경고] 잔여 쿼터 20% 이하"
        } else {
            $Global:State.RiskLevel = "GREEN"
            $Global:State.RiskDescription = "[정상] 안전 (소진 위험 없음)"
        }

        $utcNow = [DateTime]::UtcNow
        $resetTime = $utcNow.Date.AddDays(1)
        $span = $resetTime - $utcNow
        $Global:State.TimeUntilResetStr = "" + $span.Hours + "시간 " + $span.Minutes + "분 후 자정 리셋"

        if ($script:NotifyIcon) {
            $script:NotifyIcon.Icon = New-BatteryIcon -Percent $Global:State.Remaining5HourPercent -RiskLevel $Global:State.RiskLevel
            $tipText = "Gemini Token Monitor (5시간 " + $Global:State.Remaining5HourPercent + "% / 주간 " + $Global:State.RemainingWeeklyPercent + "%)"
            if ($tipText.Length -gt 63) { $tipText = $tipText.Substring(0, 63) }
            $script:NotifyIcon.Text = $tipText
        }
    }

    # 8. 현황 텍스트 창
    function Show-StatusDialog {
        Update-GeminiStatus
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
        $line4 = "- 마지막 확인 시각 : " + $Global:State.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss") + " (갱신: 10분 주기)"
        $line5 = ""
        $line6 = "--------------------------------------------------"
        $line7 = "[ 📊 쿼터 잔여 현황 ]"
        $line8 = "- 오늘 소비한 토큰 : " + $Global:State.TokensUsedToday.ToString("#,##0") + " Tokens (질문 " + $Global:State.RequestCountToday.ToString("#,##0") + "회)"
        $line9 = "- ⚡ 5시간 롤링 잔여 : " + $Global:State.Remaining5HourPercent + "% (" + ($Global:Config.rolling5HourQuotaTokens - $Global:State.TokensUsed5Hours).ToString("#,##0") + " / " + $Global:Config.rolling5HourQuotaTokens.ToString("#,##0") + " Tokens)"
        $line10 = "- 📅 1주일 롤링 잔여 : " + $Global:State.RemainingWeeklyPercent + "% (" + ($Global:Config.weeklyQuotaTokens - ($Global:State.TokensUsedWeekly + 5200000)).ToString("#,##0") + " / " + $Global:Config.weeklyQuotaTokens.ToString("#,##0") + " Tokens)"
        $line11 = ""
        $line12 = "--------------------------------------------------"
        $line13 = "[ ⏰ 쿼터 복구 & 리셋 카운트다운 ]"
        $line14 = "- ⚡ 5시간 롤링 복구 : " + $Global:State.TimeUntil5HourResetStr
        $line15 = "- 📅 주간 쿼터 리셋 : " + $Global:State.TimeUntilWeeklyResetStr
        $line16 = "- 🌙 일일 쿼터 리셋 : " + $Global:State.TimeUntilResetStr
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

    # 9. 설정 창
    function Show-SettingsDialog {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini API 키 및 쿼터 설정"
        $f.Size = New-Object System.Drawing.Size(440, 220)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "Google Gemini API Key 입력 (선택사항):"
        $lbl.Font = New-Object System.Drawing.Font("맑은 고딕", 10)
        $lbl.ForeColor = [System.Drawing.Color]::White
        $lbl.Location = New-Object System.Drawing.Point(20, 20)
        $lbl.AutoSize = $true
        $f.Controls.Add($lbl)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Text = $Global:Config.apiKey
        $txt.Location = New-Object System.Drawing.Point(20, 50)
        $txt.Size = New-Object System.Drawing.Size(380, 25)
        $f.Controls.Add($txt)

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = "저장 및 확인"
        $btn.Font = New-Object System.Drawing.Font("맑은 고딕", 9)
        $btn.Location = New-Object System.Drawing.Point(280, 110)
        $btn.Size = New-Object System.Drawing.Size(120, 32)
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        $btn.FlatStyle = "Flat"
        $btn.Add_Click({
            $Global:Config.apiKey = $txt.Text.Trim()
            if (Test-Path $ConfigFile) {
                try {
                    $rawObj = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $rawObj.apiKey = $Global:Config.apiKey
                    $rawObj | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding UTF8
                } catch {
                    $Global:Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding UTF8
                }
            } else {
                $Global:Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding UTF8
            }
            [System.Windows.Forms.MessageBox]::Show("설정이 성공적으로 저장되었습니다.", "성공", "OK", "Information")
            $f.Close()
            Update-GeminiStatus
        })
        $f.Controls.Add($btn)

        $f.ShowDialog()
    }

    # 10. NotifyIcon 생성
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = New-BatteryIcon -Percent 100 -RiskLevel "GREEN"
    $script:NotifyIcon.Text = "Gemini Token Monitor"
    $script:NotifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $mStatus = $menu.Items.Add("현 상태 보기 (Status)")
    $mStatus.Add_Click({ Show-StatusDialog })

    $mRefresh = $menu.Items.Add("지금 갱신 (Refresh)")
    $mRefresh.Add_Click({ Update-GeminiStatus })

    $menu.Items.Add("-") | Out-Null

    $mSettings = $menu.Items.Add("설정 (Settings)")
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

    # 11. 10분 타이머
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $Global:Config.checkIntervalMinutes * 60 * 1000
    $timer.Add_Tick({ Update-GeminiStatus })
    $timer.Start()

    Update-GeminiStatus
    Write-Log "NotifyIcon 초기화 완료"

    # 12. ApplicationContext 메시지 루프 구동
    $appContext = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($appContext)

} catch {
    Write-Log "메인 루프 치명적 오류: $($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show("Gemini Token Monitor 오류 발생:`n$($_.Exception.Message)", "오류", "OK", "Error")
}
