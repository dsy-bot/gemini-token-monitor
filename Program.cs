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
        public string daily_reset_time { get; set; }
        public string weekly_reset_day { get; set; }
        public string weekly_reset_time { get; set; }
        public double weekly_multiplier { get; set; }

        public AppConfig()
        {
            interval_minutes = 10;
            daily_reset_time = "00:00";
            weekly_reset_day = "Monday";
            weekly_reset_time = "00:00";
            weekly_multiplier = 30.9;
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
        public string ResetTime5HourStr { get; set; }
        public StatusLevel CurrentStatus { get; set; }
        public DateTime LastCheckTime { get; set; }
        public string LastErrorMessage { get; set; }
        public string RawJson { get; set; }

        public MonitorState()
        {
            Remaining5HourPercent = 100.0;
            RemainingWeeklyPercent = 100.0;
            ConsumptionSpeed5h = 0.0;
            Predicted5HourRemaining = 100.0;
            PredictedWeeklyRemaining = 100.0;
            HoursUntil5HourReset = 5.0;
            HoursUntilWeeklyReset = 168.0;
            ResetTime5HourStr = string.Empty;
            CurrentStatus = StatusLevel.Normal;
            LastCheckTime = DateTime.MinValue;
            LastErrorMessage = string.Empty;
            RawJson = string.Empty;
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

            WriteSystemLog("INFO", "Antigravity Token Monitor v3.0 시작");

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
                    string json = File.ReadAllText(configPath, System.Text.Encoding.UTF8);
                    AppConfig cfg = _jsonSerializer.Deserialize<AppConfig>(json);
                    if (cfg != null)
                    {
                        if (cfg.weekly_multiplier <= 0.0) cfg.weekly_multiplier = 30.9;
                        return cfg;
                    }
                }
                catch (Exception ex)
                {
                    WriteSystemLog("ERROR", "config.json 로드 실패: " + ex.Message);
                }
            }
            AppConfig defaultCfg = new AppConfig();
            SaveConfig(defaultCfg);
            return defaultCfg;
        }

        private static void SaveConfig(AppConfig cfg)
        {
            try
            {
                string configPath = Path.Combine(_appDir, "config.json");
                string json = _jsonSerializer.Serialize(cfg);
                File.WriteAllText(configPath, json, System.Text.Encoding.UTF8);
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

        private static void WriteSpeedLog(double speed5h, double t5h, double pred5h, double tWk, double predWk, StatusLevel status)
        {
            try
            {
                DateTime now = DateTime.Now;
                string fileName = string.Format("{0}_speed.log", now.ToString("yyyyMMdd"));
                string filePath = Path.Combine(_speedDir, fileName);
                string line = string.Format("[{0}] Speed5h={1:F2}%/h, 5hResetIn={2:F2}h, Pred5hRem={3:F2}%, WkResetIn={4:F2}h, PredWkRem={5:F2}%, Status={6}",
                    now.ToString("HH:mm:ss"), speed5h, t5h, pred5h, tWk, predWk, status);
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

                    double remWk = CalculateEstimatedWeeklyPercent(rem5h);
                    _state.RemainingWeeklyPercent = remWk;

                    WriteUsageLog(rem5h, remWk, _state.RawJson);

                    double speed5h = Calculate5HourConsumptionSpeed(rem5h);
                    _state.ConsumptionSpeed5h = speed5h;

                    double t5h;
                    double tWeekly;
                    CalculateResetHours(resetTimeStr, out t5h, out tWeekly);
                    _state.HoursUntil5HourReset = t5h;
                    _state.HoursUntilWeeklyReset = tWeekly;

                    double speedWk = _config.weekly_multiplier > 0 ? (speed5h / _config.weekly_multiplier) : speed5h;
                    _state.Predicted5HourRemaining = Math.Max(0.0, rem5h - (speed5h * t5h));
                    _state.PredictedWeeklyRemaining = Math.Max(0.0, remWk - (speedWk * tWeekly));

                    StatusLevel newStatus = DetermineStatus(speed5h, _state.Predicted5HourRemaining, _state.PredictedWeeklyRemaining);
                    if (_state.CurrentStatus != newStatus)
                    {
                        WriteSystemLog("INFO", string.Format("트레이 상태 변경: {0} -> {1}", _state.CurrentStatus, newStatus));
                    }
                    _state.CurrentStatus = newStatus;

                    WriteSpeedLog(speed5h, t5h, _state.Predicted5HourRemaining, tWeekly, _state.PredictedWeeklyRemaining, newStatus);

                    UpdateTrayUI();
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
                }
            };

            action.BeginInvoke(null, null);
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
                {
                    foreach (ManagementObject obj in searcher.Get())
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
                                    foreach (object m in models)
                                    {
                                        Dictionary<string, object> mDict = m as Dictionary<string, object>;
                                        if (mDict != null && mDict.ContainsKey("quotaInfo"))
                                        {
                                            Dictionary<string, object> qInfo = mDict["quotaInfo"] as Dictionary<string, object>;
                                            if (qInfo != null)
                                            {
                                                if (qInfo.ContainsKey("resetTime") && qInfo["resetTime"] != null)
                                                {
                                                    resetTimeStr = Convert.ToString(qInfo["resetTime"]);
                                                }
                                                if (qInfo.ContainsKey("remainingFraction") && qInfo["remainingFraction"] != null)
                                                {
                                                    return Math.Round(Convert.ToDouble(qInfo["remainingFraction"]) * 100.0, 1);
                                                }
                                            }
                                        }
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

        private static double CalculateEstimatedWeeklyPercent(double current5hRemPct)
        {
            double mult = _config.weekly_multiplier > 0 ? _config.weekly_multiplier : 30.9;
            double consumed5h = Math.Max(0.0, 100.0 - current5hRemPct);

            if (_calibHistory != null && _calibHistory.Count > 0)
            {
                WeeklyCalibPoint lastPoint = _calibHistory[_calibHistory.Count - 1];
                double delta5hSinceCalib = Math.Max(0.0, lastPoint.FiveHourPercent - current5hRemPct);
                double deltaWkSinceCalib = delta5hSinceCalib / mult;
                return Math.Max(0.0, Math.Min(100.0, lastPoint.UserWeeklyPercent - deltaWkSinceCalib));
            }

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

                if (_calibHistory != null && _calibHistory.Count > 0)
                {
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

                        if (delta5h >= 2.0 && deltaWk >= 0.1)
                        {
                            double calculatedMultiplier = Math.Round(delta5h / deltaWk, 2);
                            if (calculatedMultiplier >= 5.0 && calculatedMultiplier <= 150.0)
                            {
                                _config.weekly_multiplier = calculatedMultiplier;
                                SaveConfig(_config);
                                WriteSystemLog("INFO", string.Format("주간/일간 배율 자동보정 완료: {0}배 (5h소모: {1:F1}%, 주간소모: {2:F1}%)",
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
            }
            catch (Exception ex)
            {
                WriteSystemLog("ERROR", "주간 보정 저장 실패: " + ex.Message);
            }
        }

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

        private static void CalculateResetHours(string resetTimeIso, out double hours5h, out double hoursWeekly)
        {
            DateTime now = DateTime.Now;

            hours5h = 5.0;
            if (!string.IsNullOrEmpty(resetTimeIso))
            {
                try
                {
                    DateTime parsedUtc = DateTime.Parse(resetTimeIso).ToUniversalTime();
                    DateTime parsedLocal = parsedUtc.ToLocalTime();
                    if (parsedLocal > now)
                    {
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
            hoursWeekly = Math.Max(0.1, (nextWeekly - now).TotalHours);
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
            _notifyIcon.Text = "Antigravity Token Monitor v3.0";

            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem itemStatus = new ToolStripMenuItem("📊 실시간 현황 (Status)");
            itemStatus.Font = new Font("맑은 고딕", 9, FontStyle.Bold);
            itemStatus.Click += delegate(object sender, EventArgs e) { ShowStatusDialog(); };
            menu.Items.Add(itemStatus);

            ToolStripMenuItem itemCalib = new ToolStripMenuItem("🎯 주간 잔여 % 입력 & 배율 자동보정");
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
                    _notifyIcon.Icon = (Icon)tempIcon.Clone();
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
                Text = "Antigravity Token Monitor v3.0 - 실시간 현황",
                Size = new Size(640, 540),
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
                Size = new Size(600, 440)
            };

            Action refreshText = delegate
            {
                string statusText = string.Format(
                    "======================================================\r\n" +
                    "   Antigravity Token Monitor v3.0 - 실시간 모니터링\r\n" +
                    "======================================================\r\n" +
                    "  조회 시각   : {0}\r\n" +
                    "  상태 판별   : [{1}]\r\n" +
                    "\r\n" +
                    "-- 5시간 및 주간 쿼터 현황 ---------------------------\r\n" +
                    "  5시간 실측  : {2:F1} %  (공식 리셋: {3:F1}시간 남음, {4})\r\n" +
                    "  주간 잔여량 : {5:F1} %  (주간/일간 배율: {6:F1}배 적용 중)\r\n" +
                    "  5시간 소모속도 : {7:F2} %/h\r\n" +
                    "\r\n" +
                    "-- 초기화 시점 예측 잔여량 ---------------------------\r\n" +
                    "  5시간 리셋시점 예측: {8:F2} %\r\n" +
                    "  주간  리셋시점 예측: {9:F2} %  ({10}시간 후, {11} {12})\r\n" +
                    "\r\n" +
                    "-- 상태 판정 기준 ------------------------------------\r\n" +
                    "  🔴 위험: 리셋 시점 잔여량 <= 15%\r\n" +
                    "  🟠 경고: 5h 속도 >= 20%/h OR 리셋 시점 잔여량 <= 25%\r\n" +
                    "  🟢 정상: 안정 범위\r\n" +
                    "======================================================\r\n" +
                    "{13}",
                    _state.LastCheckTime > DateTime.MinValue ? _state.LastCheckTime.ToString("yyyy-MM-dd HH:mm:ss") : "조회 중...",
                    _state.CurrentStatus,
                    _state.Remaining5HourPercent,
                    _state.HoursUntil5HourReset,
                    string.IsNullOrEmpty(_state.ResetTime5HourStr) ? "대기중" : _state.ResetTime5HourStr,
                    _state.RemainingWeeklyPercent,
                    _config.weekly_multiplier,
                    _state.ConsumptionSpeed5h,
                    _state.Predicted5HourRemaining,
                    _state.PredictedWeeklyRemaining,
                    _state.HoursUntilWeeklyReset.ToString("F1"),
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
                Location = new Point(12, 460),
                Size = new Size(110, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(52, 152, 219)
            };
            btnRefresh.Click += delegate(object sender, EventArgs e) { PerformCheck(); refreshText(); };
            form.Controls.Add(btnRefresh);

            Button btnCalib = new Button
            {
                Text = "주간 % 보정",
                Location = new Point(130, 460),
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
                Location = new Point(522, 460),
                Size = new Size(90, 30),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(100, 100, 100)
            };
            btnClose.Click += delegate(object sender, EventArgs e) { form.Close(); };
            form.Controls.Add(btnClose);

            form.ShowDialog();
        }

        private static void ShowWeeklyCalibrationDialog()
        {
            Form f = new Form
            {
                Text = "주간 쿼터 설정 & 배율 보정 (v3.0)",
                Size = new Size(520, 520),
                StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                BackColor = Color.FromArgb(28, 30, 36)
            };

            // 1. 주간 잔여 % 및 배율 보정 그룹
            GroupBox gbCalib = new GroupBox
            {
                Text = "🎯 [기능 1] 주간 잔여 % 보정 & 배율 자동 조절",
                Location = new Point(15, 15),
                Size = new Size(475, 190),
                ForeColor = Color.FromArgb(255, 200, 100),
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Bold)
            };

            Label lblInfo = new Label
            {
                Text = string.Format("공식 웹에서 확인한 [현재 주간 잔여 %]를 입력하세요.\r\n(5h 실측: {0:F1}%, 리셋: {1} | 적용 배율: {2:F1}배)\r\n※ 동일 5시간 세션 내에서 2회 이상 입력 시 배율이 자동 조절됩니다.",
                    _state.Remaining5HourPercent, string.IsNullOrEmpty(_state.ResetTime5HourStr) ? "대기중" : _state.ResetTime5HourStr, _config.weekly_multiplier),
                Location = new Point(15, 25),
                Size = new Size(445, 60),
                ForeColor = Color.FromArgb(220, 230, 240),
                Font = new Font("맑은 고딕", 9f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblInfo);

            Label lblInput = new Label
            {
                Text = "주간 잔여 %:",
                Location = new Point(15, 95),
                Size = new Size(100, 25),
                ForeColor = Color.White,
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblInput);

            TextBox txtWk = new TextBox
            {
                Location = new Point(120, 93),
                Size = new Size(90, 25),
                Font = new Font("Consolas", 10),
                Text = _state.RemainingWeeklyPercent.ToString("F1")
            };
            gbCalib.Controls.Add(txtWk);

            Label lblUnit = new Label
            {
                Text = "%",
                Location = new Point(215, 95),
                Size = new Size(25, 25),
                ForeColor = Color.White,
                Font = new Font("맑은 고딕", 9.5f, FontStyle.Regular)
            };
            gbCalib.Controls.Add(lblUnit);

            Button btnSave = new Button
            {
                Text = "주간 % 보정 저장",
                Location = new Point(255, 90),
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
                    lblInfo.Text = string.Format("공식 웹에서 확인한 [현재 주간 잔여 %]를 입력하세요.\r\n(5h 실측: {0:F1}%, 리셋: {1} | 적용 배율: {2:F1}배)\r\n※ 동일 5시간 세션 내에서 2회 이상 입력 시 배율이 자동 조절됩니다.",
                        _state.Remaining5HourPercent, string.IsNullOrEmpty(_state.ResetTime5HourStr) ? "대기중" : _state.ResetTime5HourStr, _config.weekly_multiplier);
                }
                else
                {
                    MessageBox.Show(f, "0 ~ 100 사이의 올바른 % 숫자를 입력하세요.", "입력 오류", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            };
            gbCalib.Controls.Add(btnSave);
            f.Controls.Add(gbCalib);

            // 2. 주간 초기화 시간 간편 맞춤 그룹
            GroupBox gbTime = new GroupBox
            {
                Text = "⏰ [기능 2] 주간 리셋 시간 간편 맞춤 (남은 시간 입력)",
                Location = new Point(15, 220),
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

            // 일, 시간, 분 입력
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
                Location = new Point(400, 435),
                Size = new Size(90, 32),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(100, 100, 100)
            };
            btnClose.Click += delegate(object sender, EventArgs e) { f.Close(); };
            f.Controls.Add(btnClose);

            f.ShowDialog();
        }
    }
}
