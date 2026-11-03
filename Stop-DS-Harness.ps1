param([ValidateRange(1, 65535)][int]$Port = 3080)
# Explicit stop terminates only the process recorded by this launcher.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$statePath = Join-Path $root "dsh-web-$Port.state.json"
$mutex = [Threading.Mutex]::new($false, "Local\DSHarness-$Port")
$locked = $false
try {
  try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(135)) }
  catch [Threading.AbandonedMutexException] { $locked = $true }
  if (-not $locked) { throw 'Startup is still in progress. Retry Stop later.' }
  if (-not (Test-Path -LiteralPath $statePath)) { throw 'No managed server state exists. No process was stopped.' }
  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  $server = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
  if ($server -and $server.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$state.startedUtcTicks -and $server.Path -eq $state.executable) {
    Stop-Process -InputObject $server -Force
    Wait-Process -Id $server.Id -Timeout 15 -ErrorAction SilentlyContinue
    Write-Output "Stopped managed DS Harness PID $($server.Id)."
  } else {
    Write-Output 'The recorded DS Harness process has already exited. No other process was stopped.'
  }
  Remove-Item -LiteralPath $statePath -Force
  Remove-Item -LiteralPath (Join-Path $root "dsh-web-$Port.pid") -Force -ErrorAction SilentlyContinue
} finally {
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
