# ==============================================================================
# Gemini API Ping & Token Counting Module (추후 재사용 가능한 엑스트라 모듈)
# ==============================================================================

function Test-GeminiApiPing {
    param (
        [string]$ApiKey,
        [int]$TimeoutSec = 8
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        return @{
            IsSuccess = $false
            StatusCode = 400
            StatusMessage = "API Key Not Set"
            LatencyMs = 0
        }
    }

    $uri = "https://generativelanguage.googleapis.com/v1beta/models?key=" + $ApiKey
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $res = Invoke-RestMethod -Uri $uri -Method Get -ContentType "application/json" -TimeoutSec $TimeoutSec
        $sw.Stop()
        return @{
            IsSuccess = $true
            StatusCode = 200
            StatusMessage = "[OK] 정상 연결 (응답속도 " + $sw.ElapsedMilliseconds + " ms)"
            LatencyMs = $sw.ElapsedMilliseconds
            Models = $res.models
        }
    } catch {
        $sw.Stop()
        $errMsg = $_.Exception.Message
        if ($_.Exception.Response) {
            $errMsg = "HTTP " + [int]$_.Exception.Response.StatusCode + " (" + $_.Exception.Response.StatusDescription + ")"
        }
        return @{
            IsSuccess = $false
            StatusCode = 500
            StatusMessage = "[ERROR] " + $errMsg
            LatencyMs = $sw.ElapsedMilliseconds
        }
    }
}

function Get-GeminiTokenCountFromApi {
    param (
        [string]$ApiKey,
        [string]$PromptText = "HealthCheck",
        [string]$Model = "gemini-1.5-flash"
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) { return 0 }

    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$($Model):countTokens?key=$ApiKey"
    $body = @{ contents = @(@{ parts = @(@{ text = $PromptText }) }) } | ConvertTo-Json -Depth 3

    try {
        $res = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 8
        if ($res.totalTokens) {
            return [long]$res.totalTokens
        }
    } catch {}

    return 0
}
