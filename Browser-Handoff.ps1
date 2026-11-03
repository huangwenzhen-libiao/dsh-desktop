function Open-BrowserOnce($ServerState) {
  $handoffPath = Join-Path $logDir "dsh-web-$Port.browser.json"
  # A taskbar click requests a visible page. A connection in another browser
  # or an embedded tab does not establish that the user can see this app.
  # Suppress only rapid duplicate OS handoffs, never registered page counts.
  if (-not $NewPage -and (Test-Path -LiteralPath $handoffPath)) {
    $last = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($last.requestedUtc)).TotalSeconds
    if ($last.pid -eq $ServerState.pid -and $last.startedUtcTicks -eq $ServerState.startedUtcTicks -and $age -ge 0 -and $age -lt 3) {
      Write-LaunchLog 'Browser open skipped: duplicate taskbar click within 3s of the previous handoff.'
      return
    }
  }
  Start-Process $uri | Out-Null
  [ordered]@{
    pid = $ServerState.pid
    startedUtcTicks = $ServerState.startedUtcTicks
    requestedUtc = [DateTimeOffset]::UtcNow.ToString('o')
  } | ConvertTo-Json | Set-Content -LiteralPath $handoffPath -Encoding utf8
  Write-LaunchLog "Browser open requested: http://127.0.0.1:$Port/"
}
