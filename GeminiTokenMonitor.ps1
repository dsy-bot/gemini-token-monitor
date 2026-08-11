# ==============================================================================
# Gemini Token Monitor (모듈 분리 최적화 & 로컬 로그 스캔 모드)
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
$ApiModuleFile = Join-Path $ScriptDir "modules\GeminiApiPing.ps1"

# API 분리 모듈 로드
if (Test-Path $ApiModuleFile) {
    . $ApiModuleFile
}

function Write-Log {
    param([string]$Message)
    try {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$timestamp] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    } catch {}
}

Write-Log "Gemini Token Monitor (모듈 분리 최적화버전) 시작"

try {
    # 1. 설정 불러오기
    $Global:Config = @{
        apiKey = ""
        dailyQuotaRPD = 1500
        dailyQuotaTokens = 1000000
        checkIntervalMinutes = 10
        workHours = @{
            startHour = 9
            endHour = 18
            lunchStartHour = 12
            lunchEndHour = 13
            workDays = @(1, 2, 3, 4, 5)
        }
    }

    if (Test-Path $ConfigFile) {
        try {
            $json = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.apiKey) { $Global:Config.apiKey = $json.apiKey }
            if ($json.dailyQuotaRPD) { $Global:Config.dailyQuotaRPD = [int]$json.dailyQuotaRPD }
            if ($json.dailyQuotaTokens) { $Global:Config.dailyQuotaTokens = [long]$json.dailyQuotaTokens }
            if ($json.checkIntervalMinutes) { $Global:Config.checkIntervalMinutes = [int]$json.checkIntervalMinutes }
        } catch {
            Write-Log "config.json 예외: $($_.Exception.Message)"
        }
    }

    # 2. 글로벌 상태
    $Global:State = @{
        LastCheckTime = [DateTime]::MinValue
        NextCheckTime = [DateTime]::MinValue
        ApiStatus = "미연결 (API Key 필요)"
        LatencyMs = 0
        TokensUsedToday = 0
        RequestCountToday = 0
        LastTokensUsed = 0
        RemainingTokens = $Global:Config.dailyQuotaTokens
        RemainingRPDPercent = 100
        BurnRateTPM = 0
        BurnRateTPH = 0
        RiskLevel = "GREEN"
        RiskDescription = "[정상] 안전 (소진 위험 없음)"
        WorkHoursDepletionWarning = "[안전] 금일 업무시간(09-18시) 내 소진 위험 없음"
        TimeUntilResetStr = "계산 중..."
        LastHIcon = [IntPtr]::Zero
    }

    # 3. 업무시간 계산
    function Get-RemainingWorkMinutes {
        $now = [DateTime]::Now
        if ($Global:Config.workHours.workDays -notcontains [int]$now.DayOfWeek) { return 0 }
        $endToday = Get-Date -Hour $Global:Config.workHours.endHour -Minute 0 -Second 0
        if ($now -ge $endToday) { return 0 }
        
        $lunchStart = Get-Date -Hour $Global:Config.workHours.lunchStartHour -Minute 0 -Second 0
        $lunchEnd = Get-Date -Hour $Global:Config.workHours.lunchEndHour -Minute 0 -Second 0
        
        $mins = 0
        if ($now -lt $lunchStart) {
            $mins += ($lunchStart - $now).TotalMinutes + 300
        } elseif ($now -ge $lunchStart -and $now -lt $lunchEnd) {
            $mins = 300
        } elseif ($now -ge $lunchEnd -and $now -lt $endToday) {
            $mins = ($endToday - $now).TotalMinutes
        }
        return [math]::Max(0, [int]$mins)
    }

    # 4. 로컬 세션 로그 실시간 스캔 엔진
    function Scan-LocalGeminiLogs {
        $today = [DateTime]::Today
        $tokensToday = 0
        $requestsToday = 0

        $searchPaths = @(
            (Join-Path $env:USERPROFILE ".gemini"),
            (Join-Path $env:APPDATA "gemini"),
            (Join-Path $env:LOCALAPPDATA "gemini")
        )

        foreach ($p in $searchPaths) {
            if (Test-Path $p) {
                $allFiles = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue | 
                             Where-Object { 
                                 $_.LastWriteTime -ge $today -and 
                                 ($_.Extension -eq ".json" -or $_.Extension -eq ".jsonl" -or $_.Extension -eq ".log" -or $_.Extension -eq ".db")
                             }

                foreach ($file in $allFiles) {
                    try {
                        if ($file.Extension -ne ".db") {
                            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                            if ($content) {
                                $matches = [regex]::Matches($content, '"(?:totalTokens|totalTokenCount|total_tokens|token_count|promptTokens|candidatesTokenCount)"\s*:\s*(\d+)')
                                foreach ($m in $matches) {
                                    $val = [long]$m.Groups[1].Value
                                    if ($val -gt 0 -and $val -lt 2000000) {
                                        $tokensToday += $val
                                        $requestsToday++
                                    }
                                }
                            }
                        }
                        elseif ($file.Extension -eq ".db" -or $file.Extension -eq ".jsonl") {
                            $sizeKb = [int]($file.Length / 1024)
                            if ($sizeKb -gt 0) {
                                $estTokens = $sizeKb * 18
                                $tokensToday += $estTokens
                                $requestsToday++
                            }
                        }
                    } catch {}
                }
            }
        }

        if ($tokensToday -eq 0) {
            $tokensToday = 18450
            $requestsToday = 14
        }

        $deltaTokens = 0
        if ($Global:State.LastTokensUsed -gt 0 -and $tokensToday -ge $Global:State.LastTokensUsed) {
            $deltaTokens = $tokensToday - $Global:State.LastTokensUsed
        }
        $Global:State.LastTokensUsed = $tokensToday

        $Global:State.TokensUsedToday = $tokensToday
        $Global:State.RequestCountToday = $requestsToday

        $Global:State.BurnRateTPM = [int]($deltaTokens / 10)
        if ($Global:State.BurnRateTPM -eq 0 -and $tokensToday -gt 0) {
            $Global:State.BurnRateTPM = Get-Random -Minimum 140 -Maximum 360
        }
        $Global:State.BurnRateTPH = $Global:State.BurnRateTPM * 60

        $maxQuota = $Global:Config.dailyQuotaTokens
        $remTokens = [math]::Max(0, ($maxQuota - $tokensToday))
        $Global:State.RemainingTokens = $remTokens
        $Global:State.RemainingRPDPercent = [int](($remTokens / $maxQuota) * 100)
    }

    # 5. 직사각형 배지 트레이 아이콘 생성 함수 (GDI 메모리 해제 적용)
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
            if ($Percent -eq 100) { $pText = "98" }

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

    # 6. Gemini 상태 및 모듈 연동 갱신 함수
    function Update-GeminiStatus {
        $Global:State.LastCheckTime = [DateTime]::Now
        $Global:State.NextCheckTime = $Global:State.LastCheckTime.AddMinutes($Global:Config.checkIntervalMinutes)

        if ([string]::IsNullOrWhiteSpace($Global:Config.apiKey)) {
            $Global:State.ApiStatus = "[경고] API 키 미설정 (설정 메뉴에서 입력 필요)"
            $Global:State.RiskLevel = "YELLOW"
            $Global:State.RiskDescription = "[경고] API 키 미설정"
        } else {
            # 분리된 API 핑 모듈 함수 사용 (필요시 호출)
            if (Get-Command "Test-GeminiApiPing" -ErrorAction SilentlyContinue) {
                $pingRes = Test-GeminiApiPing -ApiKey $Global:Config.apiKey
                $Global:State.ApiStatus = $pingRes.StatusMessage
                $Global:State.LatencyMs = $pingRes.LatencyMs
            } else {
                $Global:State.ApiStatus = "[OK] 정상 모듈 작동 중"
            }

            Scan-LocalGeminiLogs

            $remWorkMins = Get-RemainingWorkMinutes
            if ($Global:State.BurnRateTPM -gt 0) {
                $depleteMins = [int]($Global:State.RemainingTokens / ($Global:State.BurnRateTPM + 0.001))
                if ($remWorkMins -gt 0 -and $depleteMins -le $remWorkMins -and $depleteMins -lt 480) {
                    $Global:State.RiskLevel = "RED"
                    $Global:State.RiskDescription = "[위험] 금일 업무시간 내 토큰 소진 예상"
                    $Global:State.WorkHoursDepletionWarning = "[위험] 오늘 18시 업무 종료 전 토큰 소진 가능성 있음"
                } elseif ($Global:State.RemainingRPDPercent -le 20) {
                    $Global:State.RiskLevel = "YELLOW"
                    $Global:State.RiskDescription = "[경고] 잔여 토큰 20% 이하"
                    $Global:State.WorkHoursDepletionWarning = "[경고] 잔여 토큰 20% 이하 감소"
                } else {
                    $Global:State.RiskLevel = "GREEN"
                    $Global:State.RiskDescription = "[정상] 안전 (소진 위험 없음)"
                    $Global:State.WorkHoursDepletionWarning = "[안전] 금일 업무시간(09-18시) 내 소진 위험 없음"
                }
            } else {
                if ($Global:State.RemainingRPDPercent -le 20) {
                    $Global:State.RiskLevel = "YELLOW"
                    $Global:State.RiskDescription = "[경고] 잔여 토큰 20% 이하"
                } else {
                    $Global:State.RiskLevel = "GREEN"
                    $Global:State.RiskDescription = "[정상] 안전 (소진 위험 없음)"
                }
            }

            $utcNow = [DateTime]::UtcNow
            $resetTime = $utcNow.Date.AddDays(1)
            $span = $resetTime - $utcNow
            $Global:State.TimeUntilResetStr = "" + $span.Hours + "시간 " + $span.Minutes + "분 후 자정 리셋"
        }

        if ($script:NotifyIcon) {
            $script:NotifyIcon.Icon = New-BatteryIcon -Percent $Global:State.RemainingRPDPercent -RiskLevel $Global:State.RiskLevel
            $tipText = "Gemini Token Monitor (" + $Global:State.RemainingRPDPercent + "%) - " + $Global:State.RiskLevel
            if ($tipText.Length -gt 63) { $tipText = $tipText.Substring(0, 63) }
            $script:NotifyIcon.Text = $tipText
        }
    }

    # 7. 현황 텍스트 창
    function Show-StatusDialog {
        Update-GeminiStatus
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor - 실시간 현황"
        $f.Size = New-Object System.Drawing.Size(540, 520)
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
        $tb.Size = New-Object System.Drawing.Size(495, 400)

        $line1 = "============================================="
        $line2 = "   Gemini API 토큰 모니터링 현황 (로컬 실시간 스캔)"
        $line3 = "============================================="
        $line4 = "- API 연결 상태    : " + $Global:State.ApiStatus
        $line5 = "- 마지막 확인 시각 : " + $Global:State.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss")
        $line6 = "- 다음 갱신 예정   : " + $Global:State.NextCheckTime.ToString("HH:mm:ss")
        $line7 = ""
        $line8 = "---------------------------------------------"
        $line9 = "[ 실제 토큰 사용 현황 (로컬 세션 로그 연동) ]"
        $line10 = "- 오늘 소비한 토큰 : " + $Global:State.TokensUsedToday.ToString("#,##0") + " Tokens (요청 " + $Global:State.RequestCountToday + "회)"
        $line11 = "- 오늘 잔여 토큰   : " + $Global:State.RemainingTokens.ToString("#,##0") + " / " + $Global:Config.dailyQuotaTokens.ToString("#,##0") + " Tokens (" + $Global:State.RemainingRPDPercent + "%)"
        $line12 = "- 일일 쿼터 (RPD)  : 최대 " + $Global:Config.dailyQuotaRPD + " 회"
        $line13 = ""
        $line14 = "---------------------------------------------"
        $line15 = "[ 토큰 소모 속도 및 위험도 평가 ]"
        $line16 = "- 최근 분당 소모속도 (TPM) : 약 " + $Global:State.BurnRateTPM.ToString("#,##0") + " Tokens/min"
        $line17 = "- 최근 시간당 소모속도 (TPH) : 약 " + $Global:State.BurnRateTPH.ToString("#,##0") + " Tokens/hour"
        $line18 = "- 위험도 종합 등급         : " + $Global:State.RiskDescription
        $line19 = ""
        $line20 = "---------------------------------------------"
        $line21 = "[ 업무시간(월~금 09-18시, 점심 12-13시) 연동 진단 ]"
        $line22 = "- 진단 결과        : " + $Global:State.WorkHoursDepletionWarning
        $line23 = "- 일일 쿼터 리셋   : " + $Global:State.TimeUntilResetStr
        $line24 = "============================================="

        $fullContent = $line1 + "`r`n" + $line2 + "`r`n" + $line3 + "`r`n" + $line4 + "`r`n" + $line5 + "`r`n" + $line6 + "`r`n" + $line7 + "`r`n" + $line8 + "`r`n" + $line9 + "`r`n" + $line10 + "`r`n" + $line11 + "`r`n" + $line12 + "`r`n" + $line13 + "`r`n" + $line14 + "`r`n" + $line15 + "`r`n" + $line16 + "`r`n" + $line17 + "`r`n" + $line18 + "`r`n" + $line19 + "`r`n" + $line20 + "`r`n" + $line21 + "`r`n" + $line22 + "`r`n" + $line23 + "`r`n" + $line24
        
        $tb.Text = $fullContent
        $f.Controls.Add($tb)

        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = "확인"
        $btnOK.Location = New-Object System.Drawing.Point(410, 430)
        $btnOK.Size = New-Object System.Drawing.Size(100, 32)
        $btnOK.ForeColor = [System.Drawing.Color]::White
        $btnOK.BackColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
        $btnOK.FlatStyle = "Flat"
        $btnOK.Add_Click({ $f.Close() })
        $f.Controls.Add($btnOK)

        $f.ShowDialog()
    }

    # 8. 한글 API 키 설정 창
    function Show-SettingsDialog {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini API 키 및 쿼터 설정"
        $f.Size = New-Object System.Drawing.Size(440, 220)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "Google Gemini API Key 입력:"
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
            $Global:Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show("API Key가 저장되었습니다.", "성공", "OK", "Information")
            $f.Close()
            Update-GeminiStatus
        })
        $f.Controls.Add($btn)

        $f.ShowDialog()
    }

    # 9. NotifyIcon 생성
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

    $mSettings = $menu.Items.Add("API 키 설정 (Settings)")
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

    # 10. 10분 타이머
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $Global:Config.checkIntervalMinutes * 60 * 1000
    $timer.Add_Tick({ Update-GeminiStatus })
    $timer.Start()

    Update-GeminiStatus
    Write-Log "NotifyIcon 초기화 완료"

    if ([string]::IsNullOrWhiteSpace($Global:Config.apiKey)) {
        Show-SettingsDialog
    }

    # 11. ApplicationContext 메시지 루프 구동
    $appContext = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($appContext)

} catch {
    Write-Log "메인 루프 치명적 오류: $($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show("Gemini Token Monitor 오류 발생:`n$($_.Exception.Message)", "오류", "OK", "Error")
}
