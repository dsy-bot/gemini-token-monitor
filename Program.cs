using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Management;
using System.Net;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

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

    public class ModelThreshold
    {
        public bool enabled { get; set; }
        public double warning_remaining_5h { get; set; }
        public double danger_remaining_5h { get; set; }
        public double warning_remaining_1w { get; set; }
        public double danger_remaining_1w { get; set; }
        public double warning_speed_5h { get; set; }
        public double danger_speed_5h { get; set; }
        public double warning_speed_1w { get; set; }
        public double danger_speed_1w { get; set; }

        public ModelThreshold()
        {
            enabled = true;
            warning_remaining_5h = 20.0;
            danger_remaining_5h = 10.0;
            warning_remaining_1w = 25.0;
            danger_remaining_1w = 10.0;
            warning_speed_5h = 20.0;
            danger_speed_5h = 40.0;
            warning_speed_1w = 3.0;
            danger_speed_1w = 6.0;
        }
    }

    public class AppConfig
    {
        public int interval_seconds { get; set; }
        public int interval_minutes { get; set; }
        public int speed_window_seconds { get; set; }
        public Dictionary<string, string> work_schedule { get; set; }
        public Dictionary<string, ModelThreshold> model_thresholds { get; set; }

        public AppConfig()
        {
            interval_seconds = 60;
            speed_window_seconds = 3600; // 기본 1시간 윈도우
            work_schedule = new Dictionary<string, string>();
            string[] days = new string[] { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday" };
            foreach (string d in days) work_schedule[d] = "09:00-18:00";
            work_schedule["Saturday"] = "off";
            work_schedule["Sunday"] = "off";
            model_thresholds = new Dictionary<string, ModelThreshold>();
        }

        public int GetEffectiveIntervalSeconds()
        {
            if (interval_seconds > 0) return Math.Max(5, interval_seconds);
            if (interval_minutes > 0) return Math.Max(5, interval_minutes * 60);
            return 60;
        }

        public int GetEffectiveSpeedWindowSeconds()
        {
            if (speed_window_seconds > 0) return Math.Max(60, speed_window_seconds);
            return 3600;
        }
    }

    public class QuotaBucket
    {
        public string BucketId;
        public string DisplayName;
        public string Window; // "5h" or "weekly"
        public double RemainingPercent; // 원본 정밀도 유지 (0 ~ 100)
        public DateTime ResetTime;
        public double SpeedPerHour; // %/h
        public double PredictedRemainingPercent; // after remaining work hours
    }

    public class QuotaGroup
    {
        public string DisplayName;
        public Dictionary<string, QuotaBucket> Buckets = new Dictionary<string, QuotaBucket>();
    }

    public class HistoryPoint
    {
        public DateTime Timestamp;
        public Dictionary<string, double> BucketPercents = new Dictionary<string, double>();
    }

    static class Program
    {
        private static NotifyIcon _notifyIcon;
        private static System.Windows.Forms.Timer _timer;
        private static AppConfig _config;
        private static JavaScriptSerializer _jsonSerializer;

        private static string _appDir;
        private static string _configDir;
        private static string _logsDir;
        private static string _usageDir;
        private static string _systemDir;

        private static bool _isChecking = false;
        private static StatusLevel _currentStatus = StatusLevel.Normal;
        private static DateTime _lastCheckTime = DateTime.MinValue;
        private static List<QuotaGroup> _latestGroups = new List<QuotaGroup>();

        // 메모리 상의 최근 이력 보관 (N시간 속도 계산용)
        private static List<HistoryPoint> _history = new List<HistoryPoint>();

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
            _systemDir = Path.Combine(_logsDir, "system");

            EnsureDirectories();
            _jsonSerializer = new JavaScriptSerializer();
            _config = LoadConfig();

            // 당일 기존 CSV 로그가 있다면 최근 이력 복원
            LoadHistoryFromCsv();

            WriteSystemLog("INFO", "Antigravity Token Monitor v5.0 시작");

            InitTrayIcon();

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = _config.GetEffectiveIntervalSeconds() * 1000;
            _timer.Tick += delegate(object sender, EventArgs e) { PerformCheck(); };
            _timer.Start();

            PerformCheck();

            Application.Run();
        }

        private static void EnsureDirectories()
        {
            if (!Directory.Exists(_configDir)) Directory.CreateDirectory(_configDir);
            if (!Directory.Exists(_usageDir)) Directory.CreateDirectory(_usageDir);
            if (!Directory.Exists(_systemDir)) Directory.CreateDirectory(_systemDir);
        }

        private static AppConfig LoadConfig()
        {
            try
            {
                string configPath = Path.Combine(_appDir, "config.json");
                if (File.Exists(configPath))
                {
                    string json = File.ReadAllText(configPath, System.Text.Encoding.UTF8);
                    AppConfig cfg = _jsonSerializer.Deserialize<AppConfig>(json);
                    if (cfg != null)
                    {
                        if (cfg.work_schedule == null) cfg.work_schedule = new Dictionary<string, string>();
                        if (cfg.model_thresholds == null) cfg.model_thresholds = new Dictionary<string, ModelThreshold>();
                        return cfg;
                    }
                }
            }
            catch { }

            return new AppConfig();
        }

        private static void WriteSystemLog(string level, string message)
        {
            try
            {
                DateTime now = DateTime.Now;
                string filePath = Path.Combine(_systemDir, string.Format("{0}_system.log", now.ToString("yyyyMMdd")));
                string line = string.Format("[{0}] [{1}] {2}", now.ToString("HH:mm:ss"), level, message);
                File.AppendAllLines(filePath, new string[] { line }, System.Text.Encoding.UTF8);
            }
            catch { }
        }

        // CSV 파일에 순수 실측 소수점 값 기록
        private static void AppendQuotaCsv(DateTime now, double gemini5h, double geminiWk, double argonWk, double claude5h, double claudeWk)
        {
            try
            {
                string filePath = Path.Combine(_usageDir, string.Format("{0}_usage.csv", now.ToString("yyyyMMdd")));
                bool fileExists = File.Exists(filePath);

                using (StreamWriter sw = new StreamWriter(filePath, true, System.Text.Encoding.UTF8))
                {
                    if (!fileExists)
                    {
                        sw.WriteLine("timestamp,gemini_5h,gemini_weekly,argon_weekly,claude_5h,claude_weekly");
                    }
                    sw.WriteLine(string.Format("{0:yyyy-MM-dd HH:mm:ss},{1:F6},{2:F6},{3:F6},{4:F6},{5:F6}",
                        now, gemini5h, geminiWk, argonWk, claude5h, claudeWk));
                }
            }
            catch { }
        }

        // CSV에서 당일 최근 이력 복원
        private static void LoadHistoryFromCsv()
        {
            try
            {
                DateTime now = DateTime.Now;
                string filePath = Path.Combine(_usageDir, string.Format("{0}_usage.csv", now.ToString("yyyyMMdd")));
                if (!File.Exists(filePath)) return;

                string[] lines = File.ReadAllLines(filePath, System.Text.Encoding.UTF8);
                if (lines.Length <= 1) return;

                for (int i = 1; i < lines.Length; i++)
                {
                    string line = lines[i].Trim();
                    if (string.IsNullOrEmpty(line)) continue;

                    string[] parts = line.Split(',');
                    if (parts.Length >= 6)
                    {
                        DateTime ts;
                        double g5, gw, aw, c5, cw;
                        if (DateTime.TryParse(parts[0], out ts) &&
                            double.TryParse(parts[1], out g5) &&
                            double.TryParse(parts[2], out gw) &&
                            double.TryParse(parts[3], out aw) &&
                            double.TryParse(parts[4], out c5) &&
                            double.TryParse(parts[5], out cw))
                        {
                            HistoryPoint hp = new HistoryPoint { Timestamp = ts };
                            hp.BucketPercents["gemini-5h"] = g5;
                            hp.BucketPercents["gemini-weekly"] = gw;
                            hp.BucketPercents["gemini-argon-wtu-weekly"] = aw;
                            hp.BucketPercents["3p-5h"] = c5;
                            hp.BucketPercents["3p-weekly"] = cw;
                            _history.Add(hp);
                        }
                    }
                }

                TrimHistoryMemory();
            }
            catch { }
        }

        private static void TrimHistoryMemory()
        {
            if (_history.Count == 0) return;
            DateTime cutoff = DateTime.Now.AddHours(-12.0); // 최근 12시간까지만 메모리에 보관
            _history.RemoveAll(delegate(HistoryPoint p) { return p.Timestamp < cutoff; });
        }

        private static string FetchQuotaSummaryJson()
        {
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
                                if (parts.Length > 0) csrfToken = parts[0];
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
                                Match m = Regex.Match(line, @"127\.0\.0\.1:(\d+)");
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
                            string url = string.Format("https://127.0.0.1:{0}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary", p);
                            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                            req.Method = "POST";
                            req.ContentType = "application/json";
                            req.KeepAlive = false;
                            req.ServicePoint.Expect100Continue = false;
                            req.Headers.Add("Connect-Protocol-Version", "1");
                            req.Headers.Add("X-Codeium-Csrf-Token", csrfToken);
                            req.Timeout = 2500;

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
                WriteSystemLog("ERROR", "API 호출 실패: " + ex.Message);
            }

            return string.Empty;
        }

        // N시간(speed_window_seconds) 윈도우 기반 정밀 소비속도 계산
        private static double CalculateWindowSpeed(string bucketId, double currentRem, DateTime now, int windowSeconds)
        {
            if (_history == null || _history.Count == 0) return 0.0;

            DateTime targetPast = now.AddSeconds(-windowSeconds);
            HistoryPoint baselinePoint = null;

            // 윈도우 시작점에 가장 가까운 과거 유효 샘플 탐색
            for (int i = 0; i < _history.Count; i++)
            {
                var hp = _history[i];
                if (hp.BucketPercents.ContainsKey(bucketId))
                {
                    if (hp.Timestamp >= targetPast)
                    {
                        baselinePoint = hp;
                        break;
                    }
                    baselinePoint = hp; // 범위 이전 중 가장 최근 것 보관
                }
            }

            if (baselinePoint == null || !baselinePoint.BucketPercents.ContainsKey(bucketId)) return 0.0;

            double oldRem = baselinePoint.BucketPercents[bucketId];
            double deltaHours = (now - baselinePoint.Timestamp).TotalHours;

            // 경과 시간이 너무 짧거나(10초 미만) 리셋되어 잔여량이 오히려 늘어난 경우
            if (deltaHours < (10.0 / 3600.0) || currentRem > (oldRem + 0.1))
            {
                return 0.0;
            }

            double consumed = oldRem - currentRem;
            if (consumed <= 0.0) return 0.0;

            double speed = consumed / deltaHours;
            return Math.Round(speed, 2);
        }

        private static List<QuotaGroup> ParseQuotaSummary(string json, DateTime now)
        {
            List<QuotaGroup> groups = new List<QuotaGroup>();
            try
            {
                object parsed = _jsonSerializer.DeserializeObject(json);
                Dictionary<string, object> dict = parsed as Dictionary<string, object>;
                if (dict == null || !dict.ContainsKey("response")) return groups;

                Dictionary<string, object> resp = dict["response"] as Dictionary<string, object>;
                if (resp == null || !resp.ContainsKey("groups")) return groups;

                object[] groupList = resp["groups"] as object[];
                if (groupList == null) return groups;

                HistoryPoint curPoint = new HistoryPoint { Timestamp = now };
                int windowSec = _config.GetEffectiveSpeedWindowSeconds();

                foreach (object gObj in groupList)
                {
                    Dictionary<string, object> gDict = gObj as Dictionary<string, object>;
                    if (gDict == null) continue;

                    string dispName = gDict.ContainsKey("displayName") ? Convert.ToString(gDict["displayName"]) : "기타 모델";
                    QuotaGroup group = new QuotaGroup { DisplayName = dispName };

                    if (gDict.ContainsKey("buckets"))
                    {
                        object[] bucketList = gDict["buckets"] as object[];
                        if (bucketList != null)
                        {
                            foreach (object bObj in bucketList)
                            {
                                Dictionary<string, object> bDict = bObj as Dictionary<string, object>;
                                if (bDict == null) continue;

                                string bId = bDict.ContainsKey("bucketId") ? Convert.ToString(bDict["bucketId"]) : "";
                                string bName = bDict.ContainsKey("displayName") ? Convert.ToString(bDict["displayName"]) : "";
                                string window = bDict.ContainsKey("window") ? Convert.ToString(bDict["window"]) : "5h";
                                double frac = bDict.ContainsKey("remainingFraction") ? Convert.ToDouble(bDict["remainingFraction"]) : 1.0;
                                string rTimeStr = bDict.ContainsKey("resetTime") ? Convert.ToString(bDict["resetTime"]) : "";

                                DateTime resetTime = now.AddHours(window == "weekly" ? 168.0 : 5.0);
                                if (!string.IsNullOrEmpty(rTimeStr))
                                {
                                    DateTime dt;
                                    if (DateTime.TryParse(rTimeStr, out dt)) resetTime = dt.ToLocalTime();
                                }

                                // 원본 정밀도 보존 (% 환산)
                                double rawRemPct = frac * 100.0;
                                curPoint.BucketPercents[bId] = rawRemPct;

                                // N시간 윈도우 기준 정밀 속도 계산
                                double speedPerHour = CalculateWindowSpeed(bId, rawRemPct, now, windowSec);

                                double activeWorkHours = CalculateActiveWorkingHours(now, resetTime, _config.work_schedule);
                                double predictedRem = Math.Round(rawRemPct - (speedPerHour * activeWorkHours), 2);

                                QuotaBucket bucket = new QuotaBucket
                                {
                                    BucketId = bId,
                                    DisplayName = bName,
                                    Window = window,
                                    RemainingPercent = rawRemPct,
                                    ResetTime = resetTime,
                                    SpeedPerHour = speedPerHour,
                                    PredictedRemainingPercent = predictedRem
                                };

                                group.Buckets[window] = bucket;
                            }
                        }
                    }

                    groups.Add(group);
                }

                // 현재 샘플 히스토리에 추가
                _history.Add(curPoint);
                TrimHistoryMemory();

                // CSV 파일에 순수 실측 소수점 값 기록
                double g5 = curPoint.BucketPercents.ContainsKey("gemini-5h") ? curPoint.BucketPercents["gemini-5h"] : 100.0;
                double gw = curPoint.BucketPercents.ContainsKey("gemini-weekly") ? curPoint.BucketPercents["gemini-weekly"] : 100.0;
                double aw = curPoint.BucketPercents.ContainsKey("gemini-argon-wtu-weekly") ? curPoint.BucketPercents["gemini-argon-wtu-weekly"] : 100.0;
                double c5 = curPoint.BucketPercents.ContainsKey("3p-5h") ? curPoint.BucketPercents["3p-5h"] : 100.0;
                double cw = curPoint.BucketPercents.ContainsKey("3p-weekly") ? curPoint.BucketPercents["3p-weekly"] : 100.0;
                AppendQuotaCsv(now, g5, gw, aw, c5, cw);
            }
            catch (Exception ex)
            {
                WriteSystemLog("ERROR", "쿼터 파싱 오류: " + ex.Message);
            }

            return groups;
        }

        private static double CalculateActiveWorkingHours(DateTime start, DateTime target, Dictionary<string, string> schedule)
        {
            if (target <= start) return 0.0;
            if (schedule == null || schedule.Count == 0) return (target - start).TotalHours;

            double activeHours = 0.0;
            DateTime cur = start;

            while (cur < target)
            {
                DateTime nextStep = cur.Date.AddDays(1);
                DateTime blockEnd = nextStep < target ? nextStep : target;

                string dayKey = cur.DayOfWeek.ToString();
                if (schedule.ContainsKey(dayKey))
                {
                    string timeRange = schedule[dayKey];
                    if (!string.IsNullOrEmpty(timeRange) && !timeRange.Equals("off", StringComparison.OrdinalIgnoreCase))
                    {
                        string[] parts = timeRange.Split('-');
                        if (parts.Length == 2)
                        {
                            TimeSpan workStart, workEnd;
                            if (TimeSpan.TryParse(parts[0].Trim(), out workStart) && TimeSpan.TryParse(parts[1].Trim(), out workEnd))
                            {
                                DateTime dayWorkStart = cur.Date.Add(workStart);
                                DateTime dayWorkEnd = cur.Date.Add(workEnd);

                                DateTime overlapStart = cur > dayWorkStart ? cur : dayWorkStart;
                                DateTime overlapEnd = blockEnd < dayWorkEnd ? blockEnd : dayWorkEnd;

                                if (overlapEnd > overlapStart)
                                {
                                    activeHours += (overlapEnd - overlapStart).TotalHours;
                                }
                            }
                        }
                    }
                }

                cur = blockEnd;
            }

            return Math.Round(activeHours, 1);
        }

        private static StatusLevel DetermineStatus(List<QuotaGroup> groups)
        {
            StatusLevel maxStatus = StatusLevel.Normal;

            foreach (var grp in groups)
            {
                ModelThreshold th = null;
                if (_config.model_thresholds != null && _config.model_thresholds.ContainsKey(grp.DisplayName))
                {
                    th = _config.model_thresholds[grp.DisplayName];
                }
                else
                {
                    th = new ModelThreshold();
                }

                if (!th.enabled) continue; // 알림 끔

                foreach (var b in grp.Buckets.Values)
                {
                    if (b.Window == "5h")
                    {
                        if (b.RemainingPercent <= th.danger_remaining_5h || b.SpeedPerHour >= th.danger_speed_5h)
                            return StatusLevel.Danger;
                        if (b.RemainingPercent <= th.warning_remaining_5h || b.SpeedPerHour >= th.warning_speed_5h)
                            if (maxStatus < StatusLevel.Warning) maxStatus = StatusLevel.Warning;
                    }
                    else if (b.Window == "weekly")
                    {
                        if (b.RemainingPercent <= th.danger_remaining_1w || b.SpeedPerHour >= th.danger_speed_1w)
                            return StatusLevel.Danger;
                        if (b.RemainingPercent <= th.warning_remaining_1w || b.SpeedPerHour >= th.warning_speed_1w)
                            if (maxStatus < StatusLevel.Warning) maxStatus = StatusLevel.Warning;
                    }
                }
            }

            return maxStatus;
        }

        private static void PerformCheck()
        {
            if (_isChecking) return;
            _isChecking = true;

            MethodInvoker action = delegate
            {
                try
                {
                    // 1. Hot-Reload: 매 호출 주기마다 config.json 최신 설정 자동 반영
                    _config = LoadConfig();
                    int targetIntervalMs = _config.GetEffectiveIntervalSeconds() * 1000;
                    if (_timer != null && _timer.Interval != targetIntervalMs)
                    {
                        _timer.Interval = targetIntervalMs;
                    }

                    // 2. API 호출
                    string json = FetchQuotaSummaryJson();
                    if (string.IsNullOrEmpty(json))
                    {
                        _currentStatus = StatusLevel.Error;
                        UpdateTrayUI();
                        return;
                    }

                    DateTime now = DateTime.Now;
                    _latestGroups = ParseQuotaSummary(json, now);
                    _lastCheckTime = now;
                    _currentStatus = DetermineStatus(_latestGroups);

                    UpdateTrayUI();
                }
                catch (Exception ex)
                {
                    _currentStatus = StatusLevel.Error;
                    WriteSystemLog("ERROR", "PerformCheck 예외: " + ex.Message);
                    UpdateTrayUI();
                }
                finally
                {
                    _isChecking = false;
                    TrimMemory();
                }
            };

            action.BeginInvoke(null, null);
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

        private static void InitTrayIcon()
        {
            _notifyIcon = new NotifyIcon();
            _notifyIcon.Visible = true;
            _notifyIcon.Text = "Antigravity Token Monitor v5.0";

            ContextMenuStrip menu = new ContextMenuStrip();
            IntPtr forceHandle = menu.Handle;

            ToolStripMenuItem itemStatus = new ToolStripMenuItem("📊 실시간 현황");
            itemStatus.Font = new Font("맑은 고딕", 9, FontStyle.Bold);
            itemStatus.Click += delegate(object sender, EventArgs e) { ShowStatusDialog(); };
            menu.Items.Add(itemStatus);

            ToolStripMenuItem itemCheck = new ToolStripMenuItem("🔄 지금 갱신");
            itemCheck.Click += delegate(object sender, EventArgs e) { PerformCheck(); };
            menu.Items.Add(itemCheck);

            ToolStripMenuItem itemLogs = new ToolStripMenuItem("📂 로그 폴더 열기");
            itemLogs.Click += delegate(object sender, EventArgs e) { try { Process.Start(_logsDir); } catch { } };
            menu.Items.Add(itemLogs);

            ToolStripMenuItem itemConfig = new ToolStripMenuItem("⚙️ 설정 파일 열기");
            itemConfig.Click += delegate(object sender, EventArgs e) { try { Process.Start(Path.Combine(_appDir, "config.json")); } catch { } };
            menu.Items.Add(itemConfig);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem itemExit = new ToolStripMenuItem("❌ 종료");
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

            // 대표 표시 숫자 (Gemini 5h 우선, 없으면 Argon weekly)
            int displayPct = 100;
            foreach (var grp in _latestGroups)
            {
                if (grp.DisplayName.IndexOf("Gemini Models", StringComparison.OrdinalIgnoreCase) >= 0 && grp.Buckets.ContainsKey("5h"))
                {
                    displayPct = (int)Math.Round(grp.Buckets["5h"].RemainingPercent);
                    break;
                }
                else if (grp.DisplayName.IndexOf("Argon", StringComparison.OrdinalIgnoreCase) >= 0 && grp.Buckets.ContainsKey("weekly"))
                {
                    displayPct = (int)Math.Round(grp.Buckets["weekly"].RemainingPercent);
                }
            }

            Color bgColor;
            Color borderColor;
            Color textColor = Color.White;

            switch (_currentStatus)
            {
                case StatusLevel.Danger:
                    bgColor = Color.FromArgb(231, 76, 60);
                    borderColor = Color.FromArgb(192, 57, 43);
                    break;
                case StatusLevel.Warning:
                    bgColor = Color.FromArgb(230, 126, 34);
                    borderColor = Color.FromArgb(211, 84, 0);
                    break;
                case StatusLevel.Error:
                    bgColor = Color.FromArgb(127, 140, 141);
                    borderColor = Color.FromArgb(44, 62, 80);
                    break;
                default:
                    bgColor = Color.FromArgb(46, 204, 113);
                    borderColor = Color.FromArgb(39, 174, 96);
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

                string txt = _currentStatus == StatusLevel.Error ? "ERR" : displayPct.ToString();
                using (Font font = new Font("Arial", _currentStatus == StatusLevel.Error ? 8.5f : 9.5f, FontStyle.Bold))
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

            // 툴팁 구성
            List<string> tipLines = new List<string>();
            foreach (var grp in _latestGroups)
            {
                List<string> bInfo = new List<string>();
                if (grp.Buckets.ContainsKey("weekly")) bInfo.Add(string.Format("Wk:{0:F0}%", grp.Buckets["weekly"].RemainingPercent));
                if (grp.Buckets.ContainsKey("5h")) bInfo.Add(string.Format("5h:{0:F0}%", grp.Buckets["5h"].RemainingPercent));
                string shortName = grp.DisplayName.Replace(" Models", "").Replace(" and GPT models", "");
                tipLines.Add(string.Format("{0}: {1}", shortName, string.Join(", ", bInfo.ToArray())));
            }

            string tip = string.Join(" | ", tipLines.ToArray());
            if (string.IsNullOrEmpty(tip)) tip = "Antigravity Token Monitor v5.0";
            if (tip.Length > 63) tip = tip.Substring(0, 63);
            _notifyIcon.Text = tip;
        }

        private static void ShowStatusDialog()
        {
            Form form = new Form
            {
                Text = "Antigravity Token Monitor v5.0",
                ClientSize = new Size(680, 520),
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
                Size = new Size(656, 448)
            };

            Action refreshText = delegate
            {
                DateTime now = DateTime.Now;
                double activeWorkToday = CalculateActiveWorkingHours(now, now.Date.AddDays(1), _config.work_schedule);
                double activeWorkWeekly = CalculateActiveWorkingHours(now, now.AddDays(7), _config.work_schedule);

                System.Text.StringBuilder sb = new System.Text.StringBuilder();
                sb.AppendLine("========================================================================");
                sb.AppendLine("   Antigravity Token Monitor v5.0");
                sb.AppendLine("========================================================================");
                sb.AppendLine(string.Format(" 조회 시각: {0:yyyy-MM-dd HH:mm:ss}       | 갱신 주기: {1}초 (속도윈도우: {2}초)",
                    _lastCheckTime == DateTime.MinValue ? now : _lastCheckTime, _config.GetEffectiveIntervalSeconds(), _config.GetEffectiveSpeedWindowSeconds()));
                sb.AppendLine(string.Format(" 근무 시간: 평일 09:00-18:00 (오늘 남은 실근무: {0:F1}h | 주간 잔여 실근무: {1:F1}h)",
                    activeWorkToday, activeWorkWeekly));
                sb.AppendLine(string.Format(" 종합 상태: [{0}]", _currentStatus));
                sb.AppendLine();

                int idx = 1;
                foreach (var grp in _latestGroups)
                {
                    ModelThreshold th = null;
                    if (_config.model_thresholds != null && _config.model_thresholds.ContainsKey(grp.DisplayName))
                    {
                        th = _config.model_thresholds[grp.DisplayName];
                    }
                    else
                    {
                        th = new ModelThreshold();
                    }

                    string statusSuffix = !th.enabled ? "                                     [알림 끔]" : "";
                    sb.AppendLine(string.Format("[{0}] {1}{2}", idx++, grp.DisplayName, statusSuffix));

                    if (grp.Buckets.ContainsKey("weekly"))
                    {
                        var b = grp.Buckets["weekly"];
                        TimeSpan rDiff = b.ResetTime > now ? (b.ResetTime - now) : TimeSpan.Zero;
                        string rStr = string.Format("{0}일 {1}시간 후", rDiff.Days, rDiff.Hours);
                        double workHours = CalculateActiveWorkingHours(now, b.ResetTime, _config.work_schedule);
                        string thStr = th.enabled ? string.Format("[경고<{0:F0}%, 위험<{1:F0}%]", th.warning_remaining_1w, th.danger_remaining_1w) : "[알림 비활성화]";

                        sb.AppendLine(string.Format("  • 1주일 쿼터 : {0,6:F2} %  (속도: {1,4:F2} %/h | 리셋: {2})",
                            b.RemainingPercent, b.SpeedPerHour, rStr));
                        sb.AppendLine(string.Format("    └ 예상 잔여: {0,6:F2} %  (실근무 {1:F1}h 기준) {2}",
                            b.PredictedRemainingPercent, workHours, thStr));
                    }

                    if (grp.Buckets.ContainsKey("5h"))
                    {
                        var b = grp.Buckets["5h"];
                        TimeSpan rDiff = b.ResetTime > now ? (b.ResetTime - now) : TimeSpan.Zero;
                        string rStr = string.Format("{0}시간 {1}분 후", rDiff.Hours, rDiff.Minutes);
                        double workHours = CalculateActiveWorkingHours(now, b.ResetTime, _config.work_schedule);
                        string thStr = th.enabled ? string.Format("[경고<{0:F0}%, 위험<{1:F0}%]", th.warning_remaining_5h, th.danger_remaining_5h) : "[알림 비활성화]";

                        sb.AppendLine(string.Format("  • 5시간 쿼터 : {0,6:F2} %  (속도: {1,4:F2} %/h | 리셋: {2})",
                            b.RemainingPercent, b.SpeedPerHour, rStr));
                        sb.AppendLine(string.Format("    └ 예상 잔여: {0,6:F2} %  (실근무 {1:F1}h 기준)  {2}",
                            b.PredictedRemainingPercent, workHours, thStr));
                    }

                    sb.AppendLine();
                }

                sb.AppendLine("========================================================================");
                tb.Text = sb.ToString();
                tb.SelectionStart = 0;
                tb.SelectionLength = 0;
            };

            refreshText();
            form.Controls.Add(tb);

            Button btnRefresh = new Button
            {
                Text = "지금 갱신",
                Location = new Point(12, 472),
                Size = new Size(100, 32),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(52, 152, 219),
                Font = new Font("맑은 고딕", 9f, FontStyle.Bold)
            };
            btnRefresh.Click += delegate(object sender, EventArgs e)
            {
                btnRefresh.Enabled = false;
                PerformCheck();
                Timer t = new Timer { Interval = 1000 };
                t.Tick += delegate
                {
                    t.Stop();
                    t.Dispose();
                    refreshText();
                    btnRefresh.Enabled = true;
                };
                t.Start();
            };
            form.Controls.Add(btnRefresh);

            Button btnConfig = new Button
            {
                Text = "설정 열기",
                Location = new Point(122, 472),
                Size = new Size(100, 32),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(70, 75, 85),
                Font = new Font("맑은 고딕", 9f)
            };
            btnConfig.Click += delegate(object sender, EventArgs e) { try { Process.Start(Path.Combine(_appDir, "config.json")); } catch { } };
            form.Controls.Add(btnConfig);

            Button btnLogs = new Button
            {
                Text = "로그 폴더",
                Location = new Point(232, 472),
                Size = new Size(100, 32),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(70, 75, 85),
                Font = new Font("맑은 고딕", 9f)
            };
            btnLogs.Click += delegate(object sender, EventArgs e) { try { Process.Start(_logsDir); } catch { } };
            form.Controls.Add(btnLogs);

            Button btnClose = new Button
            {
                Text = "닫기",
                Location = new Point(568, 472),
                Size = new Size(100, 32),
                FlatStyle = FlatStyle.Flat,
                ForeColor = Color.White,
                BackColor = Color.FromArgb(100, 100, 100),
                Font = new Font("맑은 고딕", 9f)
            };
            btnClose.Click += delegate(object sender, EventArgs e) { form.Close(); };
            form.Controls.Add(btnClose);

            form.ShowDialog();
            TrimMemory();
        }
    }
}
