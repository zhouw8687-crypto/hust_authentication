[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$folder = Join-Path $env:ProgramFiles 'CampusNetworkWiFiFailover'
$workerLog = Join-Path $folder 'CampusNetworkWiFiFailover.log'
$observeLog = Join-Path $PSScriptRoot 'CampusNetworkWiFiFailover.observe.log'
$name = '华科校园网备用连接'

function Get-DisplayLog {
    if (Test-Path -LiteralPath $workerLog) { return $workerLog }
    return $observeLog
}

function Get-TrayStatus {
    $log = Get-DisplayLog
    if (!(Test-Path -LiteralPath $log)) { return '等待开机任务写入日志' }
    $file = Get-Item -LiteralPath $log
    if (((Get-Date) - $file.LastWriteTime).TotalMinutes -gt 7) { return '近期无新记录，请检查开机任务' }
    $sample = Get-Content -LiteralPath $log -Tail 30 -ErrorAction Stop |
        Where-Object { $_ -match ' CHECK ' } | Select-Object -Last 1
    if ($log -eq $observeLog) {
        if ($sample -match 'wired_https=True') { return '有线在线，自动切换待启用' }
        return '只读监控，自动切换待启用'
    }
    if ($sample -match 'phase=fallback') { return '正在使用备用 Wi-Fi' }
    if ($sample -match 'phase=trial') { return '正在测试备用 Wi-Fi' }
    if ($sample -match 'wired_https=True') { return '有线校园网在线' }
    if ($sample -match 'wired=no-ipv4|wired=no-gateway') { return '有线未取得可用地址或网关' }
    if ($sample -match 'wired=link-down') { return '有线网线未连接' }
    if ($sample -match 'wired_https=False') { return '有线外网探测失败' }
    return '等待第一次检测'
}

if ($Check) {
    Get-TrayStatus
    return
}

$mutex = [Threading.Mutex]::new($false, 'Local\CampusNetworkWiFiFailover.Tray')
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { return }
    [Windows.Forms.Application]::EnableVisualStyles()
    $app = New-Object Windows.Forms.ApplicationContext
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $stateItem = $menu.Items.Add('正在读取状态')
    $stateItem.Enabled = $false
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $openLog = $menu.Items.Add('打开切换日志')
    $exitTray = $menu.Items.Add('退出托盘图标')
    $tray = New-Object Windows.Forms.NotifyIcon
    $tray.Icon = [Drawing.SystemIcons]::Information
    $tray.ContextMenuStrip = $menu
    $tray.Text = $name
    $tray.Visible = $true
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 8000
    $refresh = {
        try { $status = Get-TrayStatus } catch { $status = '暂时无法读取日志' }
        $stateItem.Text = $status
        $tray.Text = "$name · $status"
    }
    $viewLog = {
        $log = Get-DisplayLog
        if (Test-Path -LiteralPath $log) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"{0}"' -f $log)
        } else {
            [void][Windows.Forms.MessageBox]::Show('开机任务还没有生成日志。', $name)
        }
    }
    $timer.add_Tick($refresh)
    $menu.add_Opening($refresh)
    $openLog.add_Click($viewLog)
    $tray.add_DoubleClick($viewLog)
    $exitTray.add_Click({ $app.ExitThread() })
    & $refresh
    $timer.Start()
    try { [Windows.Forms.Application]::Run($app) } finally {
        $timer.Dispose()
        $tray.Visible = $false
        $tray.Dispose()
        $menu.Dispose()
        $app.Dispose()
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
