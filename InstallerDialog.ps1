# 安装向导只展示当前缺少的组件。官方安装器在独立进程中运行，界面始终保持响应。
function Get-PrerequisiteDisplayName
{
    param([string]$Id)
    switch ($Id)
    {
        'Framework' { return '.NET Framework' }
        'WebView2' { return 'WebView2' }
        'Node' { return 'Node.js' }
        'PowerShell' { return 'PowerShell' }
    }
}

function Start-PrerequisiteInstallJob
{
    param([string]$Id)

    $workingDirectory = Join-Path ([IO.Path]::GetTempPath()) ('DSHDesktopSetup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workingDirectory | Out-Null
    $helperPath = Join-Path $PSScriptRoot 'Install-Dependency.ps1'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $helperPath + '" -ComponentId ' + $Id + ' -WorkingDirectory "' + $workingDirectory + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = 'Hidden'
    return [pscustomobject]@{
        Process = [Diagnostics.Process]::Start($startInfo)
        Directory = $workingDirectory
        Started = [Diagnostics.Stopwatch]::StartNew()
    }
}

function Show-InstallerPreparationDialog
{
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Update-InstallationSearchPath
    $initialComponents = @(Get-InstallationPrerequisites)
    $initialMissingCount = @($initialComponents | Where-Object { -not $_.IsInstalled }).Count

    # 所有回调共享一个状态对象；每次只允许一个官方安装任务，避免重复启动和并行 MSI。
    $state = [pscustomobject]@{
        Components = $initialComponents
        Busy = $false
        RestartRequired = $false
        Job = $null
        CurrentId = ''
        ErrorMessage = ''
        TemporaryDirectories = [Collections.Generic.List[string]]::new()
    }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '安装 DSH Desktop'
    $form.ClientSize = New-Object System.Drawing.Size(600, (300 + 82 * [Math]::Max(1, $initialMissingCount)))
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.AutoScaleMode = 'Dpi'
    $form.BackColor = [Drawing.ColorTranslator]::FromHtml('#F5F7FC')
    $form.ForeColor = [Drawing.ColorTranslator]::FromHtml('#202B42')
    $bodyFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 21, ([Drawing.FontStyle]::Bold))
    $nameFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, ([Drawing.FontStyle]::Bold))
    $form.Font = $bodyFont

    $brand = New-Object System.Windows.Forms.Label
    $brand.Text = 'DSH DESKTOP  /  安装向导'
    $brand.ForeColor = [Drawing.ColorTranslator]::FromHtml('#5466D9')
    $brand.SetBounds(32, 22, 536, 24)
    $heading = New-Object System.Windows.Forms.Label
    $heading.Font = $titleFont
    $heading.SetBounds(28, 56, 544, 48)
    $hint = New-Object System.Windows.Forms.Label
    $hint.ForeColor = [Drawing.ColorTranslator]::FromHtml('#738097')
    $hint.SetBounds(32, 111, 536, 26)
    $form.Controls.AddRange(@($brand, $heading, $hint))

    $rows = @()
    $hints = @{
        Framework = '桌面运行环境'
        WebView2 = '聊天界面显示'
        Node = '本地服务'
        PowerShell = '应用启动工具'
    }
    $symbols = @{
        Framework = 'N'
        WebView2 = 'W'
        Node = 'JS'
        PowerShell = '>_'
    }
    foreach ($component in $initialComponents)
    {
        $card = New-Object System.Windows.Forms.Panel
        $card.BackColor = [Drawing.Color]::White
        $card.Size = New-Object System.Drawing.Size(536, 72)
        $symbol = New-Object System.Windows.Forms.Label
        $symbol.Text = $symbols[$component.Id]
        $symbol.Font = $nameFont
        $symbol.TextAlign = 'MiddleCenter'
        $symbol.BackColor = [Drawing.ColorTranslator]::FromHtml('#ECF0FF')
        $symbol.ForeColor = [Drawing.ColorTranslator]::FromHtml('#5365D6')
        $symbol.SetBounds(14, 14, 44, 44)
        $name = New-Object System.Windows.Forms.Label
        $name.Font = $nameFont
        $name.Text = Get-PrerequisiteDisplayName -Id $component.Id
        $name.SetBounds(72, 13, 320, 25)
        $description = New-Object System.Windows.Forms.Label
        $description.Text = $hints[$component.Id]
        $description.ForeColor = [Drawing.ColorTranslator]::FromHtml('#8590A2')
        $description.SetBounds(72, 40, 320, 23)
        $manual = New-Object System.Windows.Forms.LinkLabel
        $manual.Text = '手动下载'
        $manual.LinkBehavior = 'HoverUnderline'
        $manual.LinkColor = [Drawing.ColorTranslator]::FromHtml('#79859C')
        $manual.SetBounds(425, 27, 95, 24)
        $manual.Tag = $component.DownloadUrl
        $manual.Add_LinkClicked({
            param($sender, $eventArgs)
            try
            {
                Start-Process -FilePath ([string]$sender.Tag) | Out-Null
            }
            catch
            {
                $null = [Windows.Forms.MessageBox]::Show(('请手动访问：' + $sender.Tag), '打开下载页失败')
            }
        })
        $card.Controls.AddRange(@($symbol, $name, $description, $manual))
        $form.Controls.Add($card)
        $rows += [pscustomobject]@{ Id = $component.Id; Card = $card; Description = $description; Manual = $manual }
    }

    $readySummary = New-Object System.Windows.Forms.Label
    $readySummary.ForeColor = [Drawing.ColorTranslator]::FromHtml('#7A879B')
    $readySummary.AutoEllipsis = $true
    $refresh = New-Object System.Windows.Forms.LinkLabel
    $refresh.Text = '重新检测'
    $refresh.LinkBehavior = 'HoverUnderline'
    $refresh.LinkColor = [Drawing.ColorTranslator]::FromHtml('#5466D9')
    $form.Controls.AddRange(@($readySummary, $refresh))

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = 'Bottom'
    $footer.Height = 116
    $footer.BackColor = [Drawing.Color]::White
    $status = New-Object System.Windows.Forms.Label
    $status.ForeColor = [Drawing.ColorTranslator]::FromHtml('#7A879B')
    $status.SetBounds(32, 14, 536, 26)
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Style = 'Marquee'
    $progress.SetBounds(32, 0, 536, 3)
    $progress.Visible = $false
    $primary = New-Object System.Windows.Forms.Button
    $primary.Text = '安装并继续'
    $primary.FlatStyle = 'Flat'
    $primary.FlatAppearance.BorderSize = 0
    $primary.BackColor = [Drawing.ColorTranslator]::FromHtml('#5365DF')
    $primary.ForeColor = [Drawing.Color]::White
    $primary.Font = $nameFont
    $primary.SetBounds(32, 54, 416, 42)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '暂不安装'
    $cancel.FlatStyle = 'Flat'
    $cancel.FlatAppearance.BorderSize = 0
    $cancel.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1F3F8')
    $cancel.ForeColor = [Drawing.ColorTranslator]::FromHtml('#738097')
    $cancel.SetBounds(460, 54, 108, 42)
    $cancel.DialogResult = 'Cancel'
    $footer.Controls.AddRange(@($status, $progress, $primary, $cancel))
    $form.Controls.Add($footer)
    $form.CancelButton = $cancel
    $form.AcceptButton = $primary

    $refreshView = {
        Update-InstallationSearchPath
        $state.Components = @(Get-InstallationPrerequisites)
        $missing = @($state.Components | Where-Object { -not $_.IsInstalled })
        $visibleIndex = 0
        foreach ($row in $rows)
        {
            $component = $state.Components | Where-Object { $_.Id -eq $row.Id } | Select-Object -First 1
            $isMissing = -not $component.IsInstalled
            $row.Card.Visible = $isMissing
            if ($isMissing)
            {
                $row.Card.Location = New-Object Drawing.Point(32, (151 + 82 * $visibleIndex))
                $visibleIndex++
            }
            $row.Manual.Enabled = -not $state.Busy
            $row.Description.Text = $hints[$row.Id]
        }
        $readyNames = @($state.Components | Where-Object { $_.IsInstalled } | ForEach-Object { Get-PrerequisiteDisplayName -Id $_.Id })
        $readySummary.Text = ''
        if ($readyNames.Count -gt 0)
        {
            $readySummary.Text = '已就绪  ·  ' + ($readyNames -join '、')
        }
        $summaryTop = 151 + 82 * $visibleIndex + 6
        $readySummary.SetBounds(32, $summaryTop, 440, 26)
        $refresh.SetBounds(495, $summaryTop, 76, 26)
        $refresh.Enabled = -not $state.Busy
        $primary.Enabled = -not $state.Busy
        $cancel.Enabled = -not $state.Busy
        $progress.Visible = $state.Busy
        if (-not $state.Busy)
        {
            $heading.Text = '再准备 ' + $missing.Count + ' 个组件'
            $hint.Text = '点一下，装好后自动继续。'
            $status.Text = '需要联网；出现 Windows 授权提示时，请按提示继续。'
            $primary.Text = '安装并继续'
            if ($missing.Count -eq 0)
            {
                $heading.Text = '准备好了'
                $hint.Text = '接下来安装 DSH Desktop。'
                $primary.Text = '开始安装'
                $status.Text = '运行环境已就绪。'
            }
            if ($state.ErrorMessage)
            {
                $hint.Text = '没有装好？重试一下，或选择手动下载。'
                $status.Text = $state.ErrorMessage
                $primary.Text = '重试安装'
            }
            if ($state.RestartRequired)
            {
                $heading.Text = '重启后继续'
                $hint.Text = '重启 Windows 后，再打开安装器。'
                $status.Text = '组件已安装，需要重启才能生效。'
                $primary.Text = '关闭安装器'
            }
        }
    }

    $beginNext = {
        & $refreshView
        $missing = @($state.Components | Where-Object { -not $_.IsInstalled })
        if ($missing.Count -eq 0)
        {
            $state.Busy = $false
            $form.DialogResult = 'OK'
            $form.Close()
            return
        }
        $state.CurrentId = $missing[0].Id
        $state.Job = Start-PrerequisiteInstallJob -Id $state.CurrentId
        $state.TemporaryDirectories.Add($state.Job.Directory)
        $heading.Text = '正在准备组件'
        $hint.Text = '保持窗口打开，装好后自动继续。'
        $primary.Text = '正在准备…'
    }
    $primary.Add_Click({
        if ($state.RestartRequired)
        {
            $form.DialogResult = 'Cancel'
            $form.Close()
            return
        }
        $state.ErrorMessage = ''
        $state.Busy = $true
        try
        {
            & $beginNext
        }
        catch
        {
            $state.Busy = $false
            $state.ErrorMessage = '没能开始安装，请重试。'
            Write-Warning $_.Exception.Message
            & $refreshView
        }
    })
    $refresh.Add_LinkClicked({ & $refreshView })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        # 安装器仍可能持有 MSI 或等待 UAC；不在关窗时强制中止系统组件安装。
        if ($state.Busy)
        {
            $eventArgs.Cancel = $true
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        if (-not $state.Busy -or $null -eq $state.Job)
        {
            return
        }
        try
        {
            $jobStatus = $null
            $statusPath = Join-Path $state.Job.Directory 'status.json'
            if (Test-Path -LiteralPath $statusPath)
            {
                # 允许辅助进程原子替换状态文件，避免检测进程占用旧文件导致安装中断。
                $statusStream = [IO.FileStream]::new($statusPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $statusReader = [IO.StreamReader]::new($statusStream)
                try
                {
                    $jobStatus = $statusReader.ReadToEnd() | ConvertFrom-Json
                }
                finally
                {
                    $statusReader.Dispose()
                    $statusStream.Dispose()
                }
                $name = Get-PrerequisiteDisplayName -Id $state.CurrentId
                $phaseText = switch ($jobStatus.phase)
                {
                    'download' { '正在下载 ' + $name }
                    'verify' { '正在准备 ' + $name }
                    'install' { '正在安装 ' + $name }
                    default { '正在检查 ' + $name }
                }
                $status.Text = $phaseText + '…'
                ($rows | Where-Object { $_.Id -eq $state.CurrentId }).Description.Text = $phaseText
            }
            if (-not $state.Job.Process.HasExited)
            {
                return
            }
            $exitCode = $state.Job.Process.ExitCode
            $state.Job.Process.Dispose()
            $state.Job = $null
            if ($exitCode -ne 0 -or $null -eq $jobStatus -or $jobStatus.phase -eq 'failed')
            {
                $state.Busy = $false
                $state.ErrorMessage = '安装未完成，请重试或手动下载。'
                if ($jobStatus -and $jobStatus.message)
                {
                    Write-Warning $jobStatus.message
                }
                & $refreshView
                return
            }
            if ($jobStatus.phase -eq 'restart')
            {
                $state.Busy = $false
                $state.RestartRequired = $true
                & $refreshView
                return
            }
            Update-InstallationSearchPath
            $current = Get-InstallationPrerequisites | Where-Object { $_.Id -eq $state.CurrentId }
            if (-not $current.IsInstalled)
            {
                throw '组件仍未就绪，请完成安装窗口后重新检测。'
            }
            & $beginNext
        }
        catch
        {
            if ($state.Job -and -not $state.Job.Process.HasExited)
            {
                # 状态文件可能刚被原子替换。任务仍在运行时保留串行状态，下一次再读取。
                Write-Verbose $_.Exception.Message
                return
            }
            $state.Busy = $false
            $state.ErrorMessage = '请完成安装窗口，再点重新检测。'
            Write-Warning $_.Exception.Message
            & $refreshView
        }
    })
    try
    {
        & $refreshView
        $timer.Start()
        return $form.ShowDialog()
    }
    finally
    {
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
        $bodyFont.Dispose()
        $titleFont.Dispose()
        $nameFont.Dispose()
        # 只清理本次生成、且确认位于系统临时目录下的独立目录。
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        foreach ($directory in $state.TemporaryDirectories)
        {
            $resolvedDirectory = [IO.Path]::GetFullPath($directory)
            if ($resolvedDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($resolvedDirectory) -match '^DSHDesktopSetup-[a-f0-9]{32}$')
            {
                try
                {
                    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force -ErrorAction Stop
                }
                catch
                {
                    Write-Verbose ('保留尚被安装器占用的临时文件：' + $_.Exception.Message)
                }
            }
        }
    }
}
