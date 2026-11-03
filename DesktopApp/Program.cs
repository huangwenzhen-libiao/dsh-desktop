using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace DSHarness.Desktop
{
    internal static class Program
    {
        // 与后台启动器的互斥锁分开：这里控制桌面窗口，后台仍可被登录预热复用。
        private const string InstanceName = "Local\\DSHDesktop-3080";
        private const string ActivationName = "Local\\DSHDesktop-Activate-3080";

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AllowSetForegroundWindow(int processId);

        /// <summary>启动唯一桌面窗口；再次点击快捷方式时通知现有窗口恢复到前台。</summary>
        [STAThread]
        private static void Main()
        {
            var launchWatch = Stopwatch.StartNew();
            var launcherRoot = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
            var log = new DesktopLog(launcherRoot);

            using (var activation = new EventWaitHandle(false, EventResetMode.AutoReset, ActivationName))
            using (var instance = new Mutex(true, InstanceName, out bool isFirstInstance))
            {
                var ownsInstance = isFirstInstance;
                if (!ownsInstance)
                {
                    try
                    {
                        ownsInstance = instance.WaitOne(0);
                    }
                    catch (AbandonedMutexException)
                    {
                        // 原窗口异常退出后接管互斥锁，避免把恢复请求发送给已退出的进程。
                        ownsInstance = true;
                    }
                }
                if (!ownsInstance)
                {
                    GrantForegroundToExistingInstance(log);
                    activation.Set();
                    log.Write("再次启动：已通知现有桌面窗口显示，请求耗时 " + launchWatch.ElapsedMilliseconds + "ms。");
                    return;
                }

                // 重复启动只发送唤回信号，不加载界面主题、不创建 WebView，也不调用后台启动器。
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (sender, args) =>
                {
                    log.Write("界面异常", args.Exception);
                    MessageBox.Show("界面发生异常，请从菜单打开日志查看。", "DSH Desktop", MessageBoxButtons.OK, MessageBoxIcon.Error);
                };
                try
                {
                    log.Write("桌面应用启动。");
                    Application.Run(new MainForm(launcherRoot, activation, log));
                }
                catch (Exception exception)
                {
                    log.Write("桌面应用启动失败", exception);
                    MessageBox.Show("桌面应用启动失败：" + exception.Message, "DSH Desktop", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally
                {
                    instance.ReleaseMutex();
                    log.Write("桌面应用退出。");
                }
            }
        }

        /// <summary>把快捷方式点击获得的前台权限交给常驻进程，让隐藏窗口能够直接恢复到前台。</summary>
        private static void GrantForegroundToExistingInstance(DesktopLog log)
        {
            using (var current = Process.GetCurrentProcess())
            {
                var candidates = Process.GetProcessesByName(current.ProcessName);
                try
                {
                    var existing = candidates
                        .Where(process => process.Id != current.Id && process.SessionId == current.SessionId &&
                            string.Equals(process.MainModule.FileName, current.MainModule.FileName, StringComparison.OrdinalIgnoreCase))
                        .OrderBy(process => process.StartTime)
                        .FirstOrDefault();
                    if (existing != null && !AllowSetForegroundWindow(existing.Id))
                    {
                        log.Write("系统未授予前台切换权限，仍继续通知现有窗口恢复。");
                    }
                }
                catch (Exception exception) when (exception is InvalidOperationException || exception is System.ComponentModel.Win32Exception)
                {
                    log.Write("读取现有窗口进程失败，仍继续发送唤回信号", exception);
                }
                finally
                {
                    foreach (var process in candidates)
                    {
                        process.Dispose();
                    }
                }
            }
        }
    }

}
