# 使用独立模拟服务验证可移植路径、单实例、端口保护和实际停止脚本。
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $sourceRoot ('artifacts\launcher-test-' + [Guid]::NewGuid().ToString('N'))
$runtimeRoot = Join-Path $testRoot 'runtime with spaces'
$runtimePackageRoot = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh'
New-Item -ItemType Directory -Path (Join-Path $runtimePackageRoot 'lib') -Force | Out-Null
foreach ($file in @('Start-DS-Harness-Background.ps1', 'Stop-DS-Harness.ps1', 'Start-DS-Harness.mjs', 'Browser-Handoff.ps1'))
{
    Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination $testRoot
}
[ordered]@{ runtimePath = 'runtime with spaces' } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $testRoot 'launcher.config.json') -Encoding utf8
'{"name":"@deepseek-ai/dsh","version":"0.2.0-rc.2","type":"module"}' |
    Set-Content -LiteralPath (Join-Path $runtimePackageRoot 'package.json') -Encoding utf8
$mockServer = @'
import http from 'node:http';
export async function runCli() {
    const port = Number(process.argv[process.argv.indexOf('--port') + 1]);
    const server = http.createServer((request, response) => {
        response.setHeader('Content-Type', 'text/html; charset=utf-8');
        response.end('<html><script>window.__DSH_BOOT__={}</script></html>');
    });
    await new Promise(resolve => server.listen(port, '127.0.0.1', resolve));
    console.log(`dsh web: http://127.0.0.1:${port}/`);
}
'@
Set-Content -LiteralPath (Join-Path $runtimePackageRoot 'lib\bin.js') -Value $mockServer -Encoding utf8

function Get-TestPort
{
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try
    {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    }
    finally
    {
        $listener.Stop()
    }
}

$port = Get-TestPort
$statePath = Join-Path $testRoot "dsh-web-$port.state.json"
$startScript = Join-Path $testRoot 'Start-DS-Harness-Background.ps1'
$stopScript = Join-Path $testRoot 'Stop-DS-Harness.ps1'
$managedPid = $null
try
{
    & pwsh.exe -NoProfile -File $startScript -Port $port -NoBrowser -NoPopup -TimeoutSeconds 15
    if ($LASTEXITCODE -ne 0)
    {
        throw '相对 runtimePath 启动模拟后台失败。'
    }
    $firstState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $managedPid = $firstState.pid
    & pwsh.exe -NoProfile -File $startScript -Port $port -NoBrowser -NoPopup -TimeoutSeconds 15
    if ($LASTEXITCODE -ne 0)
    {
        throw '重复启动模拟后台失败。'
    }
    $secondState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($firstState.pid -ne $secondState.pid -or $firstState.startedUtcTicks -ne $secondState.startedUtcTicks)
    {
        throw '重复启动没有复用已有后台。'
    }
    Write-Output 'PASS: 含空格的相对后台路径可启动，重复启动保持同一进程。'

    # 暂时移走测试状态，让同一个模拟监听器成为未登记进程，验证不会接管它。
    $savedStatePath = Join-Path $testRoot 'saved-test-state.json'
    Move-Item -LiteralPath $statePath -Destination $savedStatePath
    try
    {
        & pwsh.exe -NoProfile -File $startScript -Port $port -NoBrowser -NoPopup -TimeoutSeconds 3 2>$null
        if ($LASTEXITCODE -eq 0)
        {
            throw '端口已被未登记进程占用时没有拒绝启动。'
        }
        if (-not (Get-Process -Id $managedPid -ErrorAction SilentlyContinue))
        {
            throw '未登记的监听进程被错误停止。'
        }
    }
    finally
    {
        Move-Item -LiteralPath $savedStatePath -Destination $statePath
    }
    Write-Output 'PASS: 未登记进程占用端口时拒绝启动，原进程保持运行。'
    & pwsh.exe -NoProfile -File $stopScript -Port $port
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $statePath))
    {
        throw '停止测试后台后未清理对应状态。'
    }
    $managedPid = $null
    Write-Output 'PASS: 实际停止脚本只停止当前测试后台。'

    # 安装到隔离目录并复用模拟 npm 安装；跳过快捷方式，不触碰当前用户的实际应用。
    $installRoot = Join-Path $testRoot 'installed application'
    & (Join-Path $sourceRoot 'Install.ps1') -InstallDirectory $installRoot -RuntimePath $runtimeRoot -SkipShortcuts
    $configuration = Get-Content -LiteralPath (Join-Path $installRoot 'launcher.config.json') -Raw | ConvertFrom-Json
    if ($configuration.runtimePath -ne $runtimeRoot -or -not (Test-Path -LiteralPath (Join-Path $installRoot 'Desktop\DSHarness.exe')))
    {
        throw '独立安装目录缺少程序或后台配置。'
    }
    Write-Output 'PASS: 隔离安装完成，后台配置指向用户指定目录。'
}
finally
{
    if (Test-Path -LiteralPath $statePath)
    {
        & pwsh.exe -NoProfile -File $stopScript -Port $port
    }
}
