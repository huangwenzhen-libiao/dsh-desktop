$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Tools\Test-Prerequisites.ps1')
& (Join-Path $PSScriptRoot 'Tools\Test-DependencyInstaller.ps1')
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Tools\Test-InstallerDialog.ps1')
if ($LASTEXITCODE -ne 0)
{
    throw '安装向导事件测试失败。'
}
$testProject = Join-Path $PSScriptRoot 'DesktopApp\Tests\BackendTests.csproj'
& dotnet build $testProject -c Release --nologo
if ($LASTEXITCODE -ne 0)
{
    throw '后台契约测试构建失败。'
}
& (Join-Path $PSScriptRoot 'DesktopApp\Tests\bin\Release\net472\BackendTests.exe') $PSScriptRoot
if ($LASTEXITCODE -ne 0)
{
    throw '后台契约测试失败。'
}
& (Join-Path $PSScriptRoot 'Tools\Test-Launcher.ps1')
