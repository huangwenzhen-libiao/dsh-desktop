# 模拟缺失、旧版和多种安装范围；不修改真实注册表，也不下载或安装系统组件。
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $sourceRoot 'Prerequisites.ps1')
Add-Type -AssemblyName System.Windows.Forms
$global:DshPrerequisiteTestState = @{
    RegistryValues = @{}
    CommandVersions = @{}
}
$savedSearchPath = $env:PATH
$frameworkSubKey = 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
$webViewSubKey = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

function Get-TestRegistryValue
{
    param($Hive, $View, $SubKey, $ValueName)
    return $global:DshPrerequisiteTestState.RegistryValues["$Hive|$View|$SubKey|$ValueName"]
}

function Get-TestCommandVersion
{
    param([string]$CommandName)
    return $global:DshPrerequisiteTestState.CommandVersions[$CommandName]
}

function Get-TestPrerequisiteDialogResult
{
    $global:DshPrerequisiteTestState.DialogShown = $true
    if ($global:DshPrerequisiteTestState.InstallDuringDialog)
    {
        $global:DshPrerequisiteTestState.RegistryValues["LocalMachine|Registry32|$frameworkSubKey|Release"] = 533320
    }
    return $global:DshPrerequisiteTestState.DialogResult
}

function Assert-Prerequisite
{
    param([bool]$Condition, [string]$Message)
    if (-not $Condition)
    {
        throw ('FAIL: ' + $Message)
    }
    Write-Output ('PASS: ' + $Message)
}

# 别名用于隔离系统读取，也能覆盖 Install.ps1 再次加载辅助文件后的真实安装入口。
Set-Alias -Name Get-PrerequisiteRegistryValue -Value Get-TestRegistryValue
Set-Alias -Name Get-PrerequisiteCommandVersion -Value Get-TestCommandVersion
Set-Alias -Name Show-InstallationPrerequisiteDialog -Value Get-TestPrerequisiteDialogResult
try
{
    Update-InstallationSearchPath
    $refreshedSearchPath = $env:PATH
    Update-InstallationSearchPath
    Assert-Prerequisite ($env:PATH -eq $refreshedSearchPath) '反复重新检测不会重复累加 PATH'
    $components = @(Get-InstallationPrerequisites)
    Assert-Prerequisite (@($components | Where-Object { -not $_.IsInstalled }).Count -eq 4) '所有组件缺失时完整列出四项运行依赖'
    $global:DshPrerequisiteTestState.RegistryValues["LocalMachine|Registry32|$frameworkSubKey|Release"] = 461807
    Assert-Prerequisite (-not (Get-InstallationPrerequisites)[0].IsInstalled) '.NET Framework 低于 4.7.2 时拦截'
    $global:DshPrerequisiteTestState.RegistryValues["LocalMachine|Registry32|$frameworkSubKey|Release"] = 461808
    Assert-Prerequisite ((Get-InstallationPrerequisites)[0].IsInstalled) '.NET Framework 4.7.2 最低受支持版本通过'
    $global:DshPrerequisiteTestState.RegistryValues["LocalMachine|Registry32|$frameworkSubKey|Release"] = 533320
    Assert-Prerequisite ((Get-InstallationPrerequisites)[0].IsInstalled) '.NET Framework 4.8.1 兼容版本通过'

    foreach ($location in @('LocalMachine|Registry32', 'LocalMachine|Registry64', 'CurrentUser|Registry32', 'CurrentUser|Registry64'))
    {
        foreach ($invalidVersion in @('', '0.0.0.0', 'invalid'))
        {
            $global:DshPrerequisiteTestState.RegistryValues["$location|$webViewSubKey|pv"] = $invalidVersion
            Assert-Prerequisite (-not (Get-InstallationPrerequisites)[1].IsInstalled) ("WebView2 $location 无效版本 '$invalidVersion' 不放行")
        }
        $global:DshPrerequisiteTestState.RegistryValues["$location|$webViewSubKey|pv"] = '143.0.3650.80'
        Assert-Prerequisite ((Get-InstallationPrerequisites)[1].IsInstalled) ("WebView2 $location 安装可被识别")
        $global:DshPrerequisiteTestState.RegistryValues.Remove("$location|$webViewSubKey|pv")
    }

    $global:DshPrerequisiteTestState.RegistryValues["CurrentUser|Registry64|$webViewSubKey|pv"] = '143.0.3650.80'
    $global:DshPrerequisiteTestState.CommandVersions['node.exe'] = [version]'22.22.0'
    $global:DshPrerequisiteTestState.CommandVersions['pwsh.exe'] = [version]'5.1'
    $components = @(Get-InstallationPrerequisites)
    Assert-Prerequisite (-not $components[2].IsInstalled -and -not $components[3].IsInstalled) '旧版 Node 和 PowerShell 不放行'
    $global:DshPrerequisiteTestState.CommandVersions['node.exe'] = [version]'22.22.1'
    $global:DshPrerequisiteTestState.CommandVersions['pwsh.exe'] = [version]'7.0'
    $global:DshPrerequisiteTestState.DialogShown = $false
    Confirm-InstallationPrerequisites -NonInteractive
    Assert-Prerequisite (-not $global:DshPrerequisiteTestState.DialogShown) '依赖全部就绪时无需弹出引导'

    $global:DshPrerequisiteTestState.RegistryValues["LocalMachine|Registry32|$frameworkSubKey|Release"] = 0
    $global:DshPrerequisiteTestState.DialogShown = $false
    $missingRejected = $false
    try
    {
        Confirm-InstallationPrerequisites -NonInteractive
    }
    catch
    {
        $missingRejected = $_.Exception.Message.Contains('.NET Framework') -and $_.Exception.Message.Contains('https://dotnet.microsoft.com/')
    }
    Assert-Prerequisite ($missingRejected -and -not $global:DshPrerequisiteTestState.DialogShown) '非交互安装明确列出缺失组件和官方下载地址'

    $installRoot = Join-Path $sourceRoot ('artifacts\prerequisite-blocked-' + [Guid]::NewGuid().ToString('N'))
    $installationRejected = $false
    $installationFailureMessage = ''
    try
    {
        & (Join-Path $sourceRoot 'Install.ps1') -InstallDirectory $installRoot -NonInteractive -SkipShortcuts
    }
    catch
    {
        $installationFailureMessage = $_.Exception.Message
        $installationRejected = $_.Exception.Message.Contains('缺少运行组件')
    }
    if (-not $installationRejected)
    {
        throw ('实际安装入口未按预期阻断：' + $installationFailureMessage)
    }
    Assert-Prerequisite ($installationRejected -and -not (Test-Path -LiteralPath $installRoot)) '实际安装入口在组件缺失时先拦截，不创建安装目录或执行 npm'

    $global:DshPrerequisiteTestState.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $global:DshPrerequisiteTestState.InstallDuringDialog = $false
    $cancelled = $false
    try
    {
        Confirm-InstallationPrerequisites
    }
    catch [System.OperationCanceledException]
    {
        $cancelled = $true
    }
    Assert-Prerequisite $cancelled '用户取消引导时停止安装'

    $global:DshPrerequisiteTestState.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $stillMissingRejected = $false
    try
    {
        Confirm-InstallationPrerequisites
    }
    catch
    {
        $stillMissingRejected = $_.Exception.Message.Contains('运行组件仍未就绪')
    }
    Assert-Prerequisite $stillMissingRejected '点击继续后再次校验，组件仍缺失时不安装'
    $global:DshPrerequisiteTestState.InstallDuringDialog = $true
    Confirm-InstallationPrerequisites
    Assert-Prerequisite $global:DshPrerequisiteTestState.DialogShown '引导中补齐组件后可继续安装'
}
finally
{
    $env:PATH = $savedSearchPath
    Remove-Variable -Name DshPrerequisiteTestState -Scope Global
}
