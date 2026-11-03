param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'DSH Desktop'),
    [string]$RuntimePath,
    [switch]$SkipShortcuts
)

$ErrorActionPreference = 'Stop'
$runtimeVersion = '0.2.0-rc.2'
$sourceRoot = $PSScriptRoot
$installRoot = [IO.Path]::GetFullPath($InstallDirectory)
$sourceExecutable = Join-Path $sourceRoot 'Desktop\DSHarness.exe'

if (-not [Environment]::Is64BitOperatingSystem)
{
    throw 'DSH Desktop 需要 64 位 Windows。'
}
if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf))
{
    throw '未找到 Desktop\DSHarness.exe。源码用户请先运行 .\Build.ps1；普通用户请下载 Windows 发布包。'
}

# Node 和 PowerShell 由用户自行安装，避免安装器修改系统环境或请求管理员权限。
$nodePath = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$null = Get-Command pwsh.exe -CommandType Application -ErrorAction Stop
$nodeVersionText = & $nodePath --version
if ($LASTEXITCODE -ne 0 -or [version]$nodeVersionText.TrimStart('v') -lt [version]'22.22.1')
{
    throw '请先安装 Node.js 22.22.1 或更高版本。'
}
$installedExecutable = Join-Path $installRoot 'Desktop\DSHarness.exe'
$runningDesktop = Get-Process -Name DSHarness -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $installedExecutable }
if ($runningDesktop)
{
    throw '请先从 DSH Desktop 菜单退出应用，再重新安装。'
}

if ([string]::IsNullOrWhiteSpace($RuntimePath))
{
    $RuntimePath = Join-Path $installRoot 'runtime'
    $npmPath = (Get-Command npm.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    New-Item -ItemType Directory -Path $RuntimePath -Force | Out-Null
    # 固定已适配的上游版本；后续升级需重新验证登录和后台协议。
    & $npmPath install --prefix $RuntimePath --omit=dev --no-audit --no-fund "@deepseek-ai/dsh@$runtimeVersion"
    if ($LASTEXITCODE -ne 0)
    {
        throw 'DSH 后台安装失败。请检查网络和 npm 输出后重试。'
    }
}
$RuntimePath = (Resolve-Path -LiteralPath $RuntimePath -ErrorAction Stop).Path
$runtimeEntry = Join-Path $RuntimePath 'node_modules\@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path -LiteralPath $runtimeEntry -PathType Leaf))
{
    throw 'RuntimePath 必须指向已安装 @deepseek-ai/dsh 的 npm 安装目录。'
}
$runtimePackage = Get-Content -LiteralPath (Join-Path $RuntimePath 'node_modules\@deepseek-ai\dsh\package.json') -Raw | ConvertFrom-Json
if ($runtimePackage.version -ne $runtimeVersion)
{
    throw "当前桌面版只适配 DSH $runtimeVersion，指定目录的版本是 $($runtimePackage.version)。"
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
if (-not $sourceRoot.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase))
{
    # 仅复制固定程序文件，不复制作者或安装目标的配置、缓存和会话。
    $programFiles = @(
        'Start-DS-Harness-Background.ps1', 'Stop-DS-Harness.ps1',
        'Start-DS-Harness.mjs', 'Browser-Handoff.ps1',
        'Install.ps1', 'app.ico', 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md'
    )
    foreach ($programFile in $programFiles)
    {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $programFile) -Destination (Join-Path $installRoot $programFile) -Force
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Desktop') -Destination $installRoot -Recurse -Force
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'licenses'))
    {
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'licenses') -Destination $installRoot -Recurse -Force
    }
}
[ordered]@{ runtimePath = $RuntimePath } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $installRoot 'launcher.config.json') -Encoding utf8

if (-not $SkipShortcuts)
{
    $shortcutShell = New-Object -ComObject WScript.Shell
    foreach ($shortcutDirectory in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')))
    {
        $shortcut = $shortcutShell.CreateShortcut((Join-Path $shortcutDirectory 'DSH Desktop.lnk'))
        $shortcut.TargetPath = $installedExecutable
        $shortcut.WorkingDirectory = Join-Path $installRoot 'Desktop'
        $shortcut.IconLocation = (Join-Path $installRoot 'app.ico') + ',0'
        $shortcut.Description = '兼容 DeepSeek Harness 的社区桌面客户端'
        $shortcut.Save()
    }
}
Write-Output "安装完成：$installedExecutable"
Write-Output '打开 DSH Desktop 后，按网页引导自行配置模型或登录；安装器不会启动后台。'
