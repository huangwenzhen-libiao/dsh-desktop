$ErrorActionPreference = 'Stop'
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
