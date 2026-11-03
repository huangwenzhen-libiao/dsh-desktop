# 官方安装流程采用模拟下载和进程返回值；绝不实际安装或更改系统组件。
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $sourceRoot 'Install-Dependency.ps1')
$testDirectory = Join-Path $sourceRoot ('artifacts\dependency-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
$global:DshDependencyTests = @{
    SignatureValid = $true
    HashValid = $true
    ExitCode = 0
    Downloads = 0
    Installs = 0
}

function Invoke-TestDownload
{
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    if (([uri]$Uri).Scheme -ne 'https')
    {
        throw '下载必须使用 HTTPS。'
    }
    $global:DshDependencyTests.Downloads++
    [IO.File]::WriteAllText($OutFile, 'test installer')
}

function Get-TestSignature
{
    param($LiteralPath)
    $status = 'NotSigned'
    if ($global:DshDependencyTests.SignatureValid)
    {
        $status = 'Valid'
    }
    return [pscustomobject]@{ Status = $status }
}

function Get-TestHash
{
    param($LiteralPath, $Algorithm)
    $hash = 'invalid'
    if ($global:DshDependencyTests.HashValid)
    {
        $hash = (Get-PrerequisiteInstaller -Id Node).Sha256
    }
    return [pscustomobject]@{ Hash = $hash }
}

function Invoke-TestNativeInstaller
{
    param($Path, $Installer)
    $global:DshDependencyTests.Installs++
    return $global:DshDependencyTests.ExitCode
}

function Assert-Dependency
{
    param([bool]$Condition, [string]$Message)
    if (-not $Condition)
    {
        throw ('FAIL: ' + $Message)
    }
    Write-Output ('PASS: ' + $Message)
}

Set-Alias Invoke-WebRequest Invoke-TestDownload
Set-Alias Get-AuthenticodeSignature Get-TestSignature
Set-Alias Get-FileHash Get-TestHash
Set-Alias Invoke-PrerequisiteInstaller Invoke-TestNativeInstaller
try
{
    foreach ($id in @('Framework', 'WebView2', 'Node', 'PowerShell'))
    {
        $installer = Get-PrerequisiteInstaller -Id $id
        Assert-Dependency (([uri]$installer.Url).Host -in @('go.microsoft.com', 'nodejs.org', 'github.com')) ("$id 安装来源为官方站点")
        Install-PrerequisiteComponent -Id $id -Directory $testDirectory
        $status = Get-Content -LiteralPath (Join-Path $testDirectory 'status.json') -Raw | ConvertFrom-Json
        Assert-Dependency ($status.phase -eq 'complete') ("$id 下载、校验和安装成功后登记完成")
    }
    $global:DshDependencyTests.SignatureValid = $false
    $before = $global:DshDependencyTests.Installs
    $rejected = $false
    try
    {
        Install-PrerequisiteComponent -Id WebView2 -Directory $testDirectory
    }
    catch
    {
        $rejected = $_.Exception.Message.Contains('校验未通过')
    }
    Assert-Dependency ($rejected -and $global:DshDependencyTests.Installs -eq $before) '签名不可信时不运行安装器'

    $global:DshDependencyTests.SignatureValid = $true
    $global:DshDependencyTests.HashValid = $false
    $rejected = $false
    try
    {
        Install-PrerequisiteComponent -Id Node -Directory $testDirectory
    }
    catch
    {
        $rejected = $_.Exception.Message.Contains('下载不完整')
    }
    Assert-Dependency ($rejected -and $global:DshDependencyTests.Installs -eq $before) '固定版本安装包哈希不符时不运行'

    $global:DshDependencyTests.HashValid = $true
    foreach ($restartCode in @(3010, 1641))
    {
        $global:DshDependencyTests.ExitCode = $restartCode
        Install-PrerequisiteComponent -Id Framework -Directory $testDirectory
        $status = Get-Content -LiteralPath (Join-Path $testDirectory 'status.json') -Raw | ConvertFrom-Json
        Assert-Dependency ($status.phase -eq 'restart') ("安装器返回 $restartCode 时要求重启，不误报已完成")
    }
    $global:DshDependencyTests.ExitCode = 1602
    $rejected = $false
    try
    {
        Install-PrerequisiteComponent -Id WebView2 -Directory $testDirectory
    }
    catch
    {
        $rejected = $_.Exception.Message.Contains('1602')
    }
    Assert-Dependency $rejected '用户取消官方安装器时保留失败状态供重试'
}
finally
{
    Remove-Variable -Name DshDependencyTests -Scope Global
}
