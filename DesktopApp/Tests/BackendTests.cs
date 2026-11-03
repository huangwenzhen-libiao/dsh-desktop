using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DSHarness.Desktop
{
    /// <summary>通过独立临时目录和模拟服务验证启动、身份校验、登录跳转及受管理停止。</summary>
    internal static class BackendTests
    {
        private static int Main(string[] args)
        {
            try
            {
                RunAsync(args[0]).GetAwaiter().GetResult();
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception);
                return 1;
            }
        }

        private static async Task RunAsync(string launcherRoot)
        {
            var root = Path.Combine(Path.GetTempPath(), "dsh-desktop-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            var log = new DesktopLog(root);
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            var backend = new HarnessBackend(root, log, port);
            await ExpectFailureAsync<FileNotFoundException>(() => backend.StartAsync(CancellationToken.None), "缺少启动脚本时明确失败");
            var startScript = Path.Combine(root, "Start-DS-Harness-Background.ps1");
            File.WriteAllText(startScript, "param([switch]$NoBrowser,[switch]$NoPopup,[int]$Port)\nexit 7\n", Encoding.UTF8);
            await ExpectFailureAsync<InvalidOperationException>(() => backend.StartAsync(CancellationToken.None), "保留启动脚本的失败状态");
            File.WriteAllText(startScript, "param([switch]$NoBrowser,[switch]$NoPopup,[int]$Port)\nexit 0\n", Encoding.UTF8);
            var mockScript = Path.Combine(root, "mock-server.mjs");
            File.WriteAllText(mockScript,
                "import http from 'node:http';\n" +
                "http.createServer((req,res)=>{const u=new URL(req.url,'http://localhost');" +
                "if(u.pathname==='/login'){res.writeHead(303,{'Set-Cookie':'test=ok; Path=/','Location':'/'});res.end();}" +
                "else if(u.pathname==='/foreign'){res.writeHead(303,{'Location':'http://example.invalid/'});res.end();}" +
                "else if(u.pathname==='/bad'){res.end('not ready');}" +
                "else if(req.headers.cookie==='test=ok'){res.end('<html><script>window.__DSH_BOOT__={}</script></html>');}" +
                "else {res.writeHead(401);res.end();}}).listen(Number(process.argv[2]),'127.0.0.1');\n", Encoding.UTF8);
            var node = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
                .Where(directory => !string.IsNullOrWhiteSpace(directory))
                .Select(directory => Path.Combine(directory.Trim('"'), "node.exe")).First(File.Exists);
            using (var mock = Process.Start(new ProcessStartInfo(node, "\"" + mockScript + "\" " + port) { UseShellExecute = false, CreateNoWindow = true }))
            {
                var productionState = Path.Combine(launcherRoot, "dsh-web-" + port + ".state.json");
                if (File.Exists(productionState))
                {
                    throw new InvalidOperationException("测试端口已有启动状态，拒绝覆盖。");
                }
                try
                {
                    await WaitForListenerAsync(port);
                    var stdoutPath = Path.Combine(root, "mock.stdout.log");
                    var state = new TestState
                    {
                        ProcessId = mock.Id,
                        StartedUtcTicks = mock.StartTime.ToUniversalTime().Ticks.ToString(),
                        Executable = mock.MainModule.FileName,
                        StandardOutputPath = stdoutPath
                    };
                    var statePath = Path.Combine(root, "dsh-web-" + port + ".state.json");
                    WriteState(statePath, state);
                    using (var stdout = new FileStream(stdoutPath, FileMode.Create, FileAccess.ReadWrite, FileShare.ReadWrite))
                    {
                        WriteReadyLine(stdout, port, "/login?token=test-only-secret");
                        var uri = await backend.StartAsync(CancellationToken.None);
                        Assert(uri.AbsolutePath == "/login" && backend.IsRunning(), "持续写入日志时可读取地址，并完成带 Cookie 的 303 登录跳转");
                        File.WriteAllText(startScript, "param([switch]$NoBrowser,[switch]$NoPopup,[int]$Port)\nStart-Sleep -Milliseconds 400\nSet-Content -LiteralPath (Join-Path $PSScriptRoot 'startup-done') -Value ok\n", Encoding.UTF8);
                        File.WriteAllText(Path.Combine(root, "Stop-DS-Harness.ps1"), "param([int]$Port)\nif (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'startup-done'))) { exit 3 }\nSet-Content -LiteralPath (Join-Path $PSScriptRoot 'stop-done') -Value ok\n", Encoding.UTF8);
                        var delayedStart = backend.StartAsync(CancellationToken.None);
                        await backend.StopAsync(CancellationToken.None);
                        await delayedStart;
                        Assert(File.Exists(Path.Combine(root, "stop-done")), "启动途中停止时先等启动登记完成，再执行停止");
                        File.WriteAllText(startScript, "param([switch]$NoBrowser,[switch]$NoPopup,[int]$Port)\nexit 0\n", Encoding.UTF8);
                        state.StartedUtcTicks = "0";
                        WriteState(statePath, state);
                        Assert(!backend.IsRunning(), "PID 相同但启动时间不符时拒绝复用");
                        await ExpectFailureAsync<InvalidOperationException>(() => backend.StartAsync(CancellationToken.None), "身份不匹配时拒绝连接");
                        state.StartedUtcTicks = mock.StartTime.ToUniversalTime().Ticks.ToString();
                        WriteState(statePath, state);
                        WriteReadyLine(stdout, port, "/bad");
                        await ExpectFailureAsync<InvalidOperationException>(() => backend.StartAsync(CancellationToken.None), "拒绝没有 DSH 启动标记的页面");
                        WriteReadyLine(stdout, port, "/foreign");
                        await ExpectFailureAsync<InvalidOperationException>(() => backend.StartAsync(CancellationToken.None), "拒绝把登录请求重定向到其他站点");
                    }
                    log.Write("测试 http://127.0.0.1:" + port + "/?token=test-only-secret");
                    Assert(!File.ReadAllText(Path.Combine(root, "desktop.log")).Contains("test-only-secret"), "桌面日志隐藏地址参数");
                    // 将模拟进程按原格式登记到独立端口，调用真正的停止脚本验证所有权保护。
                    var protectedStatePath = Path.Combine(launcherRoot, "dsh-web-3080.state.json");
                    var protectedState = File.Exists(protectedStatePath) ? File.ReadAllBytes(protectedStatePath) : null;
                    WriteState(productionState, state);
                    var actualStop = new HarnessBackend(launcherRoot, log, port);
                    await actualStop.StopAsync(CancellationToken.None);
                    Assert(mock.WaitForExit(5000), "原停止流程只结束独立测试后台");
                    Assert(!File.Exists(productionState), "停止后清理对应端口状态");
                    Assert(protectedState == null || File.ReadAllBytes(protectedStatePath).SequenceEqual(protectedState), "原 3080 后台状态保持不变");
                    await actualStop.StopAsync(CancellationToken.None);
                    Assert(true, "后台已停止时允许重复退出");
                }
                finally
                {
                    if (!mock.HasExited)
                    {
                        mock.Kill();
                        mock.WaitForExit(5000);
                    }
                    // 仅清理本轮创建的、名称已固定的状态文件，不触及任何其他端口。
                    if (File.Exists(productionState))
                    {
                        File.Delete(productionState);
                    }
                }
            }
            Console.WriteLine("PASS: 全部后台契约验证完成；测试资料：" + root);
        }

        private static async Task WaitForListenerAsync(int port)
        {
            for (var attempt = 0; attempt < 50; attempt++)
            {
                try
                {
                    using (var client = new TcpClient())
                    {
                        await client.ConnectAsync(IPAddress.Loopback, port);
                        return;
                    }
                }
                catch (SocketException)
                {
                    await Task.Delay(100);
                }
            }
            throw new TimeoutException("模拟后台未能监听测试端口。");
        }

        private static void WriteReadyLine(FileStream stream, int port, string path)
        {
            stream.SetLength(0);
            stream.Position = 0;
            var bytes = Encoding.UTF8.GetBytes("dsh web: http://127.0.0.1:" + port + path + "\n");
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush();
        }

        private static void WriteState(string path, TestState state)
        {
            using (var stream = File.Create(path))
            {
                new DataContractJsonSerializer(typeof(TestState)).WriteObject(stream, state);
            }
        }

        private static async Task ExpectFailureAsync<TException>(Func<Task> action, string name) where TException : Exception
        {
            try
            {
                await action();
            }
            catch (TException)
            {
                Assert(true, name);
                return;
            }
            throw new Exception("未出现预期异常：" + name);
        }

        private static void Assert(bool condition, string name)
        {
            if (!condition)
            {
                throw new Exception("FAIL: " + name);
            }
            Console.WriteLine("PASS: " + name);
        }

        [DataContract]
        private sealed class TestState
        {
            [DataMember(Name = "pid")] public int ProcessId { get; set; }
            [DataMember(Name = "startedUtcTicks")] public string StartedUtcTicks { get; set; }
            [DataMember(Name = "executable")] public string Executable { get; set; }
            [DataMember(Name = "stdout")] public string StandardOutputPath { get; set; }
        }
    }
}
