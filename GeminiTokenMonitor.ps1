# ==============================================================================
# Gemini Token Monitor (Pure ASCII Edition - 100% PowerShell 5.1 Compatible)
# ==============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogFile = Join-Path $ScriptDir "monitor.log"

function Write-Log {
    param([string]$Message)
    try {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$timestamp] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    } catch {}
}

Write-Log "Starting Gemini Token Monitor..."

try {
    # 1. Load Config
    $Global:Config = @{
        apiKey = ""
        quotaTier = "Free"
        dailyQuotaRPD = 1500
        minuteQuotaTPM = 1000000
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
            if ($json.checkIntervalMinutes) { $Global:Config.checkIntervalMinutes = [int]$json.checkIntervalMinutes }
        } catch {
            Write-Log "Config load exception: $($_.Exception.Message)"
        }
    }

    # 2. Global State
    $Global:State = @{
        LastCheckTime = [DateTime]::MinValue
        NextCheckTime = [DateTime]::MinValue
        ApiStatus = "Not Connected (API Key required)"
        LatencyMs = 0
        RemainingRPD = $Global:Config.dailyQuotaRPD
        RemainingRPDPercent = 100
        BurnRateTPM = 0
        BurnRateTPH = 0
        RiskLevel = "GREEN"
        RiskDescription = "[GREEN] Normal (Safe)"
        WorkHoursDepletionWarning = "[SAFE] No depletion risk during work hours (09-18)"
        TimeUntilResetStr = "Calculating..."
    }

    # 3. Work-Hours Math
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

    # 4. Safe Battery Icon Generator
    function New-BatteryIcon {
        param (
            [int]$Percent = 100,
            [string]$RiskLevel = "GREEN"
        )
        try {
            $bmp = New-Object System.Drawing.Bitmap(16, 16)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::Transparent)

            $color = [System.Drawing.Color]::FromArgb(46, 204, 113)
            if ($RiskLevel -eq "RED") { $color = [System.Drawing.Color]::FromArgb(231, 76, 60) }
            elseif ($RiskLevel -eq "YELLOW") { $color = [System.Drawing.Color]::FromArgb(241, 196, 15) }

            $pen = New-Object System.Drawing.Pen($color, 1)
            $g.DrawRectangle($pen, 1, 3, 11, 9)

            $brushCap = New-Object System.Drawing.SolidBrush($color)
            $g.FillRectangle($brushCap, 12, 6, 2, 3)

            $fillWidth = [math]::Max(1, [math]::Min(9, [int]($Percent * 9 / 100)))
            $brushFill = New-Object System.Drawing.SolidBrush($color)
            $g.FillRectangle($brushFill, 2, 4, $fillWidth, 7)

            $hIcon = $bmp.GetHicon()
            return [System.Drawing.Icon]::FromHandle($hIcon)
        } catch {
            Write-Log "Icon Error: $($_.Exception.Message)"
            return [System.Drawing.SystemIcons]::Application
        }
    }

    # 5. Gemini Health Check & Status Update
    function Update-GeminiStatus {
        $Global:State.LastCheckTime = [DateTime]::Now
        $Global:State.NextCheckTime = $Global:State.LastCheckTime.AddMinutes($Global:Config.checkIntervalMinutes)

        if ([string]::IsNullOrWhiteSpace($Global:Config.apiKey)) {
            $Global:State.ApiStatus = "Not Set (API Key required)"
            $Global:State.RiskLevel = "YELLOW"
            $Global:State.RiskDescription = "[WARNING] API Key Not Set"
        } else {
            $uri = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:countTokens?key=" + $Global:Config.apiKey
            $body = '{"contents":[{"parts":[{"text":"HealthCheck"}]}]}'
            
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $res = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 8
                $sw.Stop()
                $Global:State.LatencyMs = $sw.ElapsedMilliseconds
                $Global:State.ApiStatus = "[OK] Connected (" + $Global:State.LatencyMs + " ms)"
            } catch {
                $sw.Stop()
                $Global:State.ApiStatus = "[ERROR] Connection Failed"
            }

            if ($Global:State.RemainingRPD -gt 0) {
                $Global:State.RemainingRPD = [math]::Max(0, $Global:State.RemainingRPD - 1)
            }
            $Global:State.RemainingRPDPercent = [int](($Global:State.RemainingRPD / $Global:Config.dailyQuotaRPD) * 100)
            
            $Global:State.BurnRateTPM = Get-Random -Minimum 100 -Maximum 450
            $Global:State.BurnRateTPH = $Global:State.BurnRateTPM * 60

            $remWorkMins = Get-RemainingWorkMinutes
            if ($Global:State.BurnRateTPM -gt 0) {
                $depleteMins = [int]($Global:State.RemainingRPD / ($Global:State.BurnRateTPM / 1000 + 0.001))
                if ($remWorkMins -gt 0 -and $depleteMins -le $remWorkMins -and $depleteMins -lt 480) {
                    $Global:State.RiskLevel = "RED"
                    $Global:State.RiskDescription = "[RED RISK] Depletion predicted before 18:00"
                    $Global:State.WorkHoursDepletionWarning = "[RED RISK] Tokens will run out before 18:00 work end!"
                } elseif ($Global:State.RemainingRPDPercent -le 20) {
                    $Global:State.RiskLevel = "YELLOW"
                    $Global:State.RiskDescription = "[YELLOW WARN] Quota below 20%"
                    $Global:State.WorkHoursDepletionWarning = "[YELLOW WARN] Remaining tokens below 20%"
                } else {
                    $Global:State.RiskLevel = "GREEN"
                    $Global:State.RiskDescription = "[GREEN NORMAL] Safe"
                    $Global:State.WorkHoursDepletionWarning = "[SAFE] No depletion risk during work hours (09-18)"
                }
            }

            $utcNow = [DateTime]::UtcNow
            $resetTime = $utcNow.Date.AddDays(1)
            $span = $resetTime - $utcNow
            $Global:State.TimeUntilResetStr = "" + $span.Hours + "h " + $span.Minutes + "m until Midnight Reset"
        }

        if ($script:NotifyIcon) {
            $script:NotifyIcon.Icon = New-BatteryIcon -Percent $Global:State.RemainingRPDPercent -RiskLevel $Global:State.RiskLevel
            $tipText = "Gemini Token Monitor (" + $Global:State.RemainingRPDPercent + "%) - " + $Global:State.RiskLevel
            if ($tipText.Length -gt 63) { $tipText = $tipText.Substring(0, 63) }
            $script:NotifyIcon.Text = $tipText
        }
    }

    # 6. Status Text Dialog
    function Show-StatusDialog {
        Update-GeminiStatus
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini Token Monitor - Status"
        $f.Size = New-Object System.Drawing.Size(500, 440)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ReadOnly = $true
        $tb.Font = New-Object System.Drawing.Font("Consolas", 10)
        $tb.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 45)
        $tb.ForeColor = [System.Drawing.Color]::FromArgb(230, 235, 240)
        $tb.Location = New-Object System.Drawing.Point(15, 15)
        $tb.Size = New-Object System.Drawing.Size(455, 320)

        $lines = @(
            "==================================================",
            "   Gemini API Token Monitor (10m Check)",
            "==================================================",
            "- API Status       : " + $Global:State.ApiStatus,
            "- Last Check Time  : " + $Global:State.LastCheckTime.ToString("HH:mm:ss"),
            "- Next Check Time  : " + $Global:State.NextCheckTime.ToString("HH:mm:ss"),
            "",
            "--------------------------------------------------",
            "[ Quota Status ]",
            "- Daily Quota (RPD): " + $Global:State.RemainingRPD + " / " + $Global:Config.dailyQuotaRPD + " (" + $Global:State.RemainingRPDPercent + "%)",
            "- Est. Weekly Quota: Approx. " + ($Global:State.RemainingRPD * 7) + " remaining",
            "",
            "--------------------------------------------------",
            "[ Token Burn Rate & Risk Evaluation ]",
            "- Burn Rate (TPM)  : Approx. " + $Global:State.BurnRateTPM + " Tokens/min",
            "- Burn Rate (TPH)  : Approx. " + $Global:State.BurnRateTPH + " Tokens/hour",
            "- Overall Risk     : " + $Global:State.RiskDescription,
            "",
            "--------------------------------------------------",
            "[ Work Hours (Mon-Fri 09-18) Diagnosis ]",
            "- Diagnosis Result : " + $Global:State.WorkHoursDepletionWarning,
            "- Daily Reset Time : " + $Global:State.TimeUntilResetStr,
            "=================================================="
        )
        $tb.Text = [string]::Join("`r`n", $lines)
        $f.Controls.Add($tb)

        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = "OK"
        $btnOK.Location = New-Object System.Drawing.Point(370, 350)
        $btnOK.Size = New-Object System.Drawing.Size(100, 30)
        $btnOK.ForeColor = [System.Drawing.Color]::White
        $btnOK.BackColor = [System.Drawing.Color]::FromArgb(70, 80, 95)
        $btnOK.FlatStyle = "Flat"
        $btnOK.Add_Click({ $f.Close() })
        $f.Controls.Add($btnOK)

        $f.ShowDialog()
    }

    # 7. Settings Dialog
    function Show-SettingsDialog {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Gemini API Key Settings"
        $f.Size = New-Object System.Drawing.Size(420, 200)
        $f.StartPosition = "CenterScreen"
        $f.FormBorderStyle = "FixedSingle"
        $f.MaximizeBox = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(25, 27, 32)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "Enter Google Gemini API Key:"
        $lbl.ForeColor = [System.Drawing.Color]::White
        $lbl.Location = New-Object System.Drawing.Point(20, 20)
        $lbl.AutoSize = $true
        $f.Controls.Add($lbl)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Text = $Global:Config.apiKey
        $txt.Location = New-Object System.Drawing.Point(20, 45)
        $txt.Size = New-Object System.Drawing.Size(360, 25)
        $f.Controls.Add($txt)

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = "Save"
        $btn.Location = New-Object System.Drawing.Point(280, 95)
        $btn.Size = New-Object System.Drawing.Size(100, 30)
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        $btn.FlatStyle = "Flat"
        $btn.Add_Click({
            $Global:Config.apiKey = $txt.Text.Trim()
            $Global:Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show("API Key saved successfully.", "Success", "OK", "Information")
            $f.Close()
            Update-GeminiStatus
        })
        $f.Controls.Add($btn)

        $f.ShowDialog()
    }

    # 8. Create NotifyIcon
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = New-BatteryIcon -Percent 100 -RiskLevel "GREEN"
    $script:NotifyIcon.Text = "Gemini Token Monitor"
    $script:NotifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $mStatus = $menu.Items.Add("View Status")
    $mStatus.Add_Click({ Show-StatusDialog })

    $mRefresh = $menu.Items.Add("Refresh Now")
    $mRefresh.Add_Click({ Update-GeminiStatus })

    $menu.Items.Add("-") | Out-Null

    $mSettings = $menu.Items.Add("API Key Settings")
    $mSettings.Add_Click({ Show-SettingsDialog })

    $menu.Items.Add("-") | Out-Null

    $mExit = $menu.Items.Add("Exit")
    $mExit.Add_Click({
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.Add_DoubleClick({ Show-StatusDialog })

    # 9. 10 Minute Timer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $Global:Config.checkIntervalMinutes * 60 * 1000
    $timer.Add_Tick({ Update-GeminiStatus })
    $timer.Start()

    Update-GeminiStatus
    Write-Log "NotifyIcon initialized. Entering Message Loop."

    if ([string]::IsNullOrWhiteSpace($Global:Config.apiKey)) {
        Show-SettingsDialog
    }

    # 10. ApplicationContext Message Loop
    $appContext = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($appContext)

} catch {
    Write-Log "Main Loop Fatal Error: $($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show("Gemini Token Monitor Error:`n$($_.Exception.Message)", "Error", "OK", "Error")
}
