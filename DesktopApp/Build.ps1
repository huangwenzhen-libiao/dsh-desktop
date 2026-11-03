param([string]$OutputPath = (Join-Path $PSScriptRoot '..\Desktop'))
$ErrorActionPreference = 'Stop'
$targetExe = Join-Path ([IO.Path]::GetFullPath($OutputPath)) 'DSHarness.exe'
$running = Get-Process -Name DSHarness -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $targetExe }
if ($running) { throw '请先从应用菜单选择“退出应用（保留后台）”，再重新构建。' }
& dotnet build (Join-Path $PSScriptRoot 'DSHarness.Desktop.csproj') -c Release -o $OutputPath --nologo
if ($LASTEXITCODE -ne 0) { throw 'DS Harness 桌面应用构建失败。' }
Write-Output ('已生成：' + (Join-Path ([IO.Path]::GetFullPath($OutputPath)) 'DSHarness.exe'))
