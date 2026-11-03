using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DSHarness.Desktop
{
    /// <summary>承载现有 DSH 网页，管理初始化提示、托盘和窗口恢复；不介入模型与会话数据。</summary>
    internal sealed class MainForm : Form
    {
        private readonly string _launcherRoot;
        private readonly EventWaitHandle _activation;
        private readonly DesktopLog _log;
        private readonly HarnessBackend _backend;
        private readonly List<Image> _toolbarImages = new List<Image>();
        private readonly CancellationTokenSource _lifetime = new CancellationTokenSource();
        private readonly CancellationToken _lifetimeToken;
        private readonly Panel _content = new Panel { Dock = DockStyle.Fill };
        private readonly Panel _loading = new Panel { Dock = DockStyle.Fill, BackColor = DarkTheme.Background };
        private readonly Label _heading = new Label { AutoSize = false, Height = 52, Dock = DockStyle.Top, TextAlign = ContentAlignment.MiddleCenter };
        private readonly Label _detail = new Label { AutoSize = false, Height = 100, Dock = DockStyle.Top, TextAlign = ContentAlignment.MiddleCenter };
        private readonly Button _retry = new Button { Text = "重新连接", AutoSize = true, Height = 36, Enabled = false };
        private readonly ToolStripStatusLabel _status = new ToolStripStatusLabel { Spring = true, TextAlign = ContentAlignment.MiddleLeft };
        private readonly ToolStripButton _reload = new ToolStripButton("重新连接");
        private readonly NotifyIcon _tray;
        private readonly ContextMenuStrip _trayMenu;
        private RegisteredWaitHandle _activationRegistration;
        private readonly System.Windows.Forms.Timer _statusTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        private readonly Stopwatch _startupWatch = new Stopwatch();
        private WebView2 _webView;
        private uint _browserProcessId;
        private Uri _readyUri;
        private TaskCompletionSource<bool> _pageReady;
        private bool _isStarting;
        private bool _isConnected;
        private volatile bool _isExiting;
        private bool _isStopping;
        private bool _isInTray;
        private bool _browserMustRecreate;
        private int _healthTick;

        internal MainForm(string launcherRoot, EventWaitHandle activation, DesktopLog log)
        {
            _launcherRoot = launcherRoot;
            _lifetimeToken = _lifetime.Token;
            _activation = activation;
            _log = log;
            _backend = new HarnessBackend(launcherRoot, log);
            Text = "DSH Desktop";
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = DarkTheme.Background;
            ForeColor = DarkTheme.Text;
            _content.BackColor = DarkTheme.Background;
            AutoScaleMode = AutoScaleMode.Dpi;
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(920, 650);
            Size = new Size(1380, 900);
            Icon = new Icon(Path.Combine(_launcherRoot, "app.ico"));
            RestoreWindowBounds();

            BuildLoadingPanel();
            var renderer = new DarkToolStripRenderer();
            var toolbar = new ToolStrip
            {
                GripStyle = ToolStripGripStyle.Hidden,
                Padding = new Padding(10, 5, 10, 5),
                BackColor = DarkTheme.Chrome,
                ForeColor = DarkTheme.Text,
                ImageScalingSize = new Size(16, 16),
                Renderer = renderer
            };
            var brand = new ToolStripLabel("DSH Desktop") { Font = new Font(Font, FontStyle.Bold), Margin = new Padding(4, 0, 16, 0) };
            var logs = new ToolStripButton("打开日志");
            logs.Click += (sender, args) => OpenLogs();
            var hide = new ToolStripButton("隐藏到托盘");
            hide.Click += (sender, args) => HideToTray();
            var menu = new ToolStripDropDownButton("菜单") { Alignment = ToolStripItemAlignment.Right };
            _reload.Image = DarkTheme.CreateToolbarIcon(DesktopGlyph.Refresh);
            logs.Image = DarkTheme.CreateToolbarIcon(DesktopGlyph.Logs);
            hide.Image = DarkTheme.CreateToolbarIcon(DesktopGlyph.Tray);
            menu.Image = DarkTheme.CreateToolbarIcon(DesktopGlyph.Menu);
            menu.DropDown.BackColor = DarkTheme.Chrome;
            menu.DropDown.ForeColor = DarkTheme.Text;
            menu.DropDown.Renderer = renderer;
            menu.DropDownItems.Add("在浏览器打开", null, (sender, args) => OpenBrowser());
            menu.DropDownItems.Add(new ToolStripSeparator());
            menu.DropDownItems.Add("退出应用（保留后台）", null, (sender, args) => ExitApplication());
            menu.DropDownItems.Add("退出并停止后台…", null, OnStopAndExit);
            toolbar.Items.AddRange(new ToolStripItem[] { brand, _reload, logs, hide, menu });
            foreach (ToolStripItem item in toolbar.Items)
            {
                item.Padding = new Padding(5, 3, 5, 3);
                if (item.Image != null)
                {
                    _toolbarImages.Add(item.Image);
                }
            }
            var statusBar = new StatusStrip { SizingGrip = true, BackColor = DarkTheme.Chrome, ForeColor = DarkTheme.SecondaryText, Renderer = renderer };
            _status.ForeColor = DarkTheme.SecondaryText;
            statusBar.Items.Add(_status);
            _content.Controls.Add(_loading);
            Controls.Add(_content);
            Controls.Add(statusBar);
            Controls.Add(toolbar);

            _trayMenu = new ContextMenuStrip { BackColor = DarkTheme.Chrome, ForeColor = DarkTheme.Text, Renderer = renderer };
            _trayMenu.Items.Add("打开 DSH Desktop", null, (sender, args) => ShowFromTray());
            _trayMenu.Items.Add("打开日志目录", null, (sender, args) => OpenLogs());
            _trayMenu.Items.Add(new ToolStripSeparator());
            _trayMenu.Items.Add("退出应用（保留后台）", null, (sender, args) => ExitApplication());
            _trayMenu.Items.Add("退出并停止后台…", null, OnStopAndExit);
            _tray = new NotifyIcon { Icon = Icon, Text = "DSH Desktop · 正在初始化", Visible = true, ContextMenuStrip = _trayMenu };
            _tray.MouseClick += OnTrayMouseClick;
            _retry.Click += OnReconnect;
            _reload.Click += OnReconnect;
            Shown += OnShown;
            FormClosing += OnFormClosing;
            _statusTimer.Tick += OnStatusTick;
            _statusTimer.Start();
        }

        private void BuildLoadingPanel()
        {
            var card = new Panel { Size = new Size(560, 330), Anchor = AnchorStyles.None, BackColor = _loading.BackColor };
            var brand = new Label
            {
                Text = "DeepSeek Harness",
                Font = new Font("Segoe UI", 26F, FontStyle.Bold),
                ForeColor = DarkTheme.Accent,
                Height = 70,
                Dock = DockStyle.Top,
                TextAlign = ContentAlignment.MiddleCenter
            };
            _heading.Font = new Font(Font.FontFamily, 14F);
            _heading.ForeColor = DarkTheme.Text;
            _heading.Text = "正在准备桌面应用";
            _detail.ForeColor = DarkTheme.SecondaryText;
            _detail.Text = "正在连接本地后台，请稍候。";
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 46, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Padding = new Padding(140, 5, 0, 0) };
            var logs = new Button { Text = "打开日志", AutoSize = true, Height = 36, Margin = new Padding(12, 3, 3, 3) };
            DarkTheme.StyleButton(_retry);
            DarkTheme.StyleButton(logs);
            logs.Click += (sender, args) => OpenLogs();
            buttons.Controls.Add(_retry);
            buttons.Controls.Add(logs);
            card.Controls.Add(buttons);
            card.Controls.Add(_detail);
            card.Controls.Add(_heading);
            card.Controls.Add(brand);
            // 固定宽度卡片居中，窗口缩放不会将启动提示挤到角落。
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 1 };
            layout.Controls.Add(card, 0, 0);
            _loading.Controls.Add(layout);
            _status.Text = "正在初始化";
        }

        private async void OnShown(object sender, EventArgs args)
        {
            // 内核事件在有请求时才唤醒等待线程，隐藏后无需每 250ms 轮询一次。
            _activationRegistration = ThreadPool.RegisterWaitForSingleObject(_activation, OnActivationRequested, null, Timeout.Infinite, false);
            await ConnectAsync();
        }

        private void OnActivationRequested(object state, bool timedOut)
        {
            var requestWatch = Stopwatch.StartNew();
            if (_isExiting)
            {
                return;
            }
            try
            {
                BeginInvoke(new Action(() =>
                {
                    if (!_isExiting)
                    {
                        ShowFromTray("桌面快捷方式", requestWatch);
                    }
                }));
            }
            catch (InvalidOperationException exception)
            {
                _log.Write("窗口正在退出，未能处理唤回请求", exception);
            }
        }

        private void OnTrayMouseClick(object sender, MouseEventArgs args)
        {
            if (args.Button == MouseButtons.Left)
            {
                ShowFromTray("托盘单击");
            }
        }

        protected override void OnHandleCreated(EventArgs args)
        {
            base.OnHandleCreated(args);
            // 窗口句柄重建时重新应用原生标题栏颜色，托盘隐藏恢复保持原句柄。
            DarkTheme.ApplyTitleBar(Handle);
        }

        private async void OnReconnect(object sender, EventArgs args)
        {
            await ConnectAsync();
        }

        /// <summary>串行连接后台并创建 WebView2；失败保留窗口和重试入口。</summary>
        private async Task ConnectAsync()
        {
            if (_isStarting || _isStopping || _isExiting)
            {
                return;
            }
            _isStarting = true;
            _isConnected = false;
            _readyUri = null;
            _retry.Enabled = false;
            _reload.Enabled = false;
            _startupWatch.Restart();
            ShowLoading("正在启动本地后台", "首次初始化可能需要一两分钟。\n后台已运行时会直接复用，请保持窗口打开。");
            try
            {
                // 后台连接与浏览器初始化都异步等待，启动界面和托盘保持响应。
                _readyUri = await _backend.StartAsync(_lifetimeToken);
                _lifetimeToken.ThrowIfCancellationRequested();
                if (_isStopping)
                {
                    return;
                }
                _heading.Text = "正在加载界面";
                _detail.Text = "本地后台已就绪，正在打开会话界面。";
                await EnsureBrowserAsync();
                _lifetimeToken.ThrowIfCancellationRequested();
                if (_isStopping)
                {
                    return;
                }
                _pageReady = new TaskCompletionSource<bool>();
                _webView.CoreWebView2.Navigate(_readyUri.AbsoluteUri);
                var completed = await Task.WhenAny(_pageReady.Task, Task.Delay(TimeSpan.FromSeconds(60), _lifetimeToken));
                _lifetimeToken.ThrowIfCancellationRequested();
                if (completed != _pageReady.Task)
                {
                    throw new TimeoutException("内置页面加载超时，请重新连接或打开日志查看。");
                }
                await _pageReady.Task;
            }
            catch (OperationCanceledException)
            {
                _log.Write("桌面关闭，已取消连接等待；后台生命周期由原启动器继续管理。");
            }
            catch (Exception exception)
            {
                if (!_isExiting && !_isStopping)
                {
                    ShowFailure("连接失败", exception);
                }
            }
            finally
            {
                _isStarting = false;
                if (!_isExiting && !_isStopping)
                {
                    _retry.Enabled = true;
                    _reload.Enabled = true;
                }
            }
        }

        /// <summary>使用独立且持久化的 WebView2 用户目录；通过现有本地令牌登录，无需复制浏览器凭据。</summary>
        private async Task EnsureBrowserAsync()
        {
            if (_webView != null && (_browserMustRecreate || _webView.CoreWebView2 == null))
            {
                _content.Controls.Remove(_webView);
                _webView.Dispose();
                _webView = null;
                _browserProcessId = 0;
                _browserMustRecreate = false;
            }
            if (_webView != null && _webView.CoreWebView2 != null)
            {
                return;
            }
            // 缺少运行时会在这里产生可重试的明确异常，不自动下载或更改系统环境。
            CoreWebView2Environment.GetAvailableBrowserVersionString();
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(_launcherRoot, "webview2-data"));
            if (_isExiting)
            {
                return;
            }
            _webView = new WebView2 { Dock = DockStyle.Fill, Visible = false, DefaultBackgroundColor = DarkTheme.Background };
            _content.Controls.Add(_webView);
            await _webView.EnsureCoreWebView2Async(environment);
            _browserProcessId = _webView.CoreWebView2.BrowserProcessId;
            // 桌面壳不向网页暴露 COM 对象或本地执行桥接，现有 DSH 前端继续使用自己的服务接口。
            _webView.CoreWebView2.Settings.AreHostObjectsAllowed = false;
            _webView.CoreWebView2.Settings.IsWebMessageEnabled = false;
            _webView.CoreWebView2.NavigationStarting += OnNavigationStarting;
            _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            _webView.CoreWebView2.NewWindowRequested += OnNewWindowRequested;
            _webView.CoreWebView2.ProcessFailed += (sender, args) =>
            {
                _browserMustRecreate = true;
                ShowFailure("内置页面已停止", new InvalidOperationException("请点击重新连接。后台与会话数据仍由 DSH 管理。"));
            };
            _log.Write("WebView2 初始化完成，运行时 " + environment.BrowserVersionString + "。");
        }

        private bool IsLocalHarnessUri(Uri uri)
        {
            return _readyUri != null && uri.Scheme == _readyUri.Scheme && uri.Host == _readyUri.Host && uri.Port == _readyUri.Port;
        }

        private void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs args)
        {
            if (Uri.TryCreate(args.Uri, UriKind.Absolute, out Uri uri) && IsLocalHarnessUri(uri))
            {
                return;
            }
            args.Cancel = true;
            _status.Text = "外部页面请通过链接在浏览器中打开";
        }

        private async void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            try
            {
                if (_isExiting || _isStopping)
                {
                    return;
                }
                if (!args.IsSuccess)
                {
                    ReportNavigationFailure(new InvalidOperationException("加载状态：" + args.WebErrorStatus + "。请重新连接。"));
                    return;
                }
                var bootPresent = await _webView.CoreWebView2.ExecuteScriptAsync("typeof globalThis.__DSH_BOOT__ !== 'undefined'");
                if (_isExiting)
                {
                    return;
                }
                if (bootPresent != "true")
                {
                    ReportNavigationFailure(new InvalidOperationException("未检测到 DSH 页面，请重新连接获取最新登录信息。"));
                    return;
                }
                _isConnected = true;
                _startupWatch.Stop();
                _webView.Visible = true;
                _loading.Visible = false;
                _webView.BringToFront();
                _status.Text = "已连接本地 DSH · 关闭窗口可保留任务运行";
                _tray.Text = "DSH Desktop · 已连接";
                _log.Write("DSH 页面加载成功，页面启动标记已验证。");
                _pageReady?.TrySetResult(true);
            }
            catch (Exception exception)
            {
                if (!_isExiting)
                {
                    ReportNavigationFailure(exception);
                }
            }
        }

        private void ReportNavigationFailure(Exception exception)
        {
            if (_pageReady != null && !_pageReady.Task.IsCompleted)
            {
                _pageReady.TrySetException(exception);
            }
            else
            {
                ShowFailure("页面加载失败", exception);
            }
        }

        private void OnNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs args)
        {
            args.Handled = true;
            if (!args.IsUserInitiated || !Uri.TryCreate(args.Uri, UriKind.Absolute, out Uri uri))
            {
                return;
            }
            if (IsLocalHarnessUri(uri))
            {
                _webView.CoreWebView2.Navigate(uri.AbsoluteUri);
            }
            else if (uri.Scheme == "https" || uri.Scheme == "http")
            {
                OpenExternal(uri.AbsoluteUri);
            }
        }

        private void OnStatusTick(object sender, EventArgs args)
        {
            if (_isInTray)
            {
                return;
            }
            if (_isStarting)
            {
                _status.Text = "正在初始化 · 已等待 " + (int)_startupWatch.Elapsed.TotalSeconds + " 秒";
                return;
            }
            if (_isConnected && !_isStopping && ++_healthTick % 5 == 0 && !_backend.IsRunning())
            {
                ShowFailure("本地后台已停止", new InvalidOperationException("点击重新连接即可重新启动并恢复会话界面。"));
            }
        }

        private void ShowLoading(string heading, string detail)
        {
            _heading.Text = heading;
            _detail.Text = detail;
            _loading.Visible = true;
            _loading.BringToFront();
            _tray.Text = "DSH Desktop · " + heading;
        }

        private void ShowFailure(string heading, Exception exception)
        {
            _isConnected = false;
            _startupWatch.Stop();
            ShowLoading(heading, exception.Message);
            _status.Text = heading + " · 可以重试或打开日志";
            _retry.Enabled = true;
            _reload.Enabled = true;
            _log.Write(heading, exception);
        }

        private void HideToTray()
        {
            if (_isInTray || _isExiting)
            {
                return;
            }
            _isInTray = true;
            _statusTimer.Stop();
            // Hide 会自动从任务栏移除窗口。切换 ShowInTaskbar 会重建 HWND，影响 WebView 恢复。
            // 保留页面、脚本及连接，只让不可见窗口停止绘制；不挂起页面或回收其工作集。
            Hide();
            SaveWindowBounds();
            _log.Write("窗口已隐藏到托盘，保留原窗口和页面，后台保持运行。HWND=" + Handle.ToInt64());
        }

        /// <summary>直接显示常驻窗口，不创建 WebView、不重新导航、不调用后台启动器。</summary>
        private void ShowFromTray(string source = "托盘菜单", Stopwatch requestWatch = null)
        {
            if (_isExiting)
            {
                return;
            }
            var watch = requestWatch ?? Stopwatch.StartNew();
            _isInTray = false;
            Show();
            if (WindowState == FormWindowState.Minimized)
            {
                WindowState = FormWindowState.Normal;
            }
            Activate();
            BringToFront();
            _statusTimer.Start();
            _log.Write("窗口快速恢复：来源=" + source + "，耗时=" + watch.ElapsedMilliseconds +
                "ms，页面已就绪=" + _isConnected + "，HWND=" + Handle.ToInt64() + "，WebViewPID=" + _browserProcessId + "。");
        }

        private void OnFormClosing(object sender, FormClosingEventArgs args)
        {
            if (args.CloseReason == CloseReason.UserClosing && !_isExiting)
            {
                args.Cancel = true;
                HideToTray();
                return;
            }
            SaveWindowBounds();
            _isExiting = true;
            _lifetime.Cancel();
        }

        private void ExitApplication()
        {
            if (_isStopping)
            {
                return;
            }
            _isExiting = true;
            _log.Write("用户退出桌面应用，保留后台。");
            Close();
        }

        private async void OnStopAndExit(object sender, EventArgs args)
        {
            if (_isStopping)
            {
                return;
            }
            ShowFromTray();
            var answer = MessageBox.Show(this, "这会结束 DSH 后台，包括其中正在执行的任务。\n确认停止后台并退出？", "停止 DSH Desktop", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes)
            {
                return;
            }
            _isStopping = true;
            _reload.Enabled = false;
            _retry.Enabled = false;
            ShowLoading("正在停止后台", "正在等待原启动器完成停止操作，请稍候。");
            try
            {
                await _backend.StopAsync(_lifetimeToken);
                _isExiting = true;
                Close();
            }
            catch (Exception exception)
            {
                if (!_isExiting)
                {
                    ShowFailure("停止失败", exception);
                }
            }
            finally
            {
                _isStopping = false;
            }
        }

        private void OpenLogs()
        {
            OpenExternal(_launcherRoot);
        }

        private void OpenBrowser()
        {
            if (_readyUri == null)
            {
                _status.Text = "请等待后台连接完成";
                return;
            }
            OpenExternal(_readyUri.AbsoluteUri);
        }

        private void OpenExternal(string target)
        {
            try
            {
                Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
            }
            catch (Exception exception)
            {
                _log.Write("打开外部入口失败", exception);
                _status.Text = "无法打开，请查看日志";
            }
        }

        private void RestoreWindowBounds()
        {
            var path = Path.Combine(_launcherRoot, "desktop-window.json");
            if (!File.Exists(path))
            {
                return;
            }
            try
            {
                using (var stream = File.OpenRead(path))
                {
                    var saved = (WindowBounds)new DataContractJsonSerializer(typeof(WindowBounds)).ReadObject(stream);
                    var bounds = new Rectangle(saved.Left, saved.Top, Math.Max(saved.Width, 920), Math.Max(saved.Height, 650));
                    if (Array.Exists(Screen.AllScreens, screen => Rectangle.Intersect(screen.WorkingArea, bounds).Width >= 200 && Rectangle.Intersect(screen.WorkingArea, bounds).Height >= 100))
                    {
                        StartPosition = FormStartPosition.Manual;
                        Bounds = bounds;
                    }
                    if (saved.Maximized)
                    {
                        WindowState = FormWindowState.Maximized;
                    }
                }
            }
            catch (Exception exception)
            {
                _log.Write("恢复窗口位置失败，使用默认位置", exception);
            }
        }

        private void SaveWindowBounds()
        {
            var bounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            var saved = new WindowBounds { Left = bounds.Left, Top = bounds.Top, Width = bounds.Width, Height = bounds.Height, Maximized = WindowState == FormWindowState.Maximized };
            try
            {
                using (var stream = File.Create(Path.Combine(_launcherRoot, "desktop-window.json")))
                {
                    new DataContractJsonSerializer(typeof(WindowBounds)).WriteObject(stream, saved);
                }
            }
            catch (Exception exception)
            {
                _log.Write("保存窗口位置失败", exception);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _isExiting = true;
                _lifetime.Cancel();
                _activationRegistration?.Unregister(null);
                _statusTimer.Dispose();
                _tray.Visible = false;
                _tray.Dispose();
                _trayMenu.Dispose();
                foreach (var image in _toolbarImages)
                {
                    image.Dispose();
                }
                _webView?.Dispose();
                _lifetime.Dispose();
            }
            base.Dispose(disposing);
        }

        [DataContract]
        private sealed class WindowBounds
        {
            [DataMember] public int Left { get; set; }
            [DataMember] public int Top { get; set; }
            [DataMember] public int Width { get; set; }
            [DataMember] public int Height { get; set; }
            [DataMember] public bool Maximized { get; set; }
        }
    }
}
