param(
    [ValidateSet('Framework', 'WebView2', 'Node', 'PowerShell')][string]$ComponentId,
    [string]$WorkingDirectory
)

# 独立安装进程负责下载与等待官方安装器；主界面只读取状态，因此不会被网络或 UAC 阻塞。
function Get-PrerequisiteInstaller
{
    param([string]$Id)

    switch ($Id)
    {
        'Framework'
        {
            return [pscustomobject]@{
                Url = 'https://go.microsoft.com/fwlink/?linkid=2088631'
                FileName = 'dotnet-framework-4.8.exe'
                Arguments = '/passive /norestart'
                IsMsi = $false
                RequiresAdmin = $true
                Sha256 = ''
            }
        }
        'WebView2'
        {
            return [pscustomobject]@{
                Url = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
                FileName = 'MicrosoftEdgeWebview2Setup.exe'
                Arguments = '/silent /install'
                IsMsi = $false
                RequiresAdmin = $false
                Sha256 = ''
            }
        }
        'Node'
        {
            return [pscustomobject]@{
                Url = 'https://nodejs.org/dist/v22.22.1/node-v22.22.1-x64.msi'
                FileName = 'node-v22.22.1-x64.msi'
                Arguments = ''
                IsMsi = $true
                RequiresAdmin = $true
                Sha256 = '444c1c325dc26b7237ffc521b092aa778400665e9757e97405ab95a7584053c8'
            }
        }
        'PowerShell'
        {
            return [pscustomobject]@{
                Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.msi'
                FileName = 'PowerShell-7.6.9-win-x64.msi'
                Arguments = 'ADD_PATH=1'
                IsMsi = $true
                RequiresAdmin = $true
                Sha256 = ''
            }
        }
        default
        {
            throw '不支持的安装组件。'
        }
    }
}

function Write-DependencyStatus
{
    param([string]$Directory, [string]$Phase, [string]$Message = '')

    $statusPath = Join-Path $Directory 'status.json'
    $temporaryPath = Join-Path $Directory 'status.next.json'
    [ordered]@{ phase = $Phase; message = $Message } | ConvertTo-Json |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $statusPath -Force
}

function Test-PrerequisiteInstallerFile
{
    param([string]$Path, $Installer)

    if ($Installer.Sha256)
    {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($hash -ne $Installer.Sha256)
        {
            throw '安装包下载不完整，请重试。'
        }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid')
    {
        throw '安装包校验未通过，请重试或手动下载。'
    }
}

function Invoke-PrerequisiteInstaller
{
    param([string]$Path, $Installer)

    $startOptions = @{
        FilePath = $Path
        ArgumentList = $Installer.Arguments
        PassThru = $true
    }
    if ($Installer.IsMsi)
    {
        $startOptions.FilePath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $startOptions.ArgumentList = '/i "' + $Path + '" /passive /norestart ' + $Installer.Arguments
    }
    if ($Installer.RequiresAdmin)
    {
        $startOptions.Verb = 'RunAs'
    }

    $process = Start-Process @startOptions
    try
    {
        # 不终止系统安装器。等待超时后由用户完成已弹出的安装窗口，再重新检测。
        if (-not $process.WaitForExit(1200000))
        {
            throw '请先完成弹出的安装窗口，再重新检测。'
        }
        return $process.ExitCode
    }
    finally
    {
        $process.Dispose()
    }
}

function Install-PrerequisiteComponent
{
    param([string]$Id, [string]$Directory)

    $installer = Get-PrerequisiteInstaller -Id $Id
    $installerPath = Join-Path $Directory $installer.FileName
    Write-DependencyStatus -Directory $Directory -Phase 'download'
    # Windows PowerShell 5.1 的旧默认协议可能无法连接官方下载站点，仅更新本进程。
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $installer.Url -OutFile $installerPath -UseBasicParsing -TimeoutSec 300
    Write-DependencyStatus -Directory $Directory -Phase 'verify'
    Test-PrerequisiteInstallerFile -Path $installerPath -Installer $installer
    Write-DependencyStatus -Directory $Directory -Phase 'install'
    $exitCode = Invoke-PrerequisiteInstaller -Path $installerPath -Installer $installer
    if ($exitCode -eq 3010 -or $exitCode -eq 1641)
    {
        Write-DependencyStatus -Directory $Directory -Phase 'restart'
        return
    }
    if ($exitCode -ne 0)
    {
        throw ('组件安装未完成（' + $exitCode + '），请重试。')
    }
    Write-DependencyStatus -Directory $Directory -Phase 'complete'
}

if ($MyInvocation.InvocationName -ne '.')
{
    $ErrorActionPreference = 'Stop'
    $canWriteStatus = $false
    try
    {
        $resolvedRoot = [IO.Path]::GetFullPath($WorkingDirectory)
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolvedRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedRoot) -notmatch '^DSHDesktopSetup-[a-f0-9]{32}$')
        {
            throw '安装临时目录无效。'
        }
        $canWriteStatus = $true
        Install-PrerequisiteComponent -Id $ComponentId -Directory $resolvedRoot
    }
    catch
    {
        if ($canWriteStatus -and (Test-Path -LiteralPath $resolvedRoot))
        {
            Write-DependencyStatus -Directory $resolvedRoot -Phase 'failed' -Message $_.Exception.Message
        }
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
