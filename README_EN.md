# ⚡ Antigravity Token Monitor v5.0

[🇰🇷 한국어 설명서 (README.md)](README.md)

> **Google Antigravity Language Server Official Quota API Integration, N-Hour Window Speed Calculation, Raw Float CSV Logging & Work Schedule-based Quota Prediction**  
> Standalone, zero-install portable executable (`.exe`) with no runtime dependencies (Python/Node.js not needed), maintaining an ultra-low idle memory footprint of **2~5 MB**.

---

## 🌟 v5.0 Key Features

1. **🎯 Official Language Server QuotaSummary API Integration (v5.0 Complete Rewrite)**:
   - Direct IPC calls to `RetrieveUserQuotaSummary` from local `language_server.exe` to retrieve exact remaining quota fractions and official reset times.
   - All legacy guesswork, `weekly_multiplier` inverse estimations, manual offset adjustments, and manual reset schedule inputs have been completely removed.

2. **🤖 Independent Model Group Support (including Gemini 4 Argon)**:
   - **Gemini Models** (Flash / Pro): 5h Quota + Weekly Quota
   - **Gemini 4 Argon** (Dedicated): Weekly Quota
   - **Claude and GPT models** (3P): 5h Quota + Weekly Quota (Alerts can be toggled off)
   - Granular control over alerting (`enabled`) and individual warning/danger thresholds for each model group.

3. **⏱️ N-Hour Window Speed Calculation (`speed_window_seconds`)**:
   - Compares with historical data across a configurable time window (default 3600s = 1 hour) to eliminate the erratic volatility of 1-minute delta measurements.
   - Restores recent history directly from the current day's CSV file upon startup to ensure seamless continuity.

4. **📊 Minimal Raw Float CSV Logging (`logs/usage/yyyyMMdd_usage.csv`)**:
   - Records only the timestamp and exact 6-decimal-place (`F6`) raw quota fractions without duplicate derived fields:
     ```csv
     timestamp,gemini_5h,gemini_weekly,argon_weekly,claude_5h,claude_weekly
     2026-10-16 10:45:01,93.533385,98.152400,85.800266,100.000000,100.000000
     2026-10-16 10:46:01,93.508640,98.145324,85.800266,100.000000,100.000000
     ```

5. **🏢 Realistic Quota Prediction via Work Schedule (`work_schedule`)**:
   - Automatically excludes off-hours (nights, weekends, etc.).
   - Computes remaining active working hours until quota reset and outputs a single concise prediction line:
     ```text
     예상 잔여: (실근무 7.2h 기준) 5시간 82.5% | [경고<20%, 위험<10%]
     ```

6. **🔄 Seamless Hot-Reload**:
   - Modifying and saving `config.json` immediately takes effect on the next polling cycle without restarting the application.

7. **🚦 Dynamic System Tray Badge**:
   - Real-time percentage badge drawn directly onto the system tray icon with 3-tier color coding:
     - 🔴 **Danger**: Remaining $\le$ danger threshold OR speed $\ge$ danger speed
     - 🟠 **Warning**: Remaining $\le$ warning threshold OR speed $\ge$ warning speed
     - 🟢 **Normal**: Safe range

8. **🚀 Ultra-Low Memory Footprint (2~5 MB)**:
   - Uses `System.Threading.Timer`, Gen-2 GC trimming, and Windows native `EmptyWorkingSet`.

---

## ⚙️ Configuration (`config.json`)

```json
{
  "interval_seconds": 60,
  "speed_window_seconds": 3600,
  "work_schedule": {
    "Monday": "09:00-18:00",
    "Tuesday": "09:00-18:00",
    "Wednesday": "09:00-18:00",
    "Thursday": "09:00-18:00",
    "Friday": "09:00-18:00",
    "Saturday": "off",
    "Sunday": "off"
  },
  "model_thresholds": {
    "Gemini Models": {
      "enabled": true,
      "warning_remaining_5h": 20.0,
      "danger_remaining_5h": 10.0,
      "warning_remaining_1w": 25.0,
      "danger_remaining_1w": 10.0,
      "warning_speed_5h": 20.0,
      "danger_speed_5h": 40.0
    },
    "Gemini 4 Argon": {
      "enabled": true,
      "warning_remaining_1w": 25.0,
      "danger_remaining_1w": 10.0,
      "warning_speed_1w": 3.0,
      "danger_speed_1w": 6.0
    },
    "Claude and GPT models": {
      "enabled": false,
      "warning_remaining_5h": 15.0,
      "danger_remaining_5h": 5.0,
      "warning_remaining_1w": 20.0,
      "danger_remaining_1w": 10.0
    }
  }
}
```

---

## 🔨 Build & Run

1. **Run**: Double-click `AntigravityTokenMonitor.exe`.
2. **Build**: Run `build.bat` (uses standard Windows C# compiler `csc.exe`, builds in 1 second).
3. **Startup Registration**: Run `Install-Startup.bat` to auto-launch on Windows login.
