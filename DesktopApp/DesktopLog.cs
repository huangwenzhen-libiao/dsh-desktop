using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace DSHarness.Desktop
{
    /// <summary>记录桌面生命周期和异常；不将带登录令牌的完整地址写入日志。</summary>
    internal sealed class DesktopLog
    {
        private readonly string _logPath;
        private readonly object _writeLock = new object();

        internal DesktopLog(string launcherRoot)
        {
            _logPath = Path.Combine(launcherRoot, "desktop.log");
        }

        internal void Write(string message, Exception exception = null)
        {
            var detail = exception == null ? message : message + Environment.NewLine + exception;
            detail = Regex.Replace(detail, @"(https?://[^\s?#]+)[?#][^\s]*", "$1 [地址参数已隐藏]", RegexOptions.IgnoreCase);
            lock (_writeLock)
            {
                try
                {
                    File.AppendAllText(_logPath, DateTimeOffset.Now.ToString("o") + " " + detail + Environment.NewLine, Encoding.UTF8);
                }
                catch (IOException logException)
                {
                    System.Diagnostics.Debug.WriteLine(logException);
                }
                catch (UnauthorizedAccessException logException)
                {
                    System.Diagnostics.Debug.WriteLine(logException);
                }
            }
        }
    }
}
