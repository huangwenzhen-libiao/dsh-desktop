using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DSHarness.Desktop
{
    /// <summary>
    /// 复用已有 PowerShell 启停流程，保留后台所有权、端口保护和 Node 编译缓存。
    /// 桌面关闭不代表后台关闭，只有明确停止时才调用原停止脚本。
    /// </summary>
    internal sealed class HarnessBackend
    {
        private readonly string _launcherRoot;
        private readonly int _port;
        private readonly DesktopLog _log;
        // 停止必须排在本实例发起的启动脚本之后，防止刚启动尚未登记状态就被误判为已停止。
        private Task _startScriptTask;

        internal HarnessBackend(string launcherRoot, DesktopLog log, int port = 3080)
        {
            _launcherRoot = launcherRoot;
            _log = log;
            _port = port;
        }

        /// <summary>静默启动或复用后台，校验受管理进程和页面后返回内存中的登录地址。</summary>
        internal async Task<Uri> StartAsync(CancellationToken cancellationToken)
        {
            _startScriptTask = RunScriptAsync("Start-DS-Harness-Background.ps1", "-NoBrowser -NoPopup -Port " + _port, 660, cancellationToken);
            await _startScriptTask;
            var state = ReadState();
            if (!IsManagedProcessRunning(state))
            {
                throw new InvalidOperationException("后台已退出，请点击重新连接。");
            }

            var readyUri = ReadReadyUri(state);
            using (var handler = new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false, AutomaticDecompression = System.Net.DecompressionMethods.GZip | System.Net.DecompressionMethods.Deflate })
            using (var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) })
            {
                var requestUri = readyUri;
                var isReady = false;
                // DSH 会把 URL 中的令牌换成 Cookie，再以 303 跳转到首页。
                // 只跟随同一个本地服务内的跳转，不将登录请求转发到其他站点。
                for (var redirectCount = 0; redirectCount < 5; redirectCount++)
                {
                    using (var response = await client.GetAsync(requestUri, cancellationToken))
                    {
                        var statusCode = (int)response.StatusCode;
                        if (statusCode >= 300 && statusCode < 400 && response.Headers.Location != null)
                        {
                            var nextUri = new Uri(requestUri, response.Headers.Location);
                            if (nextUri.Scheme != readyUri.Scheme || nextUri.Host != readyUri.Host || nextUri.Port != readyUri.Port || nextUri.UserInfo.Length != 0)
                            {
                                throw new InvalidOperationException("后台登录跳转离开了当前本地服务，已停止连接。");
                            }
                            requestUri = nextUri;
                            continue;
                        }
                        var html = await response.Content.ReadAsStringAsync();
                        isReady = response.StatusCode == System.Net.HttpStatusCode.OK && html.Contains("__DSH_BOOT__");
                        break;
                    }
                }
                if (!isReady)
                {
                    throw new InvalidOperationException("后台页面尚未就绪，或登录信息已失效，请重新连接。");
                }
            }
            _log.Write("后台就绪，复用受管理进程 PID " + state.ProcessId + "。");
            return readyUri;
        }

        internal bool IsRunning()
        {
            try
            {
                return IsManagedProcessRunning(ReadState());
            }
            catch (Exception exception) when (exception is IOException || exception is SerializationException)
            {
                return false;
            }
        }

        /// <summary>只停止原启动器登记且身份匹配的进程；后台已退出时允许正常退出桌面。</summary>
        internal async Task StopAsync(CancellationToken cancellationToken)
        {
            if (_startScriptTask != null)
            {
                try
                {
                    await _startScriptTask;
                }
                catch (Exception exception)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    _log.Write("启动未成功完成，继续检查并清理受管理后台", exception);
                }
            }
            if (!File.Exists(StatePath))
            {
                _log.Write("没有后台状态文件，无需停止进程。");
                return;
            }
            await RunScriptAsync("Stop-DS-Harness.ps1", "-Port " + _port, 170, cancellationToken);
            _log.Write("已执行受管理后台停止流程。");
        }

        private string StatePath => Path.Combine(_launcherRoot, "dsh-web-" + _port + ".state.json");

        private ManagedServerState ReadState()
        {
            using (var stream = new FileStream(StatePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                return (ManagedServerState)new DataContractJsonSerializer(typeof(ManagedServerState)).ReadObject(stream);
            }
        }

        private static bool IsManagedProcessRunning(ManagedServerState state)
        {
            if (state == null || state.ProcessId <= 0)
            {
                return false;
            }
            try
            {
                using (var process = Process.GetProcessById(state.ProcessId))
                {
                    return !process.HasExited &&
                        process.StartTime.ToUniversalTime().Ticks.ToString() == state.StartedUtcTicks &&
                        string.Equals(process.MainModule.FileName, state.Executable, StringComparison.OrdinalIgnoreCase);
                }
            }
            catch (Exception exception) when (exception is ArgumentException || exception is InvalidOperationException || exception is System.ComponentModel.Win32Exception)
            {
                return false;
            }
        }

        private Uri ReadReadyUri(ManagedServerState state)
        {
            // 状态文件仅能指向启动器目录内的 stdout；不从页面或任意文件接受登录地址。
            var stdoutPath = Path.GetFullPath(state.StandardOutputPath ?? "");
            var expectedRoot = Path.GetFullPath(_launcherRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!stdoutPath.StartsWith(expectedRoot, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("后台日志路径不属于当前启动器目录。");
            }
            string readyLine = null;
            // 后台进程持续持有 stdout 的写句柄，读取时必须允许共享写入。
            using (var stream = new FileStream(stdoutPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (line.StartsWith("dsh web: ", StringComparison.Ordinal))
                    {
                        readyLine = line;
                    }
                }
            }
            var match = Regex.Match(readyLine ?? "", @"^dsh web: (?<url>\S+)\s*$");
            if (!match.Success || !Uri.TryCreate(match.Groups["url"].Value, UriKind.Absolute, out Uri readyUri) ||
                readyUri.Scheme != "http" || readyUri.Host != "127.0.0.1" || readyUri.Port != _port || readyUri.UserInfo.Length != 0)
            {
                throw new InvalidOperationException("未找到可信的本地 DSH 登录地址，请查看后台启动日志。");
            }
            return readyUri;
        }

        /// <summary>在无控制台窗口的独立进程内运行脚本；取消等待不终止正在预热的后台。</summary>
        private async Task RunScriptAsync(string scriptName, string arguments, int timeoutSeconds, CancellationToken cancellationToken)
        {
            var scriptPath = Path.Combine(_launcherRoot, scriptName);
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("缺少 DSH 启动脚本：" + scriptName, scriptPath);
            }
            var powershellPath = FindPowerShell();
            var startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\" " + arguments,
                WorkingDirectory = _launcherRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (var process = Process.Start(startInfo))
            {
                var watch = Stopwatch.StartNew();
                while (!process.HasExited)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (watch.Elapsed.TotalSeconds > timeoutSeconds)
                    {
                        throw new TimeoutException("后台操作等待超时。初始化中的服务会被保留，重新连接将继续复用。");
                    }
                    await Task.Delay(250, cancellationToken);
                }
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException("后台操作失败，请查看 launcher-" + _port + ".errors.log。");
                }
            }
        }

        private static string FindPowerShell()
        {
            var candidates = new[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "pwsh.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe")
            };
            var installed = candidates.FirstOrDefault(File.Exists);
            if (installed != null)
            {
                return installed;
            }
            foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            {
                if (string.IsNullOrWhiteSpace(directory))
                {
                    continue;
                }
                var candidate = Path.Combine(directory.Trim('"'), "pwsh.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            throw new FileNotFoundException("未找到 PowerShell 7，请检查原 DSH 启动环境。");
        }

        // 字段名与现有 PowerShell 启动器的 JSON 契约一致，不依赖 C# 属性名推断。
        [DataContract]
        private sealed class ManagedServerState
        {
            [DataMember(Name = "pid")] public int ProcessId { get; set; }
            [DataMember(Name = "startedUtcTicks")] public string StartedUtcTicks { get; set; }
            [DataMember(Name = "executable")] public string Executable { get; set; }
            [DataMember(Name = "stdout")] public string StandardOutputPath { get; set; }
        }
    }
}
