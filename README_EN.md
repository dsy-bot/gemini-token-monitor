# ⚡ Antigravity Token Monitor v4.2

[🌐 한국어 설명서 보기 (README.md)](README.md)

> **Real-time Antigravity (Gemini) Token Quota Monitoring, Upstash Redis Cloud Sync & Work-Schedule-Aware Quota Prediction System**  
> Runs as an **ultra-lightweight standalone executable (.exe)** with zero external dependencies (no Python/Node.js required) and maintains a background idle memory footprint of **1.48 MB**.

---

## 🌟 Key Features

1. **🎯 5-Hour Official Real-time Quota Direct Link**:
   - Queries ntigravity-usage quota --json and local Language Server (language_server.exe) IPC directly to receive remaining 5h quota % and official reset countdown with 100% precision.
2. **🏢 Work-Schedule-Aware Realistic Quota Prediction (New in v4.1)**:
   - Excludes non-working hours such as off-work time, sleep hours, and weekends.
   - Integrates only the **pure Active Working Hours** remaining until reset, completely eliminating false danger/warning alarms.
3. **☁️ Upstash Redis Cloud Sync (Work ↔ Home PC)**:
   - Integrates with Free Forever Upstash Redis REST API to synchronize weekly token consumption and multiplier in real-time across multiple PCs.
4. **🎯 Weekly Multiplier Auto-Calibration & Manual Tuning**:
   - Automatically calculates and learns the true weekly quota multiplier ($\text{Multiplier} = \frac{\Delta 5h\%}{\Delta Wk\%}$) based on consumption within the same 5-hour session.
   - Allows direct manual multiplier tuning (e.g. 30.9x) in the calibration dialog.
5. **🌱 New Weekly Cycle Reset & First Usage Auto-Tracker**:
   - Automatically resets weekly quota to 100% upon weekly reset schedule and detects the exact moment token consumption resumes (FirstActiveTime), recording it to logs and dashboard.
6. **⏰ Easy Weekly Reset Time Calculator**:
   - Enter remaining time shown on web UI (e.g., 2 days 5 hours 30 mins) to automatically compute and save weekly reset day and time to config.json.
7. **🚦 3-Tier Status System & Dynamic Tray Badge**:
   - 🔴 **Danger**: Predicted reset remaining $\le 15\%$
   - 🟠 **Warning**: 5h speed $\ge 20\%/\text{h}$ OR predicted reset remaining $\le 25\%$
   - 🟢 **Normal**: Stable condition
   - Real-time % number dynamically drawn on system tray badge.
8. **🚀 1.48 MB Memory Footprint Optimization**:
   - Leverages Windows native EmptyWorkingSet, Gen-2 GC trimming, and immediate socket closure (KeepAlive = false) for a rock-solid **1.48 MB** idle memory footprint (0% handle leak).
9. **📂 Categorized Daily Rolling Logs**:
   - /logs/usage/: Real-time 5h/weekly quota logs
   - /logs/speed/: 5-hour consumption speed, active working hours, reset countdown, and exhaustion predictions
   - /logs/system/: System state changes, cloud sync events, and auto-calibration history

---

## 🚀 Quick Multi-PC Setup & Updates via Git

Using Git makes setting up on a new PC (workplace, laptop, etc.) and updating effortless.

### 1. Initial Setup on a New PC (30 Seconds)
Run the following command in terminal (PowerShell or CMD):
`ash
git clone https://github.com/dsy-bot/gemini-token-monitor.git
`
1. Open the cloned gemini-token-monitor folder.
2. Create or edit config.json with your **Upstash credentials & work schedule** (see guide below).
3. Run AntigravityTokenMonitor.exe.
4. Double-click Install-Startup.bat if you wish to enable automatic startup on Windows boot.

### 2. Updating to the Latest Version (5 Seconds)
Open a terminal in the program folder and run:
`ash
git pull
`

---

## 🌐 Upstash Cloud Sync 1-Minute Guide (Work ↔ Home PC)

You can set up **Upstash (Free Forever)** in 1 minute to share weekly token status across PCs.

### Step 1: Sign up on Upstash & Create Free Database
1. Visit [console.upstash.com](https://console.upstash.com) and log in with your **Google Account** (No credit card required, Free Forever).
2. Go to the **Redis** tab and click **+ Create Database**.
3. Configure settings:
   - **Name**: gemini-token (or any preferred name)
   - **Region**: p-northeast-1 (Tokyo) or your nearest region
   - **Eviction**: Check (Enable)
4. Click **Create** at the bottom.

### Step 2: Copy REST API Credentials
1. Scroll down to the **REST API** section on the database details page.
2. Copy the following 2 values:
   - **UPSTASH_REDIS_REST_URL**: https://xxxx-xxxxx.upstash.io
   - **UPSTASH_REDIS_REST_TOKEN**: Long secret token string starting with A...

### Step 3: Enter Credentials in config.json
Enter the copied information into config.json in the program folder:
`json
{
  // Day helper: Monday | Tuesday | Wednesday | Thursday | Friday | Saturday | Sunday
  "interval_minutes": 10,
  "weekly_reset_day": "Monday",
  "weekly_reset_time": "00:00",
  "weekly_multiplier": 30.9,
  "sync_enabled": true,
  "sync_url": "https://xxxx-xxxxx.upstash.io",
  "sync_api_key": "YOUR_UPSTASH_REST_TOKEN_HERE",

  // Working hours per day of week (use "off" for days off)
  "work_schedule": {
    "Monday": "09:00-18:00",
    "Tuesday": "09:00-18:00",
    "Wednesday": "09:00-18:00",
    "Thursday": "09:00-18:00",
    "Friday": "09:00-18:00",
    "Saturday": "off",
    "Sunday": "off"
  }
}
`

> **💡 Multi-PC Tip**:  
> Put the **same sync_url and sync_api_key** in config.json on both your Work PC and Home PC. It automatically pushes when you leave work and pulls when you open it at home!

---

## ⚙️ Configuration File (config.json) Guide

config.json is automatically generated on first run and supports // line comments.

| Setting | Default | Description |
| :--- | :--- | :--- |
| interval_minutes | 10 | Background real-time quota polling interval (in minutes) |
| weekly_reset_day | "Monday" | Day of week for weekly reset (Monday ~ Sunday) |
| weekly_reset_time| "00:00" | Weekly reset time in 24-hour format (HH:mm) |
| weekly_multiplier| 30.9 | Ratio of 5-hour quota vs weekly quota ($\Delta 5h / \Delta Wk$) |
| sync_enabled | alse | Enable/disable cloud sync (	rue / alse) |
| sync_url | "" | Upstash Redis REST Endpoint URL |
| sync_api_key | "" | Upstash Redis REST Token |
| work_schedule | Mon~Fri 09:00-18:00 | Working hours per day ("HH:mm-HH:mm" or "off") |

---

## 🔨 How to Run & Build

### 1. Running the Application
- Double-click AntigravityTokenMonitor.exe to run.
- **Double-click Tray Icon**: Open 📊 Real-time Status Dashboard.
- **Right-click Tray Icon**: Check Now, Calibrate Weekly %, Open Logs, Edit Config, Exit.

### 2. Building from Source
- Run uild.bat to compile with Windows built-in C# compiler (csc.exe) in 1 second. (No SDK/tools required)

### 3. Windows Startup Registration
- **Register**: Run Install-Startup.bat (creates a shortcut in Windows Startup folder).
- **Unregister**: Run Uninstall-Startup.bat.
