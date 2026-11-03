param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
if (-not $SkipBuild)
{
    & (Join-Path $PSScriptRoot 'Build.ps1')
}
[xml]$project = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'DesktopApp\DSHarness.Desktop.csproj') -Raw
$version = [string]$project.Project.PropertyGroup.Version
$packageName = "dsh-desktop-$version-win-x64"
$artifactRoot = Join-Path $PSScriptRoot 'artifacts'
$packageRoot = Join-Path $artifactRoot ($packageName + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path (Join-Path $packageRoot 'Desktop\runtimes\win-x64\native') -Force | Out-Null

# 固定发布清单，防止把配置、会话、日志、构建缓存或调试符号带入安装包。
$rootFiles = @(
    'Install.cmd', 'Install.ps1', 'Prerequisites.ps1',
    'InstallerDialog.ps1', 'Install-Dependency.ps1',
    'Start-DS-Harness-Background.ps1', 'Stop-DS-Harness.ps1',
    'Start-DS-Harness.mjs', 'Browser-Handoff.ps1', 'app.ico',
    'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md'
)
foreach ($rootFile in $rootFiles)
{
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $rootFile) -Destination $packageRoot
}
$desktopFiles = @(
    'DSHarness.exe', 'DSHarness.exe.config', 'Microsoft.Web.WebView2.Core.dll',
    'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll',
    'runtimes\win-x64\native\WebView2Loader.dll'
)
foreach ($desktopFile in $desktopFiles)
{
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('Desktop\' + $desktopFile)) -Destination (Join-Path $packageRoot ('Desktop\' + $desktopFile))
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'licenses') -Destination $packageRoot -Recurse
$archivePath = Join-Path $artifactRoot ($packageName + '.zip')
Compress-Archive -LiteralPath (Get-ChildItem -LiteralPath $packageRoot -Force).FullName -DestinationPath $archivePath -Force
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $packageName.zip" | Set-Content -LiteralPath (Join-Path $artifactRoot 'SHA256SUMS.txt') -Encoding ascii
Write-Output "发布包：$archivePath"
