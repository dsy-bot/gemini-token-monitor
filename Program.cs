using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Net;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using System.Management;

namespace AntigravityTokenMonitor
{
    static class NativeMethods
    {
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern bool DestroyIcon(IntPtr handle);

        [DllImport("psapi.dll")]
        public static extern int EmptyWorkingSet(IntPtr hwProc);
    }

    public enum StatusLevel
    {
        Normal,
        Warning,
        Danger,
        Error
    }

    public class AppConfig
    {
        public int interval_minutes { get; set; }
        public string weekly_reset_day { get; set; }
        public string weekly_reset_time { get; set; }
        public double weekly_multiplier { get; set; }
        public bool sync_enabled { get; set; }
        public string sync_url { get; set; }
        public string sync_api_key { get; set; }
        public Dictionary<string, string> work_schedule { get; set; }

        public AppConfig()
        {
            interval_minutes = 10;
            weekly_reset_day = "Monday";
            weekly_reset_time = "00:00";
            weekly_multiplier = 30.9;
            sync_enabled = false;
            sync_url = string.Empty;
            sync_api_key = string.Empty;
            work_schedule = new Dictionary<string, string>
            {
                { "Monday", "09:00-18:00" },
                { "Tuesday", "09:00-18:00" },
                { "Wednesday", "09:00-18:00" },
                { "Thursday", "09:00-18:00" },
                { "Friday", "09:00-18:00" },
                { "Saturday", "off" },
                { "Sunday", "off" }
            };
        }
    }

    public class WeeklyCalibPoint
    {
        public string ResetTime { get; set; }
        public double FiveHourPercent { get; set; }
        public double UserWeeklyPercent { get; set; }
        public string Timestamp { get; set; }
    }

    public class MonitorState
    {
        public double Remaining5HourPercent { get; set; }
        public double RemainingWeeklyPercent { get; set; }
        public double ConsumptionSpeed5h { get; set; }
        public double Predicted5HourRemaining { get; set; }
        public double PredictedWeeklyRemaining { get; set; }
        public double HoursUntil5HourReset { get; set; }
        public double HoursUntilWeeklyReset { get; set; }
        public double ActiveHoursUntil5HourReset { get; set; }
        public double ActiveHoursUntilWeeklyReset { get; set; }
        public string ResetTime5HourStr { get; set; }
        public StatusLevel CurrentStatus { get; set; }
        public DateTime LastCheckTime { get; set; }
        public string LastErrorMessage { get; set; }
        public string RawJson { get; set; }

        public string LastWeeklyResetId { get; set; }
        public string WeeklyFirstActiveTimeStr { get; set; }
        public double Baseline5hAtWeeklyReset { get; set; }
        public double LastTracked5HourPercent { get; set; }
        public string LastTracked5HourResetTime { get; set; }
        public double WeeklyCumulative5hConsumed { get; set; }

        public MonitorState()
        {
            Remaining5HourPercent = 100.0;
            RemainingWeeklyPercent = 100.0;
            ConsumptionSpeed5h = 0.0;
            Predicted5HourRemaining = 100.0;
            PredictedWeeklyRemaining = 100.0;
            HoursUntil5HourReset = 5.0;
            HoursUntilWeeklyReset = 168.0;
            ActiveHoursUntil5HourReset = 5.0;
            ActiveHoursUntilWeeklyReset = 45.0;
            ResetTime5HourStr = string.Empty;
            CurrentStatus = StatusLevel.Normal;
            LastCheckTime = DateTime.MinValue;
            LastErrorMessage = string.Empty;
            RawJson = string.Empty;
            LastWeeklyResetId = string.Empty;
            WeeklyFirstActiveTimeStr = "기록 없음";
            Baseline5hAtWeeklyReset = 100.0;
            LastTracked5HourPercent = 100.0;
            LastTracked5HourResetTime = string.Empty;
            WeeklyCumulative5hConsumed = 0.0;
        }
    }

    public class UsageLogPoint
    {
        public DateTime Timestamp { get; set; }
        public double RemainingPercent { get; set; }
    }

    static class Program
    {
        private static NotifyIcon _notifyIcon;
        private static System.Windows.Forms.Timer _timer;
        private static AppConfig _config;
        private static MonitorState _state;
        private static List<WeeklyCalibPoint> _calibHistory;
        private static string _appDir;
        private static string _configDir;
        private static string _logsDir;
        private static string _usageDir;
        private static string _speedDir;
        private static string _systemDir;
        private static JavaScriptSerializer _jsonSerializer;
        private static bool _isChecking = false;

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
            try
            {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 | SecurityProtocolType.Tls | (SecurityProtocolType)768;
            }
            catch { }

            _appDir = AppDomain.CurrentDomain.BaseDirectory;
            _configDir = Path.Combine(_appDir, "config");
            _logsDir = Path.Combine(_appDir, "logs");
            _usageDir = Path.Combine(_logsDir, "usage");
            _speedDir = Path.Combine(_logsDir, "speed");
            _systemDir = Path.Combine(_logsDir, "system");

            EnsureDirectories();

            _jsonSerializer = new JavaScriptSerializer();
            _config = LoadConfig();
            _calibHistory = LoadCalibHistory();
            _state = new MonitorState();

            WriteSystemLog("INFO", "Antigravity Token Monitor v4.3 시작");

            // 시작 시 클라우드 Key-Value 서버에서 최신 주간 상태 동기화 시도
            if (_config.sync_enabled)
            {
                SyncPullFromServer();
            }

            InitTrayIcon();

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = Math.Max(1, _config.interval_minutes) * 60 * 1000;
            _timer.Tick += delegate(object sender, EventArgs e) { PerformCheck(); };
            _timer.Start();

            PerformCheck();

            Application.Run();
        }

        private static void EnsureDirectories()
        {
            if (!Directory.Exists(_configDir)) Directory.CreateDirectory(_configDir);
            if (!Directory.Exists(_usageDir)) Directory.CreateDirectory(_usageDir);
            if (!Directory.Exists(_speedDir)) Directory.CreateDirectory(_speedDir);
            if (!Directory.Exists(_systemDir)) Directory.CreateDirectory(_systemDir);
        }

        private static AppConfig LoadConfig()
        {
            string configPath = Path.Combine(_appDir, "config.json");
            if (File.Exists(configPath))
            {
                try
                {
                    string rawJson = File.ReadAllText(configPath, System.Text.Encoding.UTF8);
                    string cleanJson = System.Text.RegularExpressions.Regex.Replace(rawJson, @"(?m)^\s*//.*$", "");
                    AppConfig cfg = _jsonSerializer.Deserialize<AppConfig>(cleanJson);
                    if (cfg != null)
                    {
                        if (cfg.weekly_multiplier <= 0.0) cfg.weekly_multiplier = 30.9;
                        if (cfg.work_schedule == null)
                        {
                            cfg.work_schedule = new Dictionary<string, string>
                            {
                                { "Monday", "09:00-18:00" },
                                { "Tuesday", "09:00-18:00" },
                                { "Wednesday", "09:00-18:00" },
                                { "Thursday", "09:00-18:00" },
                                { "Friday", "09:00-18:00" },
                                { "Saturday", "off" },
                                { "Sunday", "off" }
                            };
                        }
                        return cfg;
                    }
                }
                catch (Exception ex)
                {
                    WriteSystemLog("ERROR", "config.json 로드 실패: " + ex.Message);
                }
                return new AppConfig();
            }
            else
            {
                AppConfig defaultCfg = new AppConfig();
                SaveConfig(defaultCfg);
                return defaultCfg;
            }
        }

        private static void SaveConfig(AppConfig cfg)
        {
            try
            {
                string configPath = Path.Combine(_appDir, "config.json");
                System.Text.StringBuilder sb = new System.Text.StringBuilder();
                sb.AppendLine("{");
                sb.AppendLine("  // 요일 복사용: Monday | Tuesday | Wednesday | Thursday | Friday | Saturday | Sunday");
                sb.AppendLine(string.Format("  \"interval_minutes\": {0},", cfg.interval_minutes));
                sb.AppendLine(string.Format("  \"weekly_reset_day\": \"{0}\",", cfg.weekly_reset_day ?? "Monday"));
                sb.AppendLine(string.Format("  \"weekly_reset_time\": \"{0}\",", cfg.weekly_reset_time ?? "00:00"));
                sb.AppendLine(string.Format("  \"weekly_multiplier\": {0:F1},", cfg.weekly_multiplier > 0 ? cfg.weekly_multiplier : 30.9));
                sb.AppendLine(string.Format("  \"sync_enabled\": {0},", cfg.sync_enabled ? "true" : "false"));
                sb.AppendLine(string.Format("  \"sync_url\": \"{0}\",", cfg.sync_url ?? ""));
                sb.AppendLine(string.Format("  \"sync_api_key\": \"{0}\",", cfg.sync_api_key ?? ""));
                sb.AppendLine("  // 요일별 출퇴근(활동) 시간대 (쉬는 날은 \"off\")");
                sb.AppendLine("  \"work_schedule\": {");
                string[] days = new string[] { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
                for (int i = 0; i < days.Length; i++)
                {
                    string d = days[i];
                    string val = "off";
                    if (cfg.work_schedule != null && cfg.work_schedule.ContainsKey(d)) val = cfg.work_schedule[d];
                    sb.AppendLine(string.Format("    \"{0}\": \"{1}\"{2}", d, val, i < days.Length - 1 ? "," : ""));
                }
                sb.AppendLine("  }");
                sb.AppendLine("}");
                File.WriteAllText(configPath, sb.ToString(), System.Text.Encoding.UTF8);
            }
            catch (Exception ex)
            {
                WriteSystemLog("ERROR", "config.json 저장 실패: " + ex.Message);
            }
        }

        private static List<WeeklyCalibPoint> LoadCalibHistory()
        {
            string calibPath = Path.Combine(_configDir, "weekly_calib.json");
            if (File.Exists(calibPath))
            {
                try
                {
                    string json = File.ReadAllText(calibPath, System.Text.Encoding.UTF8);
                    List<WeeklyCalibPoint> list = _jsonSerializer.Deserialize<List<WeeklyCalibPoint>>(json);
                    if (list != null) return list;
                }
                catch { }
            }
            return new List<WeeklyCalibPoint>();
        }

        private static void SaveCalibHistory(List<WeeklyCalibPoint> list)
        {
            try
            {
                string calibPath = Path.Combine(_configDir, "weekly_calib.json");
                string json = _jsonSerializer.Serialize(list);
                File.WriteAllText(calibPath, json, System.Text.Encoding.UTF8);
            }
            catch (Exception ex)
            {
                WriteSystemLog("ERROR", "weekly_calib.json 저장 실패: " + ex.Message);
            }
        }

        private static void WriteUsageLog(double rem5hPct, double remWkPct, string raw)
        {
            try
            {
                DateTime now = DateTime.Now;
                string fileName = string.Format("{0}_usage.log", now.ToString("yyyyMMdd"));
                string filePath = Path.Combine(_usageDir, fileName);
                string line = string.Format("[{0}] 5hRemaining={1:F2}%, WeeklyRemaining={2:F2}%, Raw={3}",
                    now.ToString("HH:mm:ss"), rem5hPct, remWkPct, raw.Replace("\r", "").Replace("\n", " "));
                File.AppendAllLines(filePath, new string[] { line }, System.Text.Encoding.UTF8);
            }
            catch (Exception ex)
            {
                WriteSystemLog("ERROR", "Usage 로그 기록 실패: " + ex.Message);
            }
        }

        private static void WriteSpeedLog(double speed5h, double t5h, double active5h, double pred5h, double tWk, double activeWk, double predWk, StatusLevel status)
        {
            try
            {
                DateTime now = DateTime.Now;
                string fileName = string.Format("{0}_speed.log", now.ToString("yyyyMMdd"));
                string filePath = Path.Combine(_speedDir, fileName);
                string line = string.Format("[{0}] Speed5h={1:F2}%/h, 5hResetIn={2:F2}h(Act={3:F2}h), Pred5hRem={4:F2}%, WkResetIn={5:F2}h(Act={6:F2}h), PredWkRem={7:F2}%, Status={8}",
                    now.ToString("HH:mm:ss"), speed5h, t5h, active5h, pred5h, tWk, activeWk, predWk, status);
                File.AppendAllLines(filePath, new string[] { line }, System.Text.Encoding.UTF8);
            }
            catch (Exception ex)
            {
                WriteSystemLog("ERROR", "Speed 로그 기록 실패: " + ex.Message);
            }
        }

        private static void WriteSystemLog(string level, string message)
        {
            try
            {
                DateTime now = DateTime.Now;
                string fileName = string.Format("{0}_system.log", now.ToString("yyyyMMdd"));
                string filePath = Path.Combine(_systemDir, fileName);
                string line = string.Format("[{0}] [{1}] {2}", now.ToString("HH:mm:ss"), level, message);
                File.AppendAllLines(filePath, new string[] { line }, System.Text.Encoding.UTF8);
            }
            catch { }
        }

        private static void PerformCheck()
        {
            PerformCheck(null);
        }

        private static void PerformCheck(Action onCompleted)
        {
            if (_isChecking) return;
            _isChecking = true;

            MethodInvoker action = delegate
            {
                try
                {
                    string jsonOutput = FetchQuotaJson();

                    if (string.IsNullOrWhiteSpace(jsonOutput))
                    {
                        _state.CurrentStatus = StatusLevel.Error;
                        if (string.IsNullOrEmpty(_state.LastErrorMessage))
                        {
                            _state.LastErrorMessage = "쿼터 JSON 데이터를 수신할 수 없습니다.";
                        }
                        WriteSystemLog("WARN", _state.LastErrorMessage);
                        UpdateTrayUI();
                        _isChecking = false;
                        return;
                    }

                    _state.RawJson = jsonOutput.Trim();
                    string resetTimeStr;
                    double rem5h = Parse5HourRemainingPercent(_state.RawJson, out resetTimeStr);
                    _state.Remaining5HourPercent = rem5h;
                    _state.ResetTime5HourStr = resetTimeStr;
                    _state.LastCheckTime = DateTime.Now;
                    _state.LastErrorMessage = string.Empty;

                    // 주간 리셋 주기 확인 및 새 주간 첫 토큰 소비 추적
                    CheckWeeklyCycleAndFirstUsage(rem5h, resetTimeStr);

                    // 5시간 실소모량 누적 합산 (주간 누적 소모량 추적용)
                    if (_state.LastTracked5HourPercent > 0 && !string.IsNullOrEmpty(_state.LastTracked5HourResetTime) && _state.LastTracked5HourResetTime == resetTimeStr)
                    {
                        double delta5h = _state.LastTracked5HourPercent - rem5h;
                        if (delta5h > 0.001)
                        {
                            _state.WeeklyCumulative5hConsumed += delta5h;
                        }
                    }
                    _state.LastTracked5HourPercent = rem5h;
                    _state.LastTracked5HourResetTime = resetTimeStr;

                    double remWk = CalculateEstimatedWeeklyPercent(rem5h, resetTimeStr);
                    _state.RemainingWeeklyPercent = remWk;

                    WriteUsageLog(rem5h, remWk, _state.RawJson);

                    double speed5h = Calculate5HourConsumptionSpeed(rem5h);
                    _state.ConsumptionSpeed5h = speed5h;

                    double t5h;
                    DateTime reset5hTarget;
                    double tWeekly;
                    DateTime resetWkTarget;
                    CalculateResetHours(resetTimeStr, out t5h, out reset5hTarget, out tWeekly, out resetWkTarget);
                    _state.HoursUntil5HourReset = t5h;
                    _state.HoursUntilWeeklyReset = tWeekly;

                    double active5h = CalculateActiveWorkingHours(DateTime.Now, reset5hTarget, _config.work_schedule);
                    double activeWeekly = CalculateActiveWorkingHours(DateTime.Now, resetWkTarget, _config.work_schedule);
                    _state.ActiveHoursUntil5HourReset = active5h;
                    _state.ActiveHoursUntilWeeklyReset = activeWeekly;

                    double speedWk = _config.weekly_multiplier > 0 ? (speed5h / _config.weekly_multiplier) : speed5h;
                    _state.Predicted5HourRemaining = Math.Max(0.0, rem5h - (speed5h * active5h));
                    _state.PredictedWeeklyRemaining = Math.Max(0.0, remWk - (speedWk * activeWeekly));

                    StatusLevel newStatus = DetermineStatus(speed5h, _state.Predicted5HourRemaining, _state.PredictedWeeklyRemaining);
                    if (_state.CurrentStatus != newStatus)
                    {
                        WriteSystemLog("INFO", string.Format("트레이 상태 변경: {0} -> {1}", _state.CurrentStatus, newStatus));
                    }
                    _state.CurrentStatus = newStatus;

                    WriteSpeedLog(speed5h, t5h, active5h, _state.Predicted5HourRemaining, tWeekly, activeWeekly, _state.PredictedWeeklyRemaining, newStatus);

                    UpdateTrayUI();

                    // 클라우드 Key-Value 서버로 최신 상태 자동 Push
                    if (_config.sync_enabled)
                    {
                        SyncPushToServer();
                    }
                }
                catch (Exception ex)
                {
                    _state.CurrentStatus = StatusLevel.Error;
                    _state.LastErrorMessage = "체크 루틴 예외: " + ex.Message;
                    WriteSystemLog("ERROR", _state.LastErrorMessage);
                    UpdateTrayUI();
                }
                finally
                {
                    _isChecking = false;
                    TrimMemory();
                    if (onCompleted != null)
                    {
                        try { onCompleted(); } catch { }
                    }
                }
            };

            action.BeginInvoke(null, null);
        }

        private static DateTime GetLastWeeklyResetDateTime(DateTime now, string resetDayStr, string resetTimeStr)
        {
            DayOfWeek resetDay = DayOfWeek.Monday;
            try { resetDay = (DayOfWeek)Enum.Parse(typeof(DayOfWeek), resetDayStr, true); } catch { }

            TimeSpan resetTime = TimeSpan.Zero;
            TimeSpan.TryParse(resetTimeStr, out resetTime);

            DateTime candidate = now.Date.Add(resetTime);
            while (candidate.DayOfWeek != resetDay || candidate > now)
            {
                candidate = candidate.AddDays(-1);
            }
            return candidate;
        }

        private static void CheckWeeklyCycleAndFirstUsage(double current5hRem, string current5hResetStr)
        {
            try
            {
                DateTime now = DateTime.Now;
                DateTime lastResetDt = GetLastWeeklyResetDateTime(now, _config.weekly_reset_day, _config.weekly_reset_time);
                string currentCycleId = lastResetDt.ToString("yyyy-MM-dd HH:mm");

                if (_state.LastWeeklyResetId != currentCycleId)
                {
                    _state.LastWeeklyResetId = currentCycleId;
                    _state.RemainingWeeklyPercent = 100.0;
                    _state.WeeklyFirstActiveTimeStr = "아직 소비 없음 (리셋 대기)";
                    _state.Baseline5hAtWeeklyReset = current5hRem;
                    _state.WeeklyCumulative5hConsumed = 0.0;

                    WeeklyCalibPoint anchorPoint = new WeeklyCalibPoint
                    {
                        ResetTime = current5hResetStr,
                        FiveHourPercent = current5hRem,
                        UserWeeklyPercent = 100.0,
                        Timestamp = now.ToString("yyyy-MM-dd HH:mm:ss")
                    };
                    if (_calibHistory == null) _calibHistory = new List<WeeklyCalibPoint>();
                    _calibHistory.Add(anchorPoint);
                    SaveCalibHistory(_calibHistory);

                    WriteSystemLog("INFO", string.Format("🎯 새 주간 사이클 진입 ({0}): 주간 잔여량 100% 초기화 및 기준점 설정 (5h 잔여: {1:F1}%)",
                        currentCycleId, current5hRem));

                    if (_config.sync_enabled)
                    {
                        SyncPushToServer();
                    }
                }
                else
                {
                    // 새 주간 첫 토큰 소모 감지
                    if (_state.WeeklyFirstActiveTimeStr.Contains("아직 소비 없음"))
                    {
                        bool consumed = (_state.Baseline5hAtWeeklyReset - current5hRem) >= 0.3;
                        if (consumed)
                        {
                            _state.WeeklyFirstActiveTimeStr = now.ToString("yyyy-MM-dd HH:mm:ss");
                            WriteSystemLog("INFO", string.Format("🎯 새 주간 첫 토큰 소비 감지! 시각: {0}, 5h 잔여: {1:F1}% (리셋당시: {2:F1}%)",
                                _state.WeeklyFirstActiveTimeStr, current5hRem, _state.Baseline5hAtWeeklyReset));
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                WriteSystemLog("WARN", "주간 사이클 확인 예외: " + ex.Message);
            }
        }

        private static void TrimMemory()
        {
            try
            {
                GC.Collect(2, GCCollectionMode.Forced, true);
                GC.WaitForPendingFinalizers();
                NativeMethods.EmptyWorkingSet(Process.GetCurrentProcess().Handle);
            }
            catch { }
        }

        private static string FetchQuotaJson()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c antigravity-usage quota --json",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process proc = Process.Start(psi))
                {
                    string stdout = proc.StandardOutput.ReadToEnd();
                    proc.WaitForExit(8000);
                    if (proc.ExitCode == 0 && !string.IsNullOrWhiteSpace(stdout) && stdout.Trim().StartsWith("{"))
                    {
                        return stdout.Trim();
                    }
                }
            }
            catch { }

            try
            {
                int lsPid = 0;
                string csrfToken = string.Empty;

                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'language_server.exe'"))
                using (ManagementObjectCollection results = searcher.Get())
                {
                    foreach (ManagementObject obj in results)
                    {
                        using (obj)
                        {
                            lsPid = Convert.ToInt32(obj["ProcessId"]);
                            string cmd = Convert.ToString(obj["CommandLine"]);
                            if (!string.IsNullOrEmpty(cmd) && cmd.Contains("--csrf_token"))
                            {
                                int idx = cmd.IndexOf("--csrf_token");
                                string sub = cmd.Substring(idx + 12).Trim();
                                string[] parts = sub.Split(new char[] { ' ', '"', '\'' }, StringSplitOptions.RemoveEmptyEntries);
                                if (parts.Length > 0)
                                {
                                    csrfToken = parts[0];
                                }
                            }
                        }
                    }
                }

                if (!string.IsNullOrEmpty(csrfToken))
                {
                    ProcessStartInfo netStatPsi = new ProcessStartInfo
                    {
                        FileName = "cmd.exe",
                        Arguments = "/c netstat -ano | findstr " + lsPid,
                        RedirectStandardOutput = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };

                    List<int> candidatePorts = new List<int>();
                    using (Process netProc = Process.Start(netStatPsi))
                    {
                        string netOut = netProc.StandardOutput.ReadToEnd();
                        netProc.WaitForExit(3000);
                        foreach (string line in netOut.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                        {
                            if (line.Contains("LISTENING") && line.Contains("127.0.0.1:"))
                            {
                                System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(line, @"127\.0\.0\.1:(\d+)");
                                if (m.Success)
                                {
                                    int p;
                                    if (int.TryParse(m.Groups[1].Value, out p) && !candidatePorts.Contains(p))
                                    {
                                        candidatePorts.Add(p);
                                    }
                                }
                            }
                        }
                    }

                    foreach (int p in candidatePorts)
                    {
                        try
                        {
                            string url = string.Format("https://127.0.0.1:{0}/exa.language_server_pb.LanguageServerService/GetUserStatus", p);
                            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                            req.Method = "POST";
                            req.ContentType = "application/json";
                            req.KeepAlive = false;
                            req.ServicePoint.Expect100Continue = false;
                            req.Headers.Add("Connect-Protocol-Version", "1");
                            req.Headers.Add("X-Codeium-Csrf-Token", csrfToken);
                            req.Timeout = 2000;

                            byte[] postBytes = System.Text.Encoding.UTF8.GetBytes("{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\"}}");
                            req.ContentLength = postBytes.Length;
                            using (Stream stream = req.GetRequestStream())
                            {
                                stream.Write(postBytes, 0, postBytes.Length);
                            }

                            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                            using (StreamReader reader = new StreamReader(resp.GetResponseStream(), System.Text.Encoding.UTF8))
                            {
                                string resultJson = reader.ReadToEnd();
                                if (!string.IsNullOrEmpty(resultJson))
                                {
                                    return resultJson;
                                }
                            }
                        }
                        catch { }
                    }
                }
            }
            catch (Exception ex)
            {
                _state.LastErrorMessage = "로컬 Language Server 직결 실패: " + ex.Message;
            }

            return string.Empty;
        }

        private static double Parse5HourRemainingPercent(string json, out string resetTimeStr)
        {
            resetTimeStr = string.Empty;
            try
            {
                object parsed = _jsonSerializer.DeserializeObject(json);
                Dictionary<string, object> dict = parsed as Dictionary<string, object>;
                if (dict != null)
                {
                    if (dict.ContainsKey("userStatus"))
                    {
                        Dictionary<string, object> uStatus = dict["userStatus"] as Dictionary<string, object>;
                        if (uStatus != null && uStatus.ContainsKey("cascadeModelConfigData"))
                        {
                            Dictionary<string, object> cmData = uStatus["cascadeModelConfigData"] as Dictionary<string, object>;
                            if (cmData != null && cmData.ContainsKey("clientModelConfigs"))
                            {
                                object[] models = cmData["clientModelConfigs"] as object[];
                                if (models != null && models.Length > 0)
                                {
                                    double lowestFraction = double.MaxValue;
                                    string lowestResetTime = string.Empty;

                                    foreach (object m in models)
                                    {
                                        Dictionary<string, object> mDict = m as Dictionary<string, object>;
                                        if (mDict != null && mDict.ContainsKey("quotaInfo"))
                                        {
                                            string label = mDict.ContainsKey("label") ? Convert.ToString(mDict["label"]) : "";
                                            string modelId = mDict.ContainsKey("modelId") ? Convert.ToString(mDict["modelId"]) : "";

                                            Dictionary<string, object> qInfo = mDict["quotaInfo"] as Dictionary<string, object>;
                                            if (qInfo != null && qInfo.ContainsKey("remainingFraction") && qInfo["remainingFraction"] != null)
                                            {
                                                double frac = Convert.ToDouble(qInfo["remainingFraction"]);
                                                string rTime = qInfo.ContainsKey("resetTime") && qInfo["resetTime"] != null ? Convert.ToString(qInfo["resetTime"]) : "";

                                                // 1. Gemini 모델 최우선 선택 (Claude / GPT-OSS 100% 가짜 쿼터 배제)
                                                if (label.IndexOf("Gemini", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                                    modelId.IndexOf("gemini", StringComparison.OrdinalIgnoreCase) >= 0)
                                                {
                                                    resetTimeStr = rTime;
                                                    return Math.Round(frac * 100.0, 1);
                                                }

                                                // 2. Gemini가 없을 경우 실제 소모 중인 최저 잔여량 모델 기록
                                                if (frac < lowestFraction)
                                                {
                                                    lowestFraction = frac;
                                                    lowestResetTime = rTime;
                                                }
                                            }
                                        }
                                    }

                                    if (lowestFraction < double.MaxValue)
                                    {
                                        resetTimeStr = lowestResetTime;
                                        return Math.Round(lowestFraction * 100.0, 1);
                                    }
                                }
                            }
                        }
                    }

                    if (dict.ContainsKey("data"))
                    {
                        Dictionary<string, object> data = dict["data"] as Dictionary<string, object>;
                        if (data != null && data.ContainsKey("fiveHour"))
                        {
                            Dictionary<string, object> fiveH = data["fiveHour"] as Dictionary<string, object>;
                            if (fiveH != null)
                            {
                                if (fiveH.ContainsKey("resetAt") && fiveH["resetAt"] != null)
                                {
                                    resetTimeStr = Convert.ToString(fiveH["resetAt"]);
                                }
                                if (fiveH.ContainsKey("remainingPercent") && fiveH["remainingPercent"] != null)
                                {
                                    return Convert.ToDouble(fiveH["remainingPercent"]);
                                }
                                if (fiveH.ContainsKey("remainingPercentage") && fiveH["remainingPercentage"] != null)
                                {
                                    return Convert.ToDouble(fiveH["remainingPercentage"]);
                                }
                            }
                        }
                    }

                    string[] keys = new string[] { "remaining_percentage", "remaining_percent", "remaining", "percentage", "percent" };
                    foreach (string key in keys)
                    {
                        if (dict.ContainsKey(key) && dict[key] != null)
                        {
                            return Convert.ToDouble(dict[key]);
                        }
                    }
                }
            }
            catch { }
            return 100.0;
        }

        private static double CalculateEstimatedWeeklyPercent(double current5hRemPct, string currentResetTimeStr)
        {
            double mult = _config.weekly_multiplier > 0 ? _config.weekly_multiplier : 30.9;

            if (_calibHistory != null && _calibHistory.Count > 0)
            {
                WeeklyCalibPoint lastPoint = _calibHistory[_calibHistory.Count - 1];

                // 5시간 세션이 변경되었을 때: 이전 세션까지 계산된 주간 잔여량을 기준으로 연속 기준점(Chained Anchor) 자동 생성
                if (!string.IsNullOrEmpty(lastPoint.ResetTime) && !string.IsNullOrEmpty(currentResetTimeStr) && lastPoint.ResetTime != currentResetTimeStr)
                {
                    double currentWk = _state.RemainingWeeklyPercent;
                    if (currentWk <= 0.0 || currentWk > 100.0) currentWk = 100.0;

                    WeeklyCalibPoint chainedAnchor = new WeeklyCalibPoint
                    {
                        ResetTime = currentResetTimeStr,
                        FiveHourPercent = current5hRemPct,
                        UserWeeklyPercent = currentWk,
                        Timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")
                    };
                    _calibHistory.Add(chainedAnchor);
                    SaveCalibHistory(_calibHistory);
                    lastPoint = chainedAnchor;
                }

                double delta5hSinceCalib = Math.Max(0.0, lastPoint.FiveHourPercent - current5hRemPct);
                double deltaWkSinceCalib = delta5hSinceCalib / mult;
                return Math.Max(0.0, Math.Min(100.0, lastPoint.UserWeeklyPercent - deltaWkSinceCalib));
            }

            double consumed5h = Math.Max(0.0, 100.0 - current5hRemPct);
            return Math.Max(0.0, Math.Min(100.0, 100.0 - (consumed5h / mult)));
        }

        public static void RecordUserWeeklyCalibration(double userWkPct)
        {
            try
            {
                double current5h = _state.Remaining5HourPercent;
                string currentReset = _state.ResetTime5HourStr;
                DateTime now = DateTime.Now;

                WeeklyCalibPoint newPoint = new WeeklyCalibPoint
                {
                    ResetTime = currentReset,
                    FiveHourPercent = current5h,
                    UserWeeklyPercent = userWkPct,
                    Timestamp = now.ToString("yyyy-MM-dd HH:mm:ss")
                };

                // 1. 이번 주 주간 리셋(100%) 기준점 탐색
                WeeklyCalibPoint weeklyAnchor = null;
                if (_calibHistory != null && _calibHistory.Count > 0)
                {
                    for (int i = _calibHistory.Count - 1; i >= 0; i--)
                    {
                        if (_calibHistory[i].UserWeeklyPercent >= 99.9)
                        {
                            weeklyAnchor = _calibHistory[i];
                            break;
                        }
                    }
                }

                double totalWkConsumed = weeklyAnchor != null ? (weeklyAnchor.UserWeeklyPercent - userWkPct) : (100.0 - userWkPct);
                double total5hConsumed = _state.WeeklyCumulative5hConsumed;

                // 누적 기록이 아직 적을 경우 Anchor와 현재 5h 차이도 합산
                if (weeklyAnchor != null && total5hConsumed < 0.5)
                {
                    if (weeklyAnchor.ResetTime == currentReset)
                    {
                        total5hConsumed = Math.Max(0.0, weeklyAnchor.FiveHourPercent - current5h);
                    }
                }

                // 2. 누적 총량 기반 배율 자동 계산 (소모량이 유의미할 때)
                if (totalWkConsumed >= 0.1 && total5hConsumed >= 0.5)
                {
                    double calculatedMultiplier = Math.Round(total5hConsumed / totalWkConsumed, 1);
                    if (calculatedMultiplier >= 1.0 && calculatedMultiplier <= 300.0)
                    {
                        _config.weekly_multiplier = calculatedMultiplier;
                        SaveConfig(_config);
                        WriteSystemLog("INFO", string.Format("🎯 누적 총량 기반 배율 자동보정 완료: {0:F1}배 (이번주 5h누적소모: {1:F1}%, 주간소모: {2:F1}%)",
                            calculatedMultiplier, total5hConsumed, totalWkConsumed));
                    }
                }
                else if (_calibHistory != null && _calibHistory.Count > 0)
                {
                    // 3. 누적량이 부족할 경우 직전 매칭 포인트 2차 검사
                    WeeklyCalibPoint prevMatch = null;
                    for (int i = _calibHistory.Count - 1; i >= 0; i--)
                    {
                        if (_calibHistory[i].ResetTime == currentReset && !string.IsNullOrEmpty(currentReset))
                        {
                            prevMatch = _calibHistory[i];
                            break;
                        }
                    }

                    if (prevMatch != null)
                    {
                        double delta5h = prevMatch.FiveHourPercent - current5h;
                        double deltaWk = prevMatch.UserWeeklyPercent - userWkPct;

                        if (delta5h >= 1.0 && deltaWk >= 0.1)
                        {
                            double calculatedMultiplier = Math.Round(delta5h / deltaWk, 1);
                            if (calculatedMultiplier >= 1.0 && calculatedMultiplier <= 300.0)
                            {
                                _config.weekly_multiplier = calculatedMultiplier;
                                SaveConfig(_config);
                                WriteSystemLog("INFO", string.Format("주간/일간 배율 세션 보정 완료: {0:F1}배 (5h소모: {1:F1}%, 주간소모: {2:F1}%)",
                                    calculatedMultiplier, delta5h, deltaWk));
                            }
                        }
                    }
                }

                _calibHistory.Add(newPoint);
                SaveCalibHistory(_calibHistory);

                _state.RemainingWeeklyPercent = userWkPct;
                WriteSystemLog("INFO", string.Format("주간 잔여량 수동 보정 기록: {0}% (5h: {1}%, Reset: {2})",
                    userWkPct, current5h, currentReset));

                UpdateTrayUI();

                if (_config.sync_enabled)
                {
                    SyncPushToServer();
                }
            }
            catch (Exception ex)
            {
                WriteSystemLog("ERROR", "주간 보정 저장 실패: " + ex.Message);
            }
        }

        #region Key-Value Cloud Sync (Raw HttpWebRequest)
        private static void SyncPullFromServer()
        {
            if (!_config.sync_enabled || string.IsNullOrEmpty(_config.sync_url)) return;

            try
            {
                string url = _config.sync_url.Trim().TrimEnd('/');
                if (url.Contains("upstash.io") && !url.Contains("/get/"))
                {
                    url = url + "/get/gemini_token";
                }

                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = "GET";
                req.UserAgent = "AntigravityTokenMonitor/4.3";
                req.KeepAlive = false;
                req.ServicePoint.Expect100Continue = false;
                req.Timeout = 3000;
                if (!string.IsNullOrEmpty(_config.sync_api_key))
                {
                    req.Headers.Add("Authorization", "Bearer " + _config.sync_api_key.Trim());
                    req.Headers.Add("X-Master-Key", _config.sync_api_key.Trim());
                    req.Headers.Add("X-Access-Key", _config.sync_api_key.Trim());
                }

                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                using (StreamReader r = new StreamReader(resp.GetResponseStream(), System.Text.Encoding.UTF8))
                {
                    string json = r.ReadToEnd();
                    if (!string.IsNullOrEmpty(json))
                    {
                        object obj = _jsonSerializer.DeserializeObject(json);
                        Dictionary<string, object> dict = obj as Dictionary<string, object>;
                        if (dict != null)
                        {
                            // Upstash Redis format: {"result": "{\"remaining_weekly_percent\":...}"}
                            if (dict.ContainsKey("result") && dict["result"] != null)
                            {
                                string innerJson = Convert.ToString(dict["result"]);
                                if (!string.IsNullOrEmpty(innerJson) && innerJson.StartsWith("{"))
                                {
                                    object innerObj = _jsonSerializer.DeserializeObject(innerJson);
                                    Dictionary<string, object> innerDict = innerObj as Dictionary<string, object>;
                                    if (innerDict != null) dict = innerDict;
                                }
                            }
                            else if (dict.ContainsKey("record"))
                            {
                                Dictionary<string, object> rec = dict["record"] as Dictionary<string, object>;
                                if (rec != null) dict = rec;
                            }

                            if (dict.ContainsKey("weekly_multiplier") && dict["weekly_multiplier"] != null)
                            {
                                _config.weekly_multiplier = Convert.ToDouble(dict["weekly_multiplier"]);
                            }
                            if (dict.ContainsKey("remaining_weekly_percent") && dict["remaining_weekly_percent"] != null)
                            {
                                _state.RemainingWeeklyPercent = Convert.ToDouble(dict["remaining_weekly_percent"]);
                            }
                            if (dict.ContainsKey("weekly_reset_day") && dict["weekly_reset_day"] != null)
                            {
                                _config.weekly_reset_day = Convert.ToString(dict["weekly_reset_day"]);
                            }
                            if (dict.ContainsKey("weekly_reset_time") && dict["weekly_reset_time"] != null)
                            {
                                _config.weekly_reset_time = Convert.ToString(dict["weekly_reset_time"]);
                            }
                            if (dict.ContainsKey("weekly_first_active_time") && dict["weekly_first_active_time"] != null)
                            {
                                _state.WeeklyFirstActiveTimeStr = Convert.ToString(dict["weekly_first_active_time"]);
                            }
                            if (dict.ContainsKey("weekly_cumulative_5h_consumed") && dict["weekly_cumulative_5h_consumed"] != null)
                            {
                                _state.WeeklyCumulative5hConsumed = Convert.ToDouble(dict["weekly_cumulative_5h_consumed"]);
                            }

                            SaveConfig(_config);
                            WriteSystemLog("INFO", string.Format("클라우드 Key-Value 동기화 수신 성공 (주간%: {0:F1}%, 배율: {1:F1}배)",
                                _state.RemainingWeeklyPercent, _config.weekly_multiplier));
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                WriteSystemLog("WARN", "클라우드 동기화 Pull 실패: " + ex.Message);
            }
            finally
            {
                TrimMemory();
            }
        }

        private static void SyncPushToServer()
        {
            if (!_config.sync_enabled || string.IsNullOrEmpty(_config.sync_url)) return;

            try
            {
                string url = _config.sync_url.Trim().TrimEnd('/');
                string httpMethod = "PUT";

                if (url.Contains("upstash.io"))
                {
                    httpMethod = "POST";
                    if (!url.Contains("/set/"))
                    {
                        url = url + "/set/gemini_token";
                    }
                }

                Dictionary<string, object> payload = new Dictionary<string, object>();
                payload["updated_at"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                payload["remaining_weekly_percent"] = _state.RemainingWeeklyPercent;
                payload["weekly_multiplier"] = _config.weekly_multiplier;
                payload["weekly_reset_day"] = _config.weekly_reset_day;
                payload["weekly_reset_time"] = _config.weekly_reset_time;
                payload["weekly_first_active_time"] = _state.WeeklyFirstActiveTimeStr;
                payload["weekly_cumulative_5h_consumed"] = _state.WeeklyCumulative5hConsumed;

                string json = _jsonSerializer.Serialize(payload);
                byte[] bytes = System.Text.Encoding.UTF8.GetBytes(json);

                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = httpMethod;
                req.ContentType = "application/json";
                req.UserAgent = "AntigravityTokenMonitor/4.3";
                req.KeepAlive = false;
                req.ServicePoint.Expect100Continue = false;
                req.ContentLength = bytes.Length;
                req.Timeout = 3000;

                if (!string.IsNullOrEmpty(_config.sync_api_key))
                {
                    req.Headers.Add("Authorization", "Bearer " + _config.sync_api_key.Trim());
                    req.Headers.Add("X-Master-Key", _config.sync_api_key.Trim());
                    req.Headers.Add("X-Access-Key", _config.sync_api_key.Trim());
                }

                using (Stream s = req.GetRequestStream())
                {
                    s.Write(bytes, 0, bytes.Length);
                }

                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    WriteSystemLog("INFO", "클라우드 Key-Value 동기화 전송 성공");
                }
            }
            catch (Exception ex)
            {
                WriteSystemLog("WARN", "클라우드 동기화 Push 실패: " + ex.Message);
            }
            finally
            {
                TrimMemory();
            }
        }
        #endregion

        private static double Calculate5HourConsumptionSpeed(double currentRemPct)
        {
            try
            {
                DateTime now = DateTime.Now;
                DateTime start5h = now.AddHours(-5);
                List<UsageLogPoint> points = new List<UsageLogPoint>();

                string[] filesToRead = new string[]
                {
                    Path.Combine(_usageDir, string.Format("{0}_usage.log", now.AddDays(-1).ToString("yyyyMMdd"))),
                    Path.Combine(_usageDir, string.Format("{0}_usage.log", now.ToString("yyyyMMdd")))
                };

                foreach (string file in filesToRead)
                {
                    if (File.Exists(file))
                    {
                        string dateStr = Path.GetFileNameWithoutExtension(file).Substring(0, 8);
                        DateTime fileDate = DateTime.ParseExact(dateStr, "yyyyMMdd", null);

                        foreach (string line in File.ReadLines(file, System.Text.Encoding.UTF8))
                        {
                            if (string.IsNullOrWhiteSpace(line) || !line.StartsWith("[")) continue;
                            int closeBracket = line.IndexOf(']');
                            if (closeBracket > 1)
                            {
                                string timeStr = line.Substring(1, closeBracket - 1);
                                TimeSpan ts;
                                if (TimeSpan.TryParse(timeStr, out ts))
                                {
                                    DateTime entryTime = fileDate.Date.Add(ts);
                                    if (entryTime >= start5h && entryTime <= now)
                                    {
                                        int remIdx = line.IndexOf("5hRemaining=");
                                        if (remIdx < 0) remIdx = line.IndexOf("RemainingPercent=");
                                        if (remIdx > 0)
                                        {
                                            int eqIdx = line.IndexOf('=', remIdx);
                                            int pctEnd = line.IndexOf('%', eqIdx);
                                            if (pctEnd > eqIdx)
                                            {
                                                string valStr = line.Substring(eqIdx + 1, pctEnd - (eqIdx + 1));
                                                double remVal;
                                                if (double.TryParse(valStr, out remVal))
                                                {
                                                    points.Add(new UsageLogPoint { Timestamp = entryTime, RemainingPercent = remVal });
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (points.Count >= 2)
                {
                    UsageLogPoint oldest = points[0];
                    UsageLogPoint newest = points[points.Count - 1];
                    double elapsedHours = (newest.Timestamp - oldest.Timestamp).TotalHours;
                    if (elapsedHours >= 0.05)
                    {
                        double deltaConsumed = oldest.RemainingPercent - newest.RemainingPercent;
                        if (deltaConsumed > 0)
                        {
                            return deltaConsumed / elapsedHours;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                WriteSystemLog("WARN", "속도 계산 예외: " + ex.Message);
            }
            return 0.0;
        }

        private static void CalculateResetHours(string resetTimeIso, out double hours5h, out DateTime reset5hTarget, out double hoursWeekly, out DateTime resetWkTarget)
        {
            DateTime now = DateTime.Now;

            hours5h = 5.0;
            reset5hTarget = now.AddHours(5.0);
            if (!string.IsNullOrEmpty(resetTimeIso))
            {
                try
                {
                    DateTime parsedUtc = DateTime.Parse(resetTimeIso).ToUniversalTime();
                    DateTime parsedLocal = parsedUtc.ToLocalTime();
                    if (parsedLocal > now)
                    {
                        reset5hTarget = parsedLocal;
                        hours5h = Math.Max(0.05, (parsedLocal - now).TotalHours);
                    }
                }
                catch { }
            }

            DayOfWeek resetDay = DayOfWeek.Monday;
            try
            {
                resetDay = (DayOfWeek)Enum.Parse(typeof(DayOfWeek), _config.weekly_reset_day, true);
            }
            catch { }

            TimeSpan weeklyResetTime = TimeSpan.Zero;
            TimeSpan.TryParse(_config.weekly_reset_time, out weeklyResetTime);

            DateTime nextWeekly = now.Date.Add(weeklyResetTime);
            while (nextWeekly.DayOfWeek != resetDay || nextWeekly <= now)
            {
                nextWeekly = nextWeekly.AddDays(1);
            }
            resetWkTarget = nextWeekly;
            hoursWeekly = Math.Max(0.1, (nextWeekly - now).TotalHours);
        }

        private static double CalculateActiveWorkingHours(DateTime start, DateTime end, Dictionary<string, string> schedule)
        {
            if (end <= start) return 0.0;
            if (schedule == null || schedule.Count == 0)
            {
                return Math.Max(0.0, (end - start).TotalHours);
            }

            double totalActiveHours = 0.0;
            DateTime curDate = start.Date;
            DateTime endDate = end.Date;

            while (curDate <= endDate)
            {
                string dayName = curDate.DayOfWeek.ToString();
                if (schedule.ContainsKey(dayName))
                {
                    string timeRange = schedule[dayName];
                    if (!string.IsNullOrWhiteSpace(timeRange) && !timeRange.Equals("off", StringComparison.OrdinalIgnoreCase))
                    {
                        string[] parts = timeRange.Split('-');
                        if (parts.Length == 2)
                        {
                            TimeSpan workStart, workEnd;
                            if (TimeSpan.TryParse(parts[0].Trim(), out workStart) && TimeSpan.TryParse(parts[1].Trim(), out workEnd))
                            {
                                DateTime workStartDt = curDate.Add(workStart);
                                DateTime workEndDt = curDate.Add(workEnd);

                                DateTime overlapStart = start > workStartDt ? start : workStartDt;
                                DateTime overlapEnd = end < workEndDt ? end : workEndDt;

                                if (overlapEnd > overlapStart)
                                {
                                    totalActiveHours += (overlapEnd - overlapStart).TotalHours;
                                }
                            }
                        }
                    }
                }
                curDate = curDate.AddDays(1);
            }

            return Math.Max(0.0, totalActiveHours);
        }

        private static StatusLevel DetermineStatus(double speed5h, double pred5h, double predWeekly)
        {
            double minPred = Math.Min(pred5h, predWeekly);

            if (minPred <= 15.0)
            {
                return StatusLevel.Danger;
            }

            if (speed5h >= 20.0 || minPred <= 25.0)
            {
                return StatusLevel.Warning;
            }

            return StatusLevel.Normal;
        }

        private static void InitTrayIcon()
        {
            _notifyIcon = new NotifyIcon();
            _notifyIcon.Visible = true;
            _notifyIcon.Text = "Antigravity Token Monitor v4.3";

            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem itemStatus = new ToolStripMenuItem("📊 실시간 현황 (Status)");
            itemStatus.Font = new Font("맑은 고딕", 9, FontStyle.Bold);
            itemStatus.Click += delegate(object sender, EventArgs e) { ShowStatusDialog(); };
            menu.Items.Add(itemStatus);

            ToolStripMenuItem itemCalib = new ToolStripMenuItem("🎯 주간 설정 & 배율 보정");
            itemCalib.Click += delegate(object sender, EventArgs e) { ShowWeeklyCalibrationDialog(); };
            menu.Items.Add(itemCalib);

            ToolStripMenuItem itemCheck = new ToolStripMenuItem("🔄 지금 갱신 (Check Now)");
            itemCheck.Click += delegate(object sender, EventArgs e) { PerformCheck(); };
            menu.Items.Add(itemCheck);

            ToolStripMenuItem itemLogs = new ToolStripMenuItem("📂 로그 폴더 열기 (Open Logs)");
            itemLogs.Click += delegate(object sender, EventArgs e) { try { Process.Start(_logsDir); } catch { } };
            menu.Items.Add(itemLogs);

            ToolStripMenuItem itemConfig = new ToolStripMenuItem("⚙️ 설정 파일 열기 (Edit Config)");
            itemConfig.Click += delegate(object sender, EventArgs e) { try { Process.Start(Path.Combine(_appDir, "config.json")); } catch { } };
            menu.Items.Add(itemConfig);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem itemExit = new ToolStripMenuItem("❌ 종료 (Exit)");
            itemExit.Click += delegate(object sender, EventArgs e)
            {
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
                Application.Exit();
            };
            menu.Items.Add(itemExit);

            _notifyIcon.ContextMenuStrip = menu;
            _notifyIcon.DoubleClick += delegate(object sender, EventArgs e) { ShowStatusDialog(); };

            UpdateTrayUI();
        }

        private static void UpdateTrayUI()
        {
            if (_notifyIcon == null) return;

            if (_notifyIcon.ContextMenuStrip != null && _notifyIcon.ContextMenuStrip.InvokeRequired)
            {
                _notifyIcon.ContextMenuStrip.BeginInvoke(new Action(UpdateTrayUI));
                return;
            }

            int displayPct = (int)Math.Round(_state.Remaining5HourPercent);
            Color bgColor;
            Color borderColor;
            Color textColor = Color.White;
            string statusStr;

            switch (_state.CurrentStatus)
            {
                case StatusLevel.Danger:
                    bgColor = Color.FromArgb(231, 76, 60);
                    borderColor = Color.FromArgb(192, 57, 43);
                    statusStr = "DANGER";
                    break;
                case StatusLevel.Warning:
                    bgColor = Color.FromArgb(230, 126, 34);
                    borderColor = Color.FromArgb(211, 84, 0);
                    statusStr = "WARNING";
                    break;
                case StatusLevel.Error:
                    bgColor = Color.FromArgb(127, 140, 141);
                    borderColor = Color.FromArgb(44, 62, 80);
                    statusStr = "ERROR";
                    break;
                default:
                    bgColor = Color.FromArgb(46, 204, 113);
                    borderColor = Color.FromArgb(39, 174, 96);
                    statusStr = "NORMAL";
                    break;
            }

            using (Bitmap bmp = new Bitmap(32, 32))
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
                g.Clear(Color.Transparent);

                using (Brush fillBrush = new SolidBrush(bgColor))
                using (Pen borderPen = new Pen(borderColor, 2))
                {
                    g.FillRectangle(fillBrush, 1, 2, 30, 28);
                    g.DrawRectangle(borderPen, 1, 2, 30, 28);
                }

                string txt = _state.CurrentStatus == StatusLevel.Error ? "ERR" : displayPct.ToString();
                using (Font font = new Font("Arial", _state.CurrentStatus == StatusLevel.Error ? 8.5f : 9.5f, FontStyle.Bold))
                using (Brush textBrush = new SolidBrush(textColor))
                using (Brush shadowBrush = new SolidBrush(Color.FromArgb(150, 0, 0, 0)))
                {
                    SizeF sz = g.MeasureString(txt, font);
                    float px = (32 - sz.Width) / 2f;
                    float py = (32 - sz.Height) / 2f;

                    g.DrawString(txt, font, shadowBrush, px + 1, py + 1);
                    g.DrawString(txt, font, textBrush, px, py);
                }

                IntPtr hIcon = bmp.GetHicon();
                using (Icon tempIcon = Icon.FromHandle(hIcon))
                {
                    Icon oldIcon = _notifyIcon.Icon;
                    _notifyIcon.Icon = (Icon)tempIcon.Clone();
                    if (oldIcon != null)
                    {
                        try { oldIcon.Dispose(); } catch { }
                    }
                }
                NativeMethods.DestroyIcon(hIcon);
            }

            string tip;
            if (_state.CurrentStatus == StatusLevel.Error)
            {
                tip = "Antigravity Token Monitor [오류] CLI/서버 확인 필요";
            }
            else
            {
                tip = string.Format("AGY 5h:{0}%({1:F1}%/h) | Wk:{2:F0}% | {3} | P5h:{4:F0}% PWk:{5:F0}%",
                    displayPct, _state.ConsumptionSpeed5h, _state.RemainingWeeklyPercent, statusStr,
                    _state.Predicted5HourRemaining, _state.PredictedWeeklyRemaining);
            }

            if (tip.Length > 63) tip = tip.Substring(0, 63);
            _notifyIcon.Text = tip;
        }

        private static void ShowStatusDialog()
        {
            Form form = new Form
            {
                Text = "Antigravity Token Monitor v4.3 - 실시간 현황",
                Size = new Size(640, 560),
                StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedSingle,
                MaximizeBox = false,
                BackColor = Color.FromArgb(25, 27, 32)
            };

            TextBox tb = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                WordWrap = false,
                ScrollBars = ScrollBars.Both,
                Font = new Font("Consolas", 10),
                BackColor = Color.FromArgb(30, 33, 40),
                ForeColor = Color.FromArgb(220, 230, 240),
                Location = new Point(12, 12),
                Size = new Size(600, 460)
            };

            Action refreshText = delegate
            {
                string statusText = string.Format(
                    "======================================================\r\n" +
                    "   Antigravity Token Monitor v4.3 - 실시간 모니터링\r\n" +
                    "======================================================\r\n" +
                    "  조회 시각   : {0}\r\n" +
                    "  상태 판별   : [{1}]\r\n" +
                    "  클라우드동기화: {2}\r\n" +
                    "\r\n" +
                    "-- 5시간 및 주간 쿼터 현황 ---------------------------\r\n" +
                    "  5시간 실측  : {3:F1} %  (공식 리셋: {4:F1}h 후, 실근무: {5:F1}h)\r\n" +
                    "  주간 잔여량 : {6:F1} %  (주간/일간 배율: {7:F1}배 적용 중)\r\n" +
                    "  5시간 소모속도 : {8:F2} %/h\r\n" +
                    "  새 주간 첫소비 : {9}\r\n" +
                    "\r\n" +
                    "-- 초기화 시점 예측 잔여량 (실근무 활동 기준) ---------\r\n" +
                    "  5시간 리셋시점 예측: {10:F2} %\r\n" +
                    "  주간  리셋시점 예측: {11:F2} %  (전체 {12}h 후, 실근무 {13:F1}h 남음, {14} {15})\r\n" +
                    "\r\n" +
                    "-- 상태 판정 기준 ------------------------------------\r\n" +
                    "  🔴 위험: 리셋 시점 잔여량 <= 15%\r\n" +
                    "  🟠 경고: 5h 속도 >= 20%/h OR 리셋 시점 잔여량 <= 25%\r\n" +
                    "  🟢 정상: 안정 범위\r\n" +
                    "======================================================\r\n" +
                    "{16}",
                    _state.LastCheckTime > DateTime.MinValue ? _state.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss") : "조회 중...",
                    _state.CurrentStatus,
                    _config.sync_enabled ? "🟢 활성화 (" + _config.sync_url + ")" : "⚪ 비활성화 (로컬 단독 모드)",
                    _state.Remaining5HourPercent,
                    _state.HoursUntil5HourReset,
                    _state.ActiveHoursUntil5HourReset,
                    _state.RemainingWeeklyPercent,
                    _config.weekly_multiplier,
                    _state.ConsumptionSpeed5h,
                    _state.WeeklyFirstActiveTimeStr,
                    _state.Predicted5HourRemaining,
                    _state.PredictedWeeklyRemaining,
                    _state.HoursUntilWeeklyReset.ToString("F1"),
                    _state.ActiveHoursUntilWeeklyReset,
                    _config.weekly_reset_day,
                    _config.weekly_reset_time,
                    string.IsNullOrEmpty(_state.LastErrorMessage) ? "" : "\r\n[최근 오류]\r\n" + _state.LastErrorMessage
                );

                tb.Text = statusText;
            };

            refreshText();
            form.Controls.Add(tb);

            Button btnRefresh = new Button
            {
                Text = "지금 갱신",
                Location = new Point(12, 480),
                Size = new Size(110, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(52, 152, 219)
            };
            btnRefresh.Click += delegate(object sender, EventArgs e)
            {
                btnRefresh.Text = "갱신 중...";
                btnRefresh.Enabled = false;
                PerformCheck(delegate
                {
                    try
                    {
                        if (form != null && !form.IsDisposed)
                        {
                            form.BeginInvoke(new Action(delegate
                            {
                                refreshText();
                                btnRefresh.Text = "지금 갱신";
                                btnRefresh.Enabled = true;
                            }));
                        }
                    }
                    catch { }
                });
            };
            form.Controls.Add(btnRefresh);

            Button btnCalib = new Button
            {
                Text = "주간 % 보정",
                Location = new Point(130, 480),
                Size = new Size(110, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(46, 204, 113)
            };
            btnCalib.Click += delegate(object sender, EventArgs e) { ShowWeeklyCalibrationDialog(); refreshText(); };
            form.Controls.Add(btnCalib);

            Button btnClose = new Button
            {
                Text = "닫기",
                Location = new Point(522, 480),
                Size = new Size(90, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(100, 100, 100)
            };
            btnClose.Click += delegate(object sender, EventArgs e) { form.Close(); };
            form.Controls.Add(btnClose);

            form.ShowDialog();
            TrimMemory();
        }

        private static void ShowWeeklyCalibrationDialog()
        {
            Form f = new Form
            {
                Text = "주간 쿼터 설정 & 배율 보정 (v4.3)",
                Size = new Size(520, 560),
                StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                BackColor = Color.FromArgb(28, 30, 36)
            };

            // 1. 주간 잔여 % 및 배율 보정 그룹
            GroupBox gbCalib = new GroupBox
            {
                Text = "🎯 [기능 1] 주간 잔여 % 보정 & 배율 수동/자동 조절",
                Location = new Point(15, 15),
                Size = new Size(475, 230),
                ForeColor = Color.FromArgb(255, 200, 100),
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Bold)
            };

            Label lblInfo = new Label
            {
                Text = string.Format("공식 웹에서 확인한 [현재 주간 잔여 %]를 입력하세요.\r\n(5h 실측: {0:F1}%, 리셋: {1})\r\n※ 동일 5시간 세션 내에서 2회 이상 입력 시 배율이 자동 조절됩니다.",
                    _state.Remaining5HourPercent, string.IsNullOrEmpty(_state.ResetTime5HourStr) ? "대기중" : _state.ResetTime5HourStr),
                Location = new Point(15, 25),
                Size = new Size(445, 55),
                ForeColor = Color.FromArgb(220, 230, 240),
                Font = new Font("맑은 고딕", 9f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblInfo);

            Label lblInput = new Label
            {
                Text = "주간 잔여 %:",
                Location = new Point(15, 88),
                Size = new Size(95, 25),
                ForeColor = Color.White,
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblInput);

            TextBox txtWk = new TextBox
            {
                Location = new Point(115, 86),
                Size = new Size(70, 25),
                Font = new Font("Consolas", 10),
                Text = _state.RemainingWeeklyPercent.ToString("F1")
            };
            gbCalib.Controls.Add(txtWk);

            Label lblUnit = new Label
            {
                Text = "%",
                Location = new Point(190, 88),
                Size = new Size(20, 25),
                ForeColor = Color.White,
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblUnit);

            Button btnSave = new Button
            {
                Text = "주간 % 보정 저장",
                Location = new Point(220, 83),
                Size = new Size(130, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(46, 204, 113),
                Font = new Font("맑은 고딕", 9f, FontStyle.Bold)
            };
            btnSave.Click += delegate(object sender, EventArgs e)
            {
                double val;
                if (double.TryParse(txtWk.Text.Trim(), out val) && val >= 0.0 && val <= 100.0)
                {
                    RecordUserWeeklyCalibration(val);
                    MessageBox.Show(f, string.Format("주간 잔여량이 {0:F1}% 로 보정되었습니다.\r\n현재 적용 주간/일간 배율: {1:F1}배", val, _config.weekly_multiplier),
                        "보정 완료", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                else
                {
                    MessageBox.Show(f, "0 ~ 100 사이의 올바른 % 숫자를 입력하세요.", "입력 오류", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            };
            gbCalib.Controls.Add(btnSave);

            // 배율 직접 수정 영역
            Label lblMult = new Label
            {
                Text = "적용 배율:",
                Location = new Point(15, 135),
                Size = new Size(95, 25),
                ForeColor = Color.FromArgb(200, 220, 255),
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblMult);

            TextBox txtMult = new TextBox
            {
                Location = new Point(115, 133),
                Size = new Size(70, 25),
                Font = new Font("Consolas", 10),
                Text = _config.weekly_multiplier.ToString("F1")
            };
            gbCalib.Controls.Add(txtMult);

            Label lblMultUnit = new Label
            {
                Text = "배",
                Location = new Point(190, 135),
                Size = new Size(25, 25),
                ForeColor = Color.White,
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblMultUnit);

            Button btnSaveMult = new Button
            {
                Text = "배율 직접 적용",
                Location = new Point(220, 130),
                Size = new Size(130, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(52, 152, 219),
                Font = new Font("맑은 고딕", 9f, FontStyle.Bold)
            };
            btnSaveMult.Click += delegate(object sender, EventArgs e)
            {
                double mVal;
                if (double.TryParse(txtMult.Text.Trim(), out mVal) && mVal >= 1.0 && mVal <= 500.0)
                {
                    _config.weekly_multiplier = Math.Round(mVal, 2);
                    SaveConfig(_config);
                    PerformCheck();
                    MessageBox.Show(f, string.Format("주간/일간 배율이 {0:F1}배로 직접 설정되었습니다.", _config.weekly_multiplier),
                        "배율 설정 완료", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                else
                {
                    MessageBox.Show(f, "1.0 ~ 500.0 사이의 올바른 배율 숫자를 입력하세요.", "입력 오류", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            };
            gbCalib.Controls.Add(btnSaveMult);

            Label lblCycleInfo = new Label
            {
                Text = string.Format("🌱 이번 주 첫 토큰 소비 시점: {0}", _state.WeeklyFirstActiveTimeStr),
                Location = new Point(15, 185),
                Size = new Size(445, 25),
                ForeColor = Color.FromArgb(150, 230, 150),
                Font = new Font("맑은 고딕", 9f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblCycleInfo);

            f.Controls.Add(gbCalib);

            // 2. 주간 초기화 시간 간편 맞춤 그룹
            GroupBox gbTime = new GroupBox
            {
                Text = "⏰ [기능 2] 주간 리셋 시간 간편 맞춤 (남은 시간 입력)",
                Location = new Point(15, 255),
                Size = new Size(475, 200),
                ForeColor = Color.FromArgb(100, 200, 255),
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Bold)
            };

            Label lblTimeGuide = new Label
            {
                Text = "웹 UI에 표시된 [주간 쿼터 남은 시간]을 입력하면\r\n초기화 요일과 시각을 자동 계산하여 config에 저장합니다.",
                Location = new Point(15, 25),
                Size = new Size(445, 40),
                ForeColor = Color.FromArgb(220, 230, 240),
                Font = new Font("맑은 고딕", 9f, FontStyle.Regular)
            };
            gbTime.Controls.Add(lblTimeGuide);

            Label lblCurSetting = new Label
            {
                Text = string.Format("현재 설정: 매주 {0} {1} (리셋까지 약 {2:F1}시간 남음)",
                    _config.weekly_reset_day, _config.weekly_reset_time, _state.HoursUntilWeeklyReset),
                Location = new Point(15, 70),
                Size = new Size(445, 25),
                ForeColor = Color.FromArgb(180, 220, 255),
                Font = new Font("맑은 고딕", 9f, FontStyle.Regular)
            };
            gbTime.Controls.Add(lblCurSetting);

            TextBox txtDays = new TextBox { Location = new Point(15, 105), Size = new Size(45, 25), Font = new Font("Consolas", 10), Text = "2" };
            Label lblD = new Label { Text = "일", Location = new Point(63, 107), Size = new Size(20, 25), ForeColor = Color.White, Font = new Font("맑은 고딕", 9.5f) };
            TextBox txtHours = new TextBox { Location = new Point(88, 105), Size = new Size(45, 25), Font = new Font("Consolas", 10), Text = "5" };
            Label lblH = new Label { Text = "시간", Location = new Point(136, 107), Size = new Size(35, 25), ForeColor = Color.White, Font = new Font("맑은 고딕", 9.5f) };
            TextBox txtMins = new TextBox { Location = new Point(175, 105), Size = new Size(45, 25), Font = new Font("Consolas", 10), Text = "30" };
            Label lblM = new Label { Text = "분 남음", Location = new Point(223, 107), Size = new Size(55, 25), ForeColor = Color.White, Font = new Font("맑은 고딕", 9.5f) };

            gbTime.Controls.Add(txtDays);
            gbTime.Controls.Add(lblD);
            gbTime.Controls.Add(txtHours);
            gbTime.Controls.Add(lblH);
            gbTime.Controls.Add(txtMins);
            gbTime.Controls.Add(lblM);

            Button btnApplyTime = new Button
            {
                Text = "리셋 시각 계산 및 적용",
                Location = new Point(290, 102),
                Size = new Size(165, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(52, 152, 219),
                Font = new Font("맑은 고딕", 9f, FontStyle.Bold)
            };
            btnApplyTime.Click += delegate(object sender, EventArgs e)
            {
                int d = 0, h = 0, m = 0;
                int.TryParse(txtDays.Text.Trim(), out d);
                int.TryParse(txtHours.Text.Trim(), out h);
                int.TryParse(txtMins.Text.Trim(), out m);

                if (d < 0) d = 0;
                if (h < 0) h = 0;
                if (m < 0) m = 0;

                if (d == 0 && h == 0 && m == 0)
                {
                    MessageBox.Show(f, "남은 시간(일/시간/분)을 올바르게 입력하세요.", "입력 오류", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                DateTime targetTime = DateTime.Now.AddDays(d).AddHours(h).AddMinutes(m);
                _config.weekly_reset_day = targetTime.DayOfWeek.ToString();
                _config.weekly_reset_time = targetTime.ToString("HH:mm");
                SaveConfig(_config);

                PerformCheck();

                lblCurSetting.Text = string.Format("현재 설정: 매주 {0} {1} (리셋까지 약 {2:F1}시간 남음)",
                    _config.weekly_reset_day, _config.weekly_reset_time, _state.HoursUntilWeeklyReset);

                WriteSystemLog("INFO", string.Format("주간 리셋 시각 간편 설정 완료: 매주 {0} {1} ({2}일 {3}시간 {4}분 후 기준)",
                    _config.weekly_reset_day, _config.weekly_reset_time, d, h, m));

                MessageBox.Show(f, string.Format("주간 리셋 시각이 성공적으로 계산되어 적용되었습니다!\r\n\r\n- 요일: {0}\r\n- 시간: {1}\r\n- 다음 리셋: {2:yyyy-MM-dd HH:mm}",
                    _config.weekly_reset_day, _config.weekly_reset_time, targetTime),
                    "리셋 시각 설정 완료", MessageBoxButtons.OK, MessageBoxIcon.Information);
            };
            gbTime.Controls.Add(btnApplyTime);
            f.Controls.Add(gbTime);

            Button btnClose = new Button
            {
                Text = "닫기",
                Location = new Point(400, 475),
                Size = new Size(90, 32),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(100, 100, 100)
            };
            btnClose.Click += delegate(object sender, EventArgs e) { f.Close(); };
            f.Controls.Add(btnClose);

            f.ShowDialog();
            TrimMemory();
        }
    }
}
