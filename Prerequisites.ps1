# 安装准备可在 Windows PowerShell 5.1 中运行，不依赖尚待安装的 PowerShell 7 或 WebView2。

function Get-PrerequisiteRegistryValue
{
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [Microsoft.Win32.RegistryView]$View,
        [string]$SubKey,
        [string]$ValueName
    )

    $baseKey = $null
    $registryKey = $null
    try
    {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
        $registryKey = $baseKey.OpenSubKey($SubKey)
        if ($null -ne $registryKey)
        {
            return $registryKey.GetValue($ValueName)
        }
    }
    catch [System.Security.SecurityException]
    {
        Write-Verbose ('无法读取组件登记信息：' + $_.Exception.Message)
    }
    catch [System.UnauthorizedAccessException]
    {
        Write-Verbose ('无权读取组件登记信息：' + $_.Exception.Message)
    }
    finally
    {
        if ($null -ne $registryKey)
        {
            $registryKey.Dispose()
        }
        if ($null -ne $baseKey)
        {
            $baseKey.Dispose()
        }
    }
}

function Update-InstallationSearchPath
{
    # 组件安装器可能已经更新了注册表中的 PATH，但当前安装窗口仍持有旧环境。
    $searchPaths = @($env:PATH)
    $searchPaths += [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $searchPaths += [Environment]::GetEnvironmentVariable('PATH', 'User')
    $searchPaths += Join-Path $env:ProgramFiles 'PowerShell\7'
    $searchPaths += Join-Path $env:ProgramFiles 'nodejs'
    $expandedPaths = [Environment]::ExpandEnvironmentVariables(($searchPaths -join ';'))
    $uniquePaths = @($expandedPaths.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $env:PATH = $uniquePaths -join ';'
}

function Get-PrerequisiteCommandVersion
{
    param([string]$CommandName)

    $command = Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command)
    {
        return $null
    }

    try
    {
        if ($CommandName -eq 'node.exe')
        {
            $versionOutput = & $command.Source --version 2>$null
        }
        else
        {
            $versionOutput = & $command.Source -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        }
        if ($LASTEXITCODE -ne 0)
        {
            return $null
        }
        $version = $null
        $versionText = ($versionOutput -join '').Trim().TrimStart('v')
        if ([version]::TryParse($versionText, [ref]$version))
        {
            return $version
        }
    }
    catch
    {
        Write-Verbose ('无法检查 ' + $CommandName + '：' + $_.Exception.Message)
    }
}

function Get-InstallationPrerequisites
{
    # .NET Framework 按 Microsoft 的 Release 下限判断，接受兼容的 4.8、4.8.1 等新版本。
    $frameworkInstalled = $false
    foreach ($view in @('Registry32', 'Registry64'))
    {
        $release = Get-PrerequisiteRegistryValue -Hive LocalMachine -View $view -SubKey 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ValueName 'Release'
        if ($null -ne $release -and [long]$release -ge 461808)
        {
            $frameworkInstalled = $true
        }
    }

    # 只检查 Evergreen Runtime 专属登记，不将 Edge 浏览器或包内 SDK DLL 当成运行时。
    # 同时覆盖按用户、按计算机安装，以及 32/64 位注册表视图。
    $webViewInstalled = $false
    $runtimeSubKey = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach ($hive in @('LocalMachine', 'CurrentUser'))
    {
        foreach ($view in @('Registry32', 'Registry64'))
        {
            $registeredVersion = Get-PrerequisiteRegistryValue -Hive $hive -View $view -SubKey $runtimeSubKey -ValueName 'pv'
            $runtimeVersion = $null
            if ([version]::TryParse([string]$registeredVersion, [ref]$runtimeVersion) -and $runtimeVersion -gt [version]'0.0.0.0')
            {
                $webViewInstalled = $true
            }
        }
    }

    $nodeVersion = Get-PrerequisiteCommandVersion -CommandName 'node.exe'
    $powerShellVersion = Get-PrerequisiteCommandVersion -CommandName 'pwsh.exe'
    @(
        [pscustomobject]@{
            Id = 'Framework'
            Name = '.NET Framework 4.7.2 或更高版本'
            Description = '用于运行桌面窗口；下载页面请选择 .NET Framework Runtime。'
            IsInstalled = $frameworkInstalled
            DownloadUrl = 'https://dotnet.microsoft.com/zh-cn/download/dotnet-framework/net48'
        }
        [pscustomobject]@{
            Id = 'WebView2'
            Name = 'Microsoft Edge WebView2 Runtime'
            Description = '用于显示聊天界面；请选择 Evergreen Bootstrapper 或 x64 Runtime。'
            IsInstalled = $webViewInstalled
            DownloadUrl = 'https://developer.microsoft.com/zh-cn/microsoft-edge/webview2/#download-section'
        }
        [pscustomobject]@{
            Id = 'Node'
            Name = 'Node.js 22.22.1 或更高版本'
            Description = '用于运行本地后台；请选择 Windows x64 安装程序并保留 npm。'
            IsInstalled = ($null -ne $nodeVersion -and $nodeVersion -ge [version]'22.22.1')
            DownloadUrl = 'https://nodejs.org/zh-cn/download'
        }
        [pscustomobject]@{
            Id = 'PowerShell'
            Name = 'PowerShell 7'
            Description = '用于启动和停止后台；请选择 Windows x64 MSI 安装程序。'
            IsInstalled = ($null -ne $powerShellVersion -and $powerShellVersion -ge [version]'7.0')
            DownloadUrl = 'https://learn.microsoft.com/zh-cn/powershell/scripting/install/install-powershell-on-windows'
        }
    )
}

function Show-InstallationPrerequisiteDialog
{
    . (Join-Path $PSScriptRoot 'InstallerDialog.ps1')
    return Show-InstallerPreparationDialog
}
function Confirm-InstallationPrerequisites
{
    param([switch]$NonInteractive)

    Update-InstallationSearchPath
    $missingComponents = @(Get-InstallationPrerequisites | Where-Object { -not $_.IsInstalled })
    if ($missingComponents.Count -eq 0)
    {
        return
    }
    if ($NonInteractive)
    {
        $missingDetails = @($missingComponents | ForEach-Object { $_.Name + '：' + $_.DownloadUrl })
        throw ('缺少运行组件，尚未开始安装 DSH Desktop。' + [Environment]::NewLine + ($missingDetails -join [Environment]::NewLine))
    }
    $result = Show-InstallationPrerequisiteDialog
    if ($result -ne [System.Windows.Forms.DialogResult]::OK)
    {
        throw [System.OperationCanceledException]::new('安装已结束，可随时重新打开继续。')
    }

    # 界面允许继续后，再检查一次实际组件状态，防止误放行或环境发生变化。
    Update-InstallationSearchPath
    if (@(Get-InstallationPrerequisites | Where-Object { -not $_.IsInstalled }).Count -gt 0)
    {
        throw '运行组件仍未就绪，请重新运行安装入口进行检测。'
    }
}
