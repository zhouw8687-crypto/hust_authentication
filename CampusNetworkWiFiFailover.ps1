[CmdletBinding()]
param(
    [ValidateSet('Observe','Check','Active','Install','Uninstall')]
    [string]$Mode = 'Observe',
    [string]$WiredAlias = '以太网',
    [string]$WifiAlias = 'WLAN',
    [string[]]$WifiProfiles = @(),
    [ValidateRange(5,300)][int]$IntervalSeconds = 15,
    [ValidateRange(1,240)][int]$TrialIntervalMinutes = 30,
    [ValidateRange(15,180)][int]$TrialSeconds = 60,
    [datetime]$Until = [datetime]::MaxValue,
    [string]$LogPath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
if (!$ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'failover.local.json' }
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (!$PSBoundParameters.ContainsKey('WiredAlias') -and $config.WiredAlias) { $WiredAlias = [string]$config.WiredAlias }
    if (!$PSBoundParameters.ContainsKey('WifiAlias') -and $config.WifiAlias) { $WifiAlias = [string]$config.WifiAlias }
    if (!$PSBoundParameters.ContainsKey('WifiProfiles') -and $config.WifiProfiles) { $WifiProfiles = @($config.WifiProfiles | ForEach-Object { [string]$_ }) }
    if (!$PSBoundParameters.ContainsKey('IntervalSeconds') -and $config.IntervalSeconds) { $IntervalSeconds = [int]$config.IntervalSeconds }
    if (!$PSBoundParameters.ContainsKey('TrialIntervalMinutes') -and $config.TrialIntervalMinutes) { $TrialIntervalMinutes = [int]$config.TrialIntervalMinutes }
    if (!$PSBoundParameters.ContainsKey('TrialSeconds') -and $config.TrialSeconds) { $TrialSeconds = [int]$config.TrialSeconds }
}
if ($IntervalSeconds -lt 5 -or $IntervalSeconds -gt 300 -or
    $TrialIntervalMinutes -lt 1 -or $TrialIntervalMinutes -gt 240 -or
    $TrialSeconds -lt 15 -or $TrialSeconds -gt 180) {
    throw 'The configured polling or trial interval is out of range. See README.md.'
}
$task = '华科校园网备用连接'
$program = 'CampusNetworkWiFiFailover'
$installDir = Join-Path $env:ProgramFiles $program
$installed = Join-Path $installDir "$program.ps1"
$installedConfig = Join-Path $installDir 'failover.local.json'
$backup = Join-Path $installDir 'wifi-metrics.json'
$trialRequest = Join-Path $installDir 'first-wifi-trial'
$native = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

function Set-TrayStartup([string]$TrayScript) {
    $startup = [Environment]::GetFolderPath('Startup')
    $link = Join-Path $startup "$task.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $native
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}"' -f $TrayScript
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class CampusSavedWifi {
    private const uint PerUserProfile = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProfileInfo {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Name;
        public uint Flags;
    }

    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanGetProfileList(IntPtr handle, ref Guid interfaceId, IntPtr reserved, out IntPtr list);

    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr memory);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);

    public static string[] Get(Guid interfaceId, bool allUsersOnly) {
        IntPtr handle;
        uint version;
        uint result = WlanOpenHandle(2, IntPtr.Zero, out version, out handle);
        if (result != 0) throw new Win32Exception((int)result);
        IntPtr list = IntPtr.Zero;
        try {
            result = WlanGetProfileList(handle, ref interfaceId, IntPtr.Zero, out list);
            if (result != 0) throw new Win32Exception((int)result);
            int count = Marshal.ReadInt32(list);
            int size = Marshal.SizeOf(typeof(ProfileInfo));
            var names = new List<string>();
            for (int index = 0; index < count; index++) {
                var entry = (ProfileInfo)Marshal.PtrToStructure(
                    IntPtr.Add(list, 8 + index * size), typeof(ProfileInfo));
                if (!allUsersOnly || (entry.Flags & PerUserProfile) == 0) names.Add(entry.Name);
            }
            return names.ToArray();
        } finally {
            if (list != IntPtr.Zero) WlanFreeMemory(list);
            WlanCloseHandle(handle, IntPtr.Zero);
        }
    }
}
'@ -Language CSharp

function Get-SavedProfiles([switch]$AllUsersOnly) {
    $wifi = Get-NetAdapter -Name $WifiAlias -ErrorAction SilentlyContinue
    if (!$wifi) { return }
    $savedNames = [CampusSavedWifi]::Get([guid]$wifi.InterfaceGuid, [bool]$AllUsersOnly)
    foreach ($profile in $WifiProfiles) {
        if ($profile -in $savedNames) { $profile }
    }
}

function Restore-WifiMetrics {
    if (!(Test-Path -LiteralPath $backup)) { return }
    $savedMetrics = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    foreach ($entry in $savedMetrics) {
        $settings = @{
            InterfaceAlias = [string]$entry.InterfaceAlias
            AddressFamily = [string]$entry.AddressFamily
            AutomaticMetric = [string]$entry.AutomaticMetric
            PolicyStore = 'ActiveStore'
        }
        if ($entry.AutomaticMetric -eq 'Disabled') { $settings.InterfaceMetric = [uint32]$entry.InterfaceMetric }
        Set-NetIPInterface @settings
    }
    Remove-Item -LiteralPath $backup
}

function Set-WifiMetric([uint32]$Metric) {
    $state = @(Get-NetIPInterface -InterfaceAlias $WifiAlias -PolicyStore ActiveStore)
    if (!(Test-Path -LiteralPath $backup)) {
        $state | Select-Object InterfaceAlias,@{n='AddressFamily';e={[string]$_.AddressFamily}},
            @{n='AutomaticMetric';e={[string]$_.AutomaticMetric}},InterfaceMetric |
            ConvertTo-Json | Set-Content -LiteralPath "$backup.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$backup.tmp" -Destination $backup
    }
    try {
        foreach ($entry in $state) {
            if ($entry.AutomaticMetric -ne 'Disabled' -or $entry.InterfaceMetric -ne $Metric) {
                $params = @{
                    InterfaceAlias = $WifiAlias; AddressFamily = $entry.AddressFamily; PolicyStore = 'ActiveStore'
                    AutomaticMetric = 'Disabled'; InterfaceMetric = $Metric
                }
                Set-NetIPInterface @params
            }
        }
    } catch {
        Restore-WifiMetrics
        throw
    }
}

if ($Mode -in 'Install','Uninstall') {
    if (!$isAdmin) { throw 'Run this installer as administrator.' }
    $existing = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    if ($Mode -eq 'Uninstall') {
        if ($existing) {
            if ($existing.State -eq 'Running') { Stop-ScheduledTask -TaskName $task }
            Unregister-ScheduledTask -TaskName $task -Confirm:$false
        }
        Restore-WifiMetrics
        $shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) "$task.lnk"
        if (Test-Path -LiteralPath $shortcut) {
            $savedLink = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
            if ($savedLink.Arguments.Contains((Join-Path $installDir 'CampusNetworkWiFiTray.ps1'))) {
                Remove-Item -LiteralPath $shortcut
            }
        }
        Write-Host 'Boot task removed. Logs and saved Wi-Fi profiles were retained.'
        return
    }

    if (!@(Get-SavedProfiles -AllUsersOnly).Count) {
        throw 'Configure an all-user Wi-Fi profile in failover.local.json and save that network in Windows.'
    }
    if ($existing.State -eq 'Running') { throw 'Uninstall the running task before reinstalling.' }
    $traySource = Join-Path $PSScriptRoot 'CampusNetworkWiFiTray.ps1'
    if (!(Test-Path -LiteralPath $traySource -PathType Leaf)) { throw 'The tray script is missing.' }
    $folder = New-Item -ItemType Directory -Path $installDir -Force
    if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected installation directory.' }
    if ($PSCommandPath -ne $installed) { Copy-Item -LiteralPath $PSCommandPath -Destination $installed -Force }
    [ordered]@{
        WiredAlias = $WiredAlias
        WifiAlias = $WifiAlias
        WifiProfiles = $WifiProfiles
        IntervalSeconds = $IntervalSeconds
        TrialIntervalMinutes = $TrialIntervalMinutes
        TrialSeconds = $TrialSeconds
    } | ConvertTo-Json | Set-Content -LiteralPath $installedConfig -Encoding UTF8
    $trayInstalled = Join-Path $installDir 'CampusNetworkWiFiTray.ps1'
    if ($traySource -ne $trayInstalled) { Copy-Item -LiteralPath $traySource -Destination $trayInstalled -Force }
    $action = New-ScheduledTaskAction -Execute $native -WorkingDirectory $installDir -Argument (
        '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}" -Mode Active' -f $installed
    )
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 3 -RestartInterval ([timespan]::FromMinutes(1))
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Campus wired internet and saved Wi-Fi failover' -Force | Out-Null
    Set-TrayStartup $trayInstalled
    New-Item -ItemType File -Path $trialRequest -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    Write-Host "Boot task started. Logs are in $installDir."
    return
}

if ($Mode -eq 'Active' -and (!$isAdmin -or $PSCommandPath -ne $installed)) {
    throw 'Active mode needs the installed Program Files copy and administrator privileges.'
}
if (!$LogPath) {
    $filename = if ($Mode -eq 'Active') { "$program.log" } else { "$program.observe.log" }
    $LogPath = Join-Path $PSScriptRoot $filename
}

function Write-Status([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'), $Message
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 2097152) {
        Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;

public static class CampusInterfaceProbe {
    private const int IpUnicastIf = 31;

    public static bool Test(string local, int index, string remote, string host, string path) {
        try {
            using (var tcp = new TcpClient(AddressFamily.InterNetwork)) {
                tcp.Client.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName) IpUnicastIf,
                    IPAddress.HostToNetworkOrder(index));
                tcp.Client.Bind(new IPEndPoint(IPAddress.Parse(local), 0));
                if (!tcp.ConnectAsync(IPAddress.Parse(remote), 443).Wait(2200)) return false;
                using (var tls = new SslStream(tcp.GetStream(), false)) {
                    if (!tls.AuthenticateAsClientAsync(host).Wait(2600)) return false;
                    tls.WriteTimeout = 2200;
                    byte[] request = Encoding.ASCII.GetBytes("GET " + path + " HTTP/1.1\r\nHost: " +
                        host + "\r\nAccept: application/dns-json\r\nConnection: close\r\n\r\n");
                    tls.Write(request, 0, request.Length);
                    byte[] header = new byte[12];
                    int total = 0;
                    DateTime deadline = DateTime.UtcNow.AddMilliseconds(2200);
                    while (total < header.Length) {
                        var read = tls.ReadAsync(header, total, header.Length - total);
                        int remaining = (int) (deadline - DateTime.UtcNow).TotalMilliseconds;
                        if (remaining <= 0 || !read.Wait(remaining) || read.Result == 0) return false;
                        total += read.Result;
                    }
                    string status = Encoding.ASCII.GetString(header);
                    return status == "HTTP/1.1 200" || status == "HTTP/1.0 200";
                }
            }
        } catch (SocketException) { return false; }
          catch (IOException) { return false; }
          catch (System.Security.Authentication.AuthenticationException) { return false; }
          catch (AggregateException) { return false; }
    }
}
'@ -Language CSharp

function Get-InterfaceState([string]$Alias) {
    $adapter = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
    if (!$adapter -or $adapter.Status -ne 'Up') {
        return [pscustomobject]@{ State = 'link-down'; InterfaceIndex = 0; IPv4 = $null }
    }
    $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' -and !$_.SkipAsSource -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    $gateway = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $state = if (!$ip) { 'no-ipv4' } elseif (!$gateway) { 'no-gateway' } else { 'ready' }
    return [pscustomobject]@{ State = $state; InterfaceIndex = $adapter.ifIndex; IPv4 = $ip.IPAddress }
}

function Test-Internet($Interface) {
    if ($Interface.State -ne 'ready') { return $false }
    if ([CampusInterfaceProbe]::Test($Interface.IPv4, $Interface.InterfaceIndex, '223.5.5.5',
        'dns.alidns.com', '/resolve?name=example.com&type=A')) { return $true }
    return [CampusInterfaceProbe]::Test($Interface.IPv4, $Interface.InterfaceIndex, '1.1.1.1',
        'one.one.one.one', '/dns-query?name=example.com&type=A')
}

function Get-ConnectedWifi {
    $wifi = Get-NetAdapter -Name $WifiAlias -ErrorAction SilentlyContinue
    if (!$wifi -or $wifi.Status -ne 'Up') { return 'disconnected' }
    $lines = & netsh.exe wlan show interfaces 2>$null
    $matchesFound = @($lines | Select-String '^\s*SSID\s*:\s*(.+?)\s*$')
    if ($matchesFound.Count -ne 1) { return 'unknown' }
    $name = $matchesFound[0].Matches[0].Groups[1].Value
    if ($name -in $WifiProfiles) { return $name }
    return 'other-network'
}

function Connect-VerifiedWifi {
    $saved = @(Get-SavedProfiles)
    if (!$saved.Count) { Write-Status 'WIFI_NO_SAVED_PROFILE'; return $null }
    $current = Get-ConnectedWifi
    if ($current -in 'unknown','other-network') { Write-Status "WIFI_BUSY state=$current"; return $null }
    Set-WifiMetric 5000
    foreach ($profile in $saved) {
        $current = Get-ConnectedWifi
        if ($current -in 'unknown','other-network') { Write-Status "WIFI_BUSY state=$current"; return $null }
        if ($current -ne $profile) {
            & netsh.exe wlan connect "name=$profile" "interface=$WifiAlias" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Status "WIFI_CONNECT_FAILED profile=$profile exit=$LASTEXITCODE"
                continue
            }
            $script:managedWifi = $profile
        }
        $deadline = [datetime]::UtcNow.AddSeconds(25)
        do {
            if ((Get-ConnectedWifi) -eq $profile -and (Test-Internet (Get-InterfaceState $WifiAlias))) {
                Write-Status "WIFI_INTERNET_OK profile=$profile"
                return $profile
            }
            Start-Sleep -Seconds 2
        } while ([datetime]::UtcNow -lt $deadline)
        Write-Status "WIFI_INTERNET_FAILED profile=$profile"
    }
    return $null
}

function Stop-ManagedWifi {
    if ($script:managedWifi -and (Get-ConnectedWifi) -eq $script:managedWifi) {
        & netsh.exe wlan disconnect "interface=$WifiAlias" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Status "WIFI_DISCONNECT_FAILED exit=$LASTEXITCODE"; return $false }
    }
    $script:managedWifi = $null
    Restore-WifiMetrics
    return $true
}

function Test-DefaultIPv4([string]$Alias) {
    $route = Find-NetRoute -RemoteIPAddress '223.5.5.5' -ErrorAction SilentlyContinue |
        Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
    $adapter = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
    return [bool]($route -and $adapter -and $route.InterfaceIndex -eq $adapter.ifIndex)
}

function Prefer-Wifi {
    Set-WifiMetric 5
    Write-Status "FALLBACK wifi_default_ipv4=$(Test-DefaultIPv4 $WifiAlias)"
}

$script:managedWifi = $null
$phase = 'wired'
$healthy = 0
$unhealthy = 0
$wifiMisses = 0
$nextTrial = [datetime]::UtcNow.AddMinutes($TrialIntervalMinutes)
$nextAttempt = [datetime]::MinValue
$lastState = ''
$lastHeartbeat = [datetime]::MinValue
$lock = $null
if ($Mode -eq 'Active') {
    $lock = [IO.File]::Open((Join-Path $installDir 'runner.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
}

try {
    if ($lock) {
        Restore-WifiMetrics
        if (Test-Path -LiteralPath $trialRequest) {
            $nextTrial = [datetime]::MinValue
            Remove-Item -LiteralPath $trialRequest
        }
    }
    $saved = @(Get-SavedProfiles)
    Write-Status "START mode=$Mode saved_profiles=$($saved.Count) interval_seconds=$IntervalSeconds"
    do {
        $now = [datetime]::UtcNow
        $wired = Get-InterfaceState $WiredAlias
        $online = Test-Internet $wired
        $wifiState = Get-ConnectedWifi
        $summary = "wired=$($wired.State) wired_https=$online wifi=$wifiState phase=$phase"
        if ($summary -ne $lastState -or ($now - $lastHeartbeat).TotalMinutes -ge 5) {
            Write-Status "CHECK $summary"
            $lastState = $summary
            $lastHeartbeat = $now
        }
        if ($Mode -eq 'Check') { break }

        if ($Mode -eq 'Active') {
            if ($online) { $healthy++; $unhealthy = 0 } else { $unhealthy++; $healthy = 0 }

            if ($phase -eq 'trial' -and $unhealthy -ge 2) {
                if (Test-Internet (Get-InterfaceState $WifiAlias)) {
                    Prefer-Wifi
                    $phase = 'fallback'
                } else {
                    $phase = 'wired'
                    $nextAttempt = $now
                }
            }

            if ($phase -eq 'fallback') {
                if ($healthy -ge 3 -and (Stop-ManagedWifi)) {
                    Write-Status 'WIRED_RESTORED fallback_disconnected'
                    $phase = 'wired'
                    $nextTrial = $now.AddMinutes($TrialIntervalMinutes)
                } elseif ($wifiState -ne $script:managedWifi -or !(Test-Internet (Get-InterfaceState $WifiAlias))) {
                    $wifiMisses++
                    if ($wifiMisses -ge 2) { $phase = 'wired'; $nextAttempt = $now }
                } else {
                    $wifiMisses = 0
                }
            }

            if ($phase -eq 'trial' -and $now -ge $trialEnd -and $healthy -ge 3 -and (Stop-ManagedWifi)) {
                Write-Status 'TRIAL_END wired_online'
                $phase = 'wired'
            }

            if ($phase -eq 'wired' -and $unhealthy -ge 2 -and $now -ge $nextAttempt) {
                $profile = Connect-VerifiedWifi
                if ($profile) {
                    $script:managedWifi = $profile
                    Prefer-Wifi
                    $wifiMisses = 0
                    $phase = 'fallback'
                } else {
                    Restore-WifiMetrics
                    $nextAttempt = [datetime]::UtcNow.AddMinutes(2)
                }
            } elseif ($phase -eq 'wired' -and $healthy -ge 3 -and $now -ge $nextTrial) {
                $nextTrial = $now.AddMinutes($TrialIntervalMinutes)
                if ($wifiState -eq 'disconnected') {
                    $profile = Connect-VerifiedWifi
                    if ($profile) {
                        $trialEnd = [datetime]::UtcNow.AddSeconds($TrialSeconds)
                        $phase = 'trial'
                        Write-Status "TRIAL_START duration_seconds=$TrialSeconds wired_default_ipv4=$(Test-DefaultIPv4 $WiredAlias)"
                        if (!(Test-DefaultIPv4 $WiredAlias) -and (Test-Internet (Get-InterfaceState $WiredAlias))) {
                            if (Stop-ManagedWifi) {
                                $phase = 'wired'
                                Write-Status 'TRIAL_END wired_default_route_changed'
                            }
                        }
                    } elseif (Test-Internet (Get-InterfaceState $WiredAlias)) {
                        [void](Stop-ManagedWifi)
                    } else {
                        Restore-WifiMetrics
                    }
                }
            }
        }

        if ((Get-Date) -ge $Until) { break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $Until)
} catch {
    Write-Status "ERROR type=$($_.Exception.GetType().Name) id=$($_.FullyQualifiedErrorId)"
    throw
} finally {
    if ($lock) {
        try { Restore-WifiMetrics } finally { $lock.Dispose() }
    }
    Write-Status "END mode=$Mode"
}
