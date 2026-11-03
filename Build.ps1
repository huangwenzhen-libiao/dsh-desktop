# 从源码构建；不会安装或启动应用，也不会改动已有 DSH 数据。
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Tools\Build-Icon.ps1')
& (Join-Path $PSScriptRoot 'DesktopApp\Build.ps1') -OutputPath (Join-Path $PSScriptRoot 'Desktop')
