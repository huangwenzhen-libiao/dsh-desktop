# 直接验证向导自身的事件与状态，不向真实安装器或系统发送鼠标键盘输入。
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $sourceRoot 'Prerequisites.ps1')
. (Join-Path $sourceRoot 'InstallerDialog.ps1')
Add-Type -AssemblyName System.Windows.Forms
$global:DshDialogTests = @{}
$initialComponents = @(Get-InstallationPrerequisites)
$originalDialogDefinition = (Get-Command Show-InstallerPreparationDialog).Definition

function Get-TestDialogComponents
{
    return $global:DshDialogTests.Components
}

function Start-TestDialogJob
{
    param([string]$Id)
    $global:DshDialogTests.StartedIds.Add($Id)
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('DSHDesktopSetup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    $phase = $global:DshDialogTests.Phase
    $exitCode = 0
    if ($phase -eq 'complete')
    {
        ($global:DshDialogTests.Components | Where-Object { $_.Id -eq $Id }).IsInstalled = $true
    }
    if ($phase -eq 'failed')
    {
        $exitCode = 1
    }
    [ordered]@{ phase = $phase; message = '模拟安装结果' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $directory 'status.json') -Encoding UTF8
    $process = [pscustomobject]@{ HasExited = $true; ExitCode = $exitCode }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    return [pscustomobject]@{ Process = $process; Directory = $directory }
}

Set-Alias -Name Get-InstallationPrerequisites -Value Get-TestDialogComponents
Set-Alias -Name Start-PrerequisiteInstallJob -Value Start-TestDialogJob
try
{
    foreach ($phase in @('complete', 'failed', 'restart'))
    {
        $global:DshDialogTests.Components = @($initialComponents | ForEach-Object {
            [pscustomobject]@{ Id = $_.Id; Name = $_.Name; IsInstalled = ($_.Id -notin @('Framework', 'WebView2')); DownloadUrl = $_.DownloadUrl }
        })
        $global:DshDialogTests.StartedIds = [Collections.Generic.List[string]]::new()
        $global:DshDialogTests.Phase = $phase
        $global:DshDialogTests.FinalStateChecked = $false
        # 保留真实 ShowDialog 消息循环，由向导自己的 Shown/Timer 事件完成模拟交互。
        $testEntry = @'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $testTimer = New-Object System.Windows.Forms.Timer
        $testTimer.Interval = 100
        $testTimer.Add_Tick({
            if ($watch.Elapsed.TotalSeconds -gt 10)
            {
                $global:DshDialogTests.Error = '向导没有在规定时间内完成。'
                $state.Busy = $false
                $form.DialogResult = 'Cancel'
                $form.Close()
            }
            if (-not $state.Busy -and ($state.ErrorMessage -or $state.RestartRequired))
            {
                if ($state.RestartRequired -and $primary.Text -ne '关闭安装器')
                {
                    $global:DshDialogTests.Error = '需要重启时主按钮没有切换为关闭。'
                }
                if ($state.ErrorMessage -and $primary.Text -ne '重试安装')
                {
                    $global:DshDialogTests.Error = '安装失败后没有显示重试入口。'
                }
                $global:DshDialogTests.FinalStateChecked = $true
                $form.DialogResult = 'Cancel'
                $form.Close()
            }
        })
        $form.Add_Shown({
            if (@($rows | Where-Object { $_.Card.Visible }).Count -ne 2)
            {
                $global:DshDialogTests.Error = '应当只显示两个缺失组件。'
            }
            if ($heading.Text -ne '再准备 2 个组件' -or $primary.Text -ne '安装并继续')
            {
                $global:DshDialogTests.Error = '初次进入时主操作不明确。'
            }
            $primary.PerformClick()
            $testTimer.Start()
        })
        try { return $form.ShowDialog() }
        finally { $testTimer.Stop(); $testTimer.Dispose() }
'@
        $definition = $originalDialogDefinition.Replace('return $form.ShowDialog()', $testEntry)
        Set-Item -Path Function:\Show-InstallerPreparationDialog -Value ([ScriptBlock]::Create($definition))
        $result = Show-InstallerPreparationDialog
        if ($global:DshDialogTests.Error)
        {
            throw $global:DshDialogTests.Error
        }
        if ($phase -eq 'complete')
        {
            if ($result -ne 'OK' -or ($global:DshDialogTests.StartedIds -join ',') -ne 'Framework,WebView2')
            {
                throw '逐项安装完成后没有自动继续，或重复启动了组件安装器。'
            }
        }
        elseif (-not $global:DshDialogTests.FinalStateChecked -or $global:DshDialogTests.StartedIds.Count -ne 1)
        {
            throw '失败或重启时没有停止后续安装。'
        }
        Write-Output ('PASS: 向导真实事件流程 ' + $phase)
    }
}
finally
{
    Remove-Variable -Name DshDialogTests -Scope Global
}
