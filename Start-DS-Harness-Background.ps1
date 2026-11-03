param(
  [string]$InstallPath = '',
  [ValidateRange(1, 65535)][int]$Port = 3080,
  [switch]$NoBrowser,
  [ValidateRange(1, 600)][int]$TimeoutSeconds = 300,
  [switch]$NoTakeover,
  [switch]$NoPopup,
  [switch]$NewPage
)
# NoTakeover is accepted for old shortcuts; unknown listeners are always left alone.
$ErrorActionPreference = 'Stop'
# 安装位置由本机安装器记录；源码和发布包不包含作者的绝对路径。
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
  $configurationPath = Join-Path $PSScriptRoot 'launcher.config.json'
  if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
    $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
    $InstallPath = [string]$configuration.runtimePath
  }
  if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $InstallPath = Join-Path $PSScriptRoot 'runtime'
  } elseif (-not [IO.Path]::IsPathRooted($InstallPath)) {
    $InstallPath = Join-Path $PSScriptRoot $InstallPath
  }
}
$logDir = $PSScriptRoot
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$uri = "http://127.0.0.1:$Port/"
$statePath = Join-Path $logDir "dsh-web-$Port.state.json"
$markerPath = Join-Path $logDir "dsh-web-$Port.pid"
$launcherLog = Join-Path $logDir "launcher-$Port.log"
$errorLog = Join-Path $logDir "launcher-$Port.errors.log"
$mutex = [Threading.Mutex]::new($false, "Local\DSHarness-$Port")
$locked = $false

function Write-LaunchLog([string]$Message) {
  Add-Content -LiteralPath $launcherLog -Value "$(Get-Date -Format o) [launcher $PID] $Message" -Encoding utf8
}
function Get-Listeners {
  @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique)
}
function Get-ManagedProcess($State) {
  if (-not $State) { return $null }
  $candidate = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
  if ($candidate -and $candidate.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$State.startedUtcTicks -and
      $candidate.Path -eq $State.executable) { return $candidate }
  return $null
}
function Get-ReadyUri([string]$StdoutPath) {
  if (-not $StdoutPath -or -not (Test-Path -LiteralPath $StdoutPath)) { return $null }
  $pattern = '^dsh web: (?<url>http://127\.0\.0\.1:' + $Port + '(?:[/?][^\s]*)?)(?:\s|$)'
  $matchLine = Select-String -LiteralPath $StdoutPath -Pattern $pattern | Select-Object -Last 1
  if (-not $matchLine) { return $null }
  $candidateUri = [Uri]$matchLine.Matches[0].Groups['url'].Value
  if ($candidateUri.Scheme -ne 'http' -or $candidateUri.Host -ne '127.0.0.1' -or $candidateUri.Port -ne $Port) { return $null }
  return $candidateUri.AbsoluteUri
}
function Test-Ready([int]$ServerPid, [string]$StdoutPath) {
  $readyUri = Get-ReadyUri $StdoutPath
  if (-not $readyUri) { return $false }
  if (@(Get-Listeners) -notcontains $ServerPid) { return $false }
  try {
    $response = Invoke-WebRequest -Uri $readyUri -UseBasicParsing -TimeoutSec 2
    return $response.StatusCode -eq 200 -and $response.Content.Contains('__DSH_BOOT__')
  } catch { return $false } # Routes may still be mounting.
}
. (Join-Path $PSScriptRoot 'Browser-Handoff.ps1')
try {
  try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds + 15)) }
  catch [Threading.AbandonedMutexException] { $locked = $true }
  if (-not $locked) { throw 'Another launch is still in progress. No second server was started.' }
  Write-LaunchLog 'Launch requested.'
  $state = $null
  if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  }
  $server = Get-ManagedProcess $state
  $listeners = @(Get-Listeners)
  if ($listeners.Count -gt 0 -and (-not $server -or @($listeners | Where-Object { $_ -ne $server.Id }).Count -gt 0)) {
    throw "Port $Port is occupied by an unmanaged process (PID $($listeners -join ', ')). It was not stopped."
  }
  if ($server) {
    Write-LaunchLog "Reusing existing server PID $($server.Id), including a server still starting."
  } else {
    $resolvedInstall = (Resolve-Path -LiteralPath $InstallPath).Path
    $entry = Join-Path $resolvedInstall 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw "Missing CLI entry: $entry" }
    $runtime = Join-Path $PSScriptRoot 'Start-DS-Harness.mjs'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw "Missing startup runtime: $runtime" }
    $nodePath = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $runId = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
    $stdoutPath = Join-Path $logDir "dsh-web-$Port-$runId.stdout.log"
    $stderrPath = Join-Path $logDir "dsh-web-$Port-$runId.stderr.log"
    $server = Start-Process -FilePath $nodePath -WorkingDirectory $resolvedInstall -WindowStyle Hidden `
      -ArgumentList @(('"' + $runtime + '"'), ('"' + $resolvedInstall + '"'), 'web', '--port', "$Port", '--no-open') `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $state = [ordered]@{
      pid = $server.Id
      startedUtcTicks = $server.StartTime.ToUniversalTime().Ticks.ToString()
      executable = $server.Path
      installPath = $resolvedInstall
      launchMode = 'compiled-with-cache'
      stdout = $stdoutPath
      stderr = $stderrPath
    }
    # Record ownership before readiness; a timeout must not cause a second launch.
    $tempState = "$statePath.$PID.tmp"
    $state | ConvertTo-Json | Set-Content -LiteralPath $tempState -Encoding utf8
    Move-Item -LiteralPath $tempState -Destination $statePath -Force
    Set-Content -LiteralPath $markerPath -Value $server.Id -Encoding ascii
    Write-LaunchLog "Started PID $($server.Id). stdout=$stdoutPath stderr=$stderrPath"
  }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $waitWatch = [Diagnostics.Stopwatch]::StartNew()
  $nextProgressSeconds = 15
  $ready = $false
  do {
    if (-not (Get-ManagedProcess $state)) {
      $detail = if (Test-Path -LiteralPath $state.stderr) { (Get-Content -LiteralPath $state.stderr -Tail 15) -join "`n" } else { '' }
      throw "Server exited before readiness. See $($state.stderr).`n$detail"
    }
    if (Test-Ready $server.Id $state.stdout) { $ready = $true; break }
    if ($waitWatch.Elapsed.TotalSeconds -ge $nextProgressSeconds) {
      Write-LaunchLog "Still initializing PID $($server.Id); waited $([int]$waitWatch.Elapsed.TotalSeconds)s."
      $nextProgressSeconds += 15
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  if (-not $ready) { throw "Startup timed out after $TimeoutSeconds seconds. PID $($server.Id) is retained; another click will reuse it. See $($state.stderr)." }
  $uri = Get-ReadyUri $state.stdout
  Write-LaunchLog "Ready: http://127.0.0.1:$Port/ PID $($server.Id); readiness wait $($waitWatch.ElapsedMilliseconds)ms"
  if (-not $NoBrowser) { Open-BrowserOnce $state }
} catch {
  $detail = "$(Get-Date -Format o) [launcher $PID] $($_.Exception.Message)`n$($_.ScriptStackTrace)"
  Add-Content -LiteralPath $errorLog -Value $detail -Encoding utf8
  Write-LaunchLog "FAILED: $($_.Exception.Message)"
  if (-not $NoPopup -and -not $NoBrowser) {
    $shell = New-Object -ComObject WScript.Shell
    $null = $shell.Popup("$($_.Exception.Message)`n`nError log: $errorLog", 30, 'DS Harness', 16)
  }
  [Console]::Error.WriteLine($detail)
  exit 1
} finally {
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
