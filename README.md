# DSH Desktop

兼容 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Windows 社区桌面客户端，使用 C#、.NET Framework 和 WebView2。

本项目由社区独立维护，与 DeepSeek 官方无隶属或背书关系。模型、工具、插件、会话和网页界面由上游 DSH 提供；本项目负责桌面窗口、托盘和本地后台生命周期。

## 功能

- 独立深色桌面窗口，内嵌 DSH 网页。
- 关闭窗口后隐藏到托盘，再次打开恢复原窗口。
- 桌面窗口和后台分别保持单实例，支持后台初始化时重复打开。
- 可单独退出窗口，或在确认后停止本客户端管理的后台。
- 后台启动状态、失败提示和重新连接入口。
- 校验后台 PID、启动时间和可执行文件；端口被其他程序占用时明确报错。

## 安装

支持 64 位 Windows 10/11。先安装以下依赖，并重新打开 PowerShell，使 PATH 生效：

1. [Node.js](https://nodejs.org/en/download)，22.22.1 或更高版本；已知构建环境为 22.22.1。
2. [PowerShell 7](https://github.com/PowerShell/PowerShell/releases)。
3. [.NET Framework 4.7.2 或更新的兼容版本](https://dotnet.microsoft.com/download/dotnet-framework)。
4. [Microsoft Edge WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)。

从本仓库 Releases 下载 `dsh-desktop-1.0.0-win-x64.zip`，解压后在该目录执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

安装器通过 npm 获取固定版本的 `@deepseek-ai/dsh@0.2.0-rc.2`，默认安装到 `%LOCALAPPDATA%\DSH Desktop`，并创建桌面和开始菜单的 **DSH Desktop** 快捷方式。安装需要网络，不需要管理员权限，也不会自动启动应用。

首次打开后，通过 DSH 网页自行登录或填写模型服务配置。使用模型服务可能需要你自己的账号或 API Key，费用由对应服务商收取。

已有同版本 npm 安装时，可复用其安装目录：

```powershell
.\Install.ps1 -RuntimePath 'D:\Apps\dsh-runtime'
```

该目录应包含 `node_modules\@deepseek-ai\dsh\lib\bin.js`。需要自定义安装位置或不创建快捷方式时，使用 `-InstallDirectory`、`-SkipShortcuts`。应用、日志和浏览器缓存均写入安装目录，请选可写位置。

## 使用与数据

点击关闭按钮隐藏到托盘；双击快捷方式或点击托盘图标可恢复。通过菜单选择“退出应用（保留后台）”或“退出并停止后台”。停止后台会中断其运行中的任务，应用会提示确认。

默认服务地址为 `127.0.0.1:3080`。如果已有 DSH 或其他应用占用端口，请先通过原程序正常停止它；本客户端不会接管或结束未登记的进程。安装版与作者原有客户端使用不同安装目录。

| 数据 | 位置 |
| --- | --- |
| DSH 配置、凭据和会话 | 上游 DSH 默认使用 `%USERPROFILE%\.dsh`，按上游设置管理 |
| 安装位置与后台目录配置 | 安装目录的 `launcher.config.json` |
| 内嵌浏览器数据 | 安装目录的 `webview2-data` |
| 窗口位置 | 安装目录的 `desktop-window.json` |
| 日志、后台进程状态和编译缓存 | 安装目录 |

客户端会使用当前 Windows 用户已有的 DSH 配置和会话。发布包不含任何账号、API Key、会话、Cookie 或作者配置。后台日志可能含本地登录令牌或业务内容，请勿直接上传日志、`.dsh` 或浏览器目录；反馈问题时先脱敏。

## 从源码构建

除运行依赖外，还需要安装 [.NET SDK](https://dotnet.microsoft.com/download) 和 .NET Framework 4.7.2 目标开发包。使用 PowerShell 7：

```powershell
.\Build.ps1
.\Test.ps1
.\Package.ps1 -SkipBuild
```

构建输出在 `Desktop`，安装包在 `artifacts`。构建只生成文件，不会安装或启动真实后台。发布脚本只收集固定清单中的文件，不会打包运行时数据或 PDB；运行依赖由安装器安装。可以执行 `.\Install.ps1` 将构建结果安装到自己的用户目录。

仓库包含 GitHub Actions：推送和 PR 运行编译及后台契约测试；推送 `v1.0.0` 标签后会生成 Windows 包并作为 GitHub Release 附件发布。项目版本与标签应保持一致，自动发布前请先完成真实 Windows 安装验收。

## 验证范围与反馈

`Test.ps1` 使用独立临时目录和模拟后台，验证登录 Cookie/303 跳转、共享日志读取、进程身份、跨站跳转拒绝、启动与停止顺序、后台复用和端口保护。不会发送模型请求或访问你的实际会话。

真实模型回复、工具执行、附件、插件及新机器安装需要在自己的环境验收。上游仍在快速迭代，本版固定适配 DSH `0.2.0-rc.2`，更新上游后应重新验证。

欢迎通过本仓库 Issues 报告问题，附 Windows、Node.js、PowerShell、WebView2 版本以及已脱敏的错误信息。

## 许可证

本客户端源码采用 [MIT](LICENSE) 许可证。上游 DSH 和 Microsoft WebView2 分别遵循各自的许可，见 [第三方说明](THIRD_PARTY_NOTICES.md)。本项目的终端窗口图标为独立绘制。
