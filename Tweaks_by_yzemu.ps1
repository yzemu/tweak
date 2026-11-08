# Tweaks by yzemu - safe Windows 10/11 tweaker (PowerShell 5.1 + WPF)
# Every tweak is reversible. A restore point is created before changes are applied.

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

try {

# ---------- Backup storage ----------
$DataDir = Join-Path $env:ProgramData 'TweaksByYzemu'
$BackupFile = Join-Path $DataDir 'backup.xml'
$LangFile = Join-Path $DataDir 'lang.txt'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$script:Backup = @{}
if (Test-Path $BackupFile) { try { $script:Backup = Import-Clixml $BackupFile } catch {} }
if ($script:Backup -isnot [hashtable]) { $script:Backup = @{} }
$script:RPDone = $false
$script:Lang = $(if ((Get-Culture).TwoLetterISOLanguageName -eq 'ru') { 'ru' } else { 'en' })
if (Test-Path $LangFile) { try { $l = (Get-Content $LangFile -Raw).Trim(); if ($l -in 'en', 'ru') { $script:Lang = $l } } catch {} }
$script:Build = 0
try { $script:Build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber } catch {}
function Save-Backup { $script:Backup | Export-Clixml -Path $BackupFile }

# ---------- Registry tweaks with automatic rollback ----------
function Restore-RegItem($s) {
    if ($s.Existed) { New-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -PropertyType $s.Type -Force | Out-Null }
    else { Remove-ItemProperty -Path $s.Path -Name $s.Name -ErrorAction SilentlyContinue }
}
function Set-RegTweak($id, $items) {
    $saved = @()
    try {
        foreach ($i in $items) {
            if (-not (Test-Path $i.Path)) { New-Item -Path $i.Path -Force | Out-Null }
            $old = Get-ItemProperty -Path $i.Path -Name $i.Name -ErrorAction SilentlyContinue
            $saved += @{ Path = $i.Path; Name = $i.Name; Existed = ($null -ne $old); Value = $(if ($old) { $old.($i.Name) }); Type = $i.Type }
            New-ItemProperty -Path $i.Path -Name $i.Name -Value $i.Value -PropertyType $i.Type -Force | Out-Null
        }
    } catch {
        foreach ($s in $saved) { Restore-RegItem $s }
        throw
    }
    $script:Backup[$id] = $saved
}
function Undo-RegTweak($id) {
    if (-not $script:Backup.ContainsKey($id)) { return }
    foreach ($s in $script:Backup[$id]) { Restore-RegItem $s }
}
function Invoke-Apply($t) { if ($t.Reg) { Set-RegTweak $t.Id $t.Reg } else { & $t.Apply $t } }
function Invoke-Undo($t) { if ($t.Reg) { Undo-RegTweak $t.Id } else { & $t.Revert $t }; $script:Backup.Remove($t.Id) }

# ---------- Tweak constructors ----------
$GuidRx = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
function Rg($p, $n, $v, $t = 'DWord') { @{ Path = $p; Name = $n; Value = $v; Type = $t } }
function Tw($id, $page, $title, $desc, $reg, [bool]$reboot = $false, [int]$min = 0) { @{ Id = $id; Page = $page; Title = $title; Desc = $desc; Reg = $reg; Reboot = $reboot; Min = $min } }

# Power plan setting (AC). The previous value is stored for rollback.
$PowerApply = { param($t)
    $cur = powercfg /getactivescheme | Out-String
    if ($cur -notmatch "($GuidRx)") { throw 'Could not detect the active power plan' }
    $g = $Matches[1]
    $m = [regex]::Matches((powercfg /query $g $t.Sub $t.Setting | Out-String), '0x[0-9a-fA-F]{8}')
    if ($m.Count -lt 2) { throw 'This setting is not available in the current power plan' }
    $old = [Convert]::ToInt32($m[$m.Count - 2].Value.Substring(2), 16)
    powercfg /setacvalueindex $g $t.Sub $t.Setting $t.Value | Out-Null
    powercfg /setactive $g | Out-Null
    $script:Backup[$t.Id] = @{ Scheme = $g; Old = $old }
}
$PowerRevert = { param($t)
    $b = $script:Backup[$t.Id]
    powercfg /setacvalueindex $b.Scheme $t.Sub $t.Setting $b.Old | Out-Null
    powercfg /setactive $b.Scheme | Out-Null
}
function Pw($id, $title, $desc, $sub, $setting, $value) { @{ Id = $id; Page = 'power'; Title = $title; Desc = $desc; Sub = $sub; Setting = $setting; Value = $value; Apply = $PowerApply; Revert = $PowerRevert } }

# Services: disable and remember the previous startup mode.
$SvcRevert = { param($t)
    foreach ($s in $script:Backup[$t.Id]) {
        $mode = switch ($s.Mode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } default { 'Disabled' } }
        Set-Service -Name $s.Name -StartupType $mode -ErrorAction SilentlyContinue
        if ($s.Running) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
    }
}
$SvcApply = { param($t)
    $saved = @()
    try {
        foreach ($n in $t.Svc) {
            $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
            if (-not $s) { continue }
            $saved += @{ Name = $n; Mode = $s.StartMode; Running = ($s.State -eq 'Running') }
            Set-Service -Name $n -StartupType Disabled -ErrorAction Stop
            if ($s.State -eq 'Running') { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        $script:Backup[$t.Id] = $saved; & $SvcRevert $t; $script:Backup.Remove($t.Id)
        throw
    }
    $script:Backup[$t.Id] = $saved
}
function New-SvcTweak($id, $page, $title, $desc, $svc) { @{ Id = $id; Page = $page; Title = $title; Desc = $desc; Svc = $svc; Apply = $SvcApply; Revert = $SvcRevert } }

# Scheduled tasks: re-enable only what we disabled.
$TaskApply = { param($t)
    $saved = @()
    foreach ($x in $t.Tasks) {
        $task = Get-ScheduledTask -TaskPath $x.Path -TaskName $x.Name -ErrorAction SilentlyContinue
        if ($task -and $task.State -ne 'Disabled') {
            Disable-ScheduledTask -TaskPath $x.Path -TaskName $x.Name -ErrorAction SilentlyContinue | Out-Null
            $saved += $x
        }
    }
    $script:Backup[$t.Id] = $saved
}
$TaskRevert = { param($t)
    foreach ($x in $script:Backup[$t.Id]) { Enable-ScheduledTask -TaskPath $x.Path -TaskName $x.Name -ErrorAction SilentlyContinue | Out-Null }
}

$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$cdmRegs = @('SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
    'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'SilentInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled') | ForEach-Object { Rg $cdm $_ 0 }
$expl = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$pers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$dcPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$sysPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$clsid = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'

$script:Tweaks = @(
    # ===== Performance =====
    (Tw 'gamemode' 'perf' 'Windows Game Mode' 'Gives the running game priority and holds back background tasks.' @((Rg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1), (Rg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1)))
    (Tw 'gamedvr' 'perf' 'Disable Game DVR background recording' 'Stops Xbox Game Bar clip capture. Less CPU and GPU overhead while gaming.' @((Rg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0), (Rg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0)))
    (Tw 'hags' 'perf' 'Hardware-accelerated GPU scheduling' 'The graphics card manages its own task queue and memory. Usually helpful on modern GPUs.' @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2)) $true)
    (Tw 'mmcss' 'perf' 'More CPU time for games' 'Lowers the share of CPU reserved for background multimedia tasks (from 20% to 10%).' @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10)))
    (Tw 'mouseaccel' 'perf' 'Disable mouse acceleration' 'Turns off "Enhance pointer precision" for predictable aim in shooters.' @((Rg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'), (Rg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'), (Rg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String')) $true)
    (Tw 'stickykeys' 'perf' 'Disable Sticky Keys popup' 'No more popup after pressing Shift five times in the middle of a game.' @((Rg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'), (Rg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'), (Rg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String')))
    (Tw 'startdelay' 'perf' 'Remove startup delay' 'Startup apps launch right after sign-in without the built-in pause.' @((Rg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0)))
    (Tw 'visfx' 'perf' 'Disable transparency and window animations' 'Lighter interface, especially on older PCs. Looks stricter.' @((Rg $pers 'EnableTransparency' 0), (Rg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String')))

    # ===== Power =====
    (Pw 'cpumin' 'CPU always at full speed' 'Minimum processor state 100% on AC power: no dips under sudden load. Runs hotter and louder.' 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' 100)
    (Pw 'coreparking' 'Disable core parking' 'All CPU cores stay active, fewer latency spikes in games.' 'SUB_PROCESSOR' 'CPMINCORES' 100)
    (Pw 'aspm' 'Disable PCIe power saving (ASPM)' 'GPU and NVMe never sleep between tasks. Fewer micro-stutters, slightly higher power draw.' 'SUB_PCIEXPRESS' 'ASPM' 0)
    @{ Id = 'hibernate'; Page = 'power'; Title = 'Disable hibernation'
       Desc = 'Deletes hiberfil.sys and frees several GB of disk space. Also disables Fast Startup.'
       Apply = {
           $old = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
           powercfg /hibernate off | Out-Null
           $script:Backup['hibernate'] = @{ Old = $old }
       }
       Revert = { if ($script:Backup['hibernate'].Old -ne 0) { powercfg /hibernate on | Out-Null } } }

    # ===== Privacy =====
    (Tw 'telemetry' 'privacy' 'Minimal Windows telemetry' 'Sets diagnostic data to the minimum and disables feedback prompts. On Home/Pro this equals "Basic".' @((Rg $dcPol 'AllowTelemetry' 0), (Rg $dcPol 'DoNotShowFeedbackNotifications' 1)))
    (New-SvcTweak 'diagsvc' 'privacy' 'Disable telemetry services' 'Stops DiagTrack (Connected User Experiences) and dmwappushservice.' @('DiagTrack', 'dmwappushservice'))
    @{ Id = 'telemtasks'; Page = 'privacy'; Title = 'Disable data collection tasks'
       Desc = 'Disables Compatibility Appraiser, CEIP and disk diagnostics scheduled tasks.'
       Tasks = @(@{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
                 @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
                 @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
                 @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
                 @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' })
       Apply = $TaskApply; Revert = $TaskRevert }
    (Tw 'adid' 'privacy' 'Disable advertising ID' 'Apps no longer get a personal advertising identifier.' @((Rg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0)))
    (Tw 'tailored' 'privacy' 'Disable tailored experiences' 'Windows stops using diagnostic data to pick tips and ads.' @((Rg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0)))
    (Tw 'activity' 'privacy' 'Disable activity history' 'Windows no longer collects or uploads your activity log (Timeline).' @((Rg $sysPol 'EnableActivityFeed' 0), (Rg $sysPol 'PublishUserActivities' 0), (Rg $sysPol 'UploadUserActivities' 0)))
    (Tw 'location' 'privacy' 'Deny location access' 'Location services are off for all apps. Maps and weather will ask for a city.' @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String')))
    (Tw 'feedback' 'privacy' 'Disable feedback requests' 'Windows stops asking "how is Windows doing".' @((Rg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0)))
    (Tw 'errorrep' 'privacy' 'Disable error reporting' 'Crash reports are no longer sent to Microsoft.' @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1)))
    (Tw 'consumer' 'privacy' 'Block promoted app auto-install' 'Windows stops adding promoted games and apps to the Start menu.' @((Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1), (Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1)))
    (Tw 'suggest' 'privacy' 'Remove suggestions and ads' 'No tips in Settings, on the lock screen or in the Start menu.' $cdmRegs)
    (Tw 'bing' 'privacy' 'Disable Bing in Start search' 'Search looks only on this PC, with no web queries.' @((Rg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0), (Rg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1)))
    (Tw 'copilot' 'privacy' 'Disable Copilot' 'Removes the Windows Copilot AI assistant.' @((Rg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1)))
    (Tw 'recall' 'privacy' 'Disable Recall (Windows 11)' 'Blocks AI screen snapshots and analysis of your activity.' @((Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1)) $false 22000)

    # ===== System =====
    (Tw 'darktheme' 'system' 'Windows dark theme' 'Dark appearance for the system and apps.' @((Rg $pers 'AppsUseLightTheme' 0), (Rg $pers 'SystemUsesLightTheme' 0)))
    (Tw 'fileext' 'system' 'Show file extensions' 'Shows .exe, .txt and so on. Protects against fakes like "photo.jpg.exe".' @((Rg $expl 'HideFileExt' 0)))
    (Tw 'hidden' 'system' 'Show hidden files' 'Hidden files and folders become visible in Explorer.' @((Rg $expl 'Hidden' 1)))
    (Tw 'thispc' 'system' 'Open Explorer on "This PC"' 'Instead of Home / Quick access.' @((Rg $expl 'LaunchTo' 1)))
    (Tw 'widgets' 'system' 'Disable widgets and news' 'Removes the widgets and news panel from the taskbar.' @((Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0)))
    (Tw 'cortana' 'system' 'Disable Cortana' 'Turns off the voice assistant.' @((Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0)))
    (Tw 'faststart' 'system' 'Disable Fast Startup' 'Shutdown becomes a full shutdown. Fixes odd behavior and driver issues after "shutting down".' @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0)))
    @{ Id = 'classicmenu'; Page = 'system'; Title = 'Classic context menu (Windows 11)'; Min = 22000
       Desc = 'Right-click shows the full menu right away, no "Show more options". Explorer restarts briefly.'
       Apply = {
           New-Item -Path "$clsid\InprocServer32" -Force | Out-Null
           Set-ItemProperty -Path "$clsid\InprocServer32" -Name '(default)' -Value ''
           $script:Backup['classicmenu'] = @{ On = $true }
           Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
       }
       Revert = {
           Remove-Item -Path $clsid -Recurse -Force -ErrorAction SilentlyContinue
           Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
       } }

    # ===== Updates =====
    (Tw 'deferfeat' 'updates' 'Defer feature updates by one year' 'Big feature updates arrive after 365 days. Security patches come as usual.' @((Rg $wuPol 'DeferFeatureUpdates' 1), (Rg $wuPol 'DeferFeatureUpdatesPeriodInDays' 365)))
    (Tw 'nodrivers' 'updates' 'No drivers via Windows Update' 'Your GPU driver will not be replaced with an older one behind your back.' @((Rg $wuPol 'ExcludeWUDriversInQualityUpdate' 1)))
    (Tw 'noreboot' 'updates' 'No automatic restart after updates' 'No forced restart while you are signed in.' @((Rg "$wuPol\AU" 'NoAutoRebootWithLoggedOnUsers' 1)))
    (Tw 'nodo' 'updates' 'Stop sharing updates with other PCs' 'Delivery Optimization will not use your internet to upload update files.' @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0)))

    # ===== Disk & SSD =====
    @{ Id = 'trim'; Page = 'disk'; Title = 'Make sure TRIM is enabled'
       Desc = 'TRIM helps an SSD keep its write speed. Usually already on; this guarantees it.'
       Apply = {
           $o = fsutil behavior query DisableDeleteNotify | Out-String
           $old = if ($o -match '=\s*(\d)') { $Matches[1] } else { '0' }
           fsutil behavior set DisableDeleteNotify 0 | Out-Null
           $script:Backup['trim'] = @{ Old = $old }
       }
       Revert = { fsutil behavior set DisableDeleteNotify $script:Backup['trim'].Old | Out-Null } }
    @{ Id = 'lastaccess'; Page = 'disk'; Title = 'Stop writing last-access time'
       Desc = 'Fewer needless disk writes every time a file is opened. Extends SSD life.'
       Apply = {
           $o = fsutil behavior query disablelastaccess | Out-String
           $old = if ($o -match '=\s*(\d)') { $Matches[1] } else { '2' }
           fsutil behavior set disablelastaccess 1 | Out-Null
           $script:Backup['lastaccess'] = @{ Old = $old }
       }
       Revert = { fsutil behavior set disablelastaccess $script:Backup['lastaccess'].Old | Out-Null } }
    (New-SvcTweak 'sysmain' 'disk' 'Disable SysMain (Superfetch)' 'Preloads apps into memory. Nearly useless on SSD. Keep it enabled on HDD.' @('SysMain'))
)

# ---------- Presets ----------
$script:Presets = @{
    gaming  = @('gamemode', 'gamedvr', 'mmcss', 'mouseaccel', 'stickykeys', 'startdelay')
    privacy = @('telemetry', 'adid', 'tailored', 'activity', 'feedback', 'consumer', 'suggest', 'bing')
}

# ---------- Apps (installed through winget) ----------
$script:Apps = @(
    @{ Id = 'Google.Chrome'; Title = 'Google Chrome'; Desc = 'Web browser' }
    @{ Id = 'Mozilla.Firefox'; Title = 'Mozilla Firefox'; Desc = 'Web browser' }
    @{ Id = 'Brave.Brave'; Title = 'Brave'; Desc = 'Browser with built-in ad blocking' }
    @{ Id = '7zip.7zip'; Title = '7-Zip'; Desc = 'File archiver' }
    @{ Id = 'VideoLAN.VLC'; Title = 'VLC'; Desc = 'Media player that opens almost anything' }
    @{ Id = 'Discord.Discord'; Title = 'Discord'; Desc = 'Voice and text chat' }
    @{ Id = 'Valve.Steam'; Title = 'Steam'; Desc = 'Game store and library' }
    @{ Id = 'Telegram.TelegramDesktop'; Title = 'Telegram'; Desc = 'Messenger' }
    @{ Id = 'OBSProject.OBSStudio'; Title = 'OBS Studio'; Desc = 'Recording and streaming' }
    @{ Id = 'qBittorrent.qBittorrent'; Title = 'qBittorrent'; Desc = 'Ad-free torrent client' }
    @{ Id = 'Notepad++.Notepad++'; Title = 'Notepad++'; Desc = 'Handy text editor' }
    @{ Id = 'Microsoft.VisualStudioCode'; Title = 'VS Code'; Desc = 'Code editor' }
    @{ Id = 'Python.Python.3.12'; Title = 'Python 3.12'; Desc = 'Programming language' }
    @{ Id = 'Git.Git'; Title = 'Git'; Desc = 'Version control' }
    @{ Id = 'REALiX.HWiNFO'; Title = 'HWiNFO'; Desc = 'Temperatures, clocks and hardware sensors' }
    @{ Id = 'CPUID.CPU-Z'; Title = 'CPU-Z'; Desc = 'CPU, RAM and motherboard info' }
    @{ Id = 'Guru3D.Afterburner'; Title = 'MSI Afterburner'; Desc = 'GPU monitoring and tuning' }
    @{ Id = 'voidtools.Everything'; Title = 'Everything'; Desc = 'Instant file search' }
    @{ Id = 'Microsoft.PowerToys'; Title = 'PowerToys'; Desc = 'Handy Windows utilities' }
    @{ Id = 'ShareX.ShareX'; Title = 'ShareX'; Desc = 'Screenshots and screen recording' }
    @{ Id = 'Spotify.Spotify'; Title = 'Spotify'; Desc = 'Music' }
)

# ---------- Background jobs (no console windows) ----------
$script:Queue = New-Object System.Collections.Queue
$script:Cur = $null
$script:JobTotal = 0; $script:JobDone = 0; $script:JobFail = @()
$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(600)
$script:Timer.Add_Tick({
    if ($script:Cur) {
        if (-not $script:Cur.Proc.HasExited) { return }
        $code = $script:Cur.Proc.ExitCode
        if ($script:Cur.Ok -notcontains $code) { $script:JobFail += $script:Cur.Label }
        $script:JobDone++
        $script:Cur = $null
    }
    if ($script:Queue.Count -gt 0) {
        $j = $script:Queue.Dequeue()
        Set-Status ("[{0}/{1}] {2}..." -f ($script:JobDone + 1), $script:JobTotal, $j.Label)
        try {
            $p = Start-Process -FilePath $j.File -ArgumentList $j.Args -WindowStyle Hidden -PassThru
            $null = $p.Handle
            $j.Proc = $p; $script:Cur = $j
        } catch { $script:JobFail += $j.Label; $script:JobDone++ }
    } else {
        $script:Timer.Stop()
        $script:BusyBar.Visibility = 'Collapsed'
        $ok = $script:JobTotal - $script:JobFail.Count
        if ($script:JobFail.Count) { Set-Status ("Finished: $ok OK, failed: " + ($script:JobFail -join ', ')) }
        else { Set-Status "Finished: all $ok task(s) completed." }
        $script:JobTotal = 0; $script:JobDone = 0; $script:JobFail = @()
    }
})
function Enqueue-Job($label, $file, $arg, [int[]]$ok = @(0)) {
    $script:Queue.Enqueue(@{ Label = $label; File = $file; Args = $arg; Ok = $ok; Proc = $null })
    $script:JobTotal++
    $script:BusyBar.Visibility = 'Visible'
    if (-not $script:Timer.IsEnabled) { $script:Timer.Start() }
}
$WingetOk = @(0, -1978335189, -1978335135)   # success / no update needed / already installed
$WingetFlags = '--silent --accept-source-agreements --accept-package-agreements --disable-interactivity'
function Test-Winget { if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget not found. Install "App Installer" from the Microsoft Store.' } }

# ---------- Actions ----------
function Get-DirSize($p) { [long](Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum }
function Set-Dns($servers) {
    foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })) {
        if ($servers) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers }
        else { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses }
    }
    Clear-DnsClientCache
}
function Set-Scheme($guid, $name) {
    powercfg /setactive $guid 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Plan is hidden or missing: reuse our earlier copy, or create it once.
        $found = $null
        foreach ($line in (powercfg /list)) {
            if ($line -match "($GuidRx)\s+\((.+?)\)" -and $Matches[2] -eq $name) { $found = $Matches[1]; break }
        }
        if (-not $found) {
            $dup = powercfg /duplicatescheme $guid | Out-String
            if ($dup -match "($GuidRx)") { $found = $Matches[1]; powercfg /changename $found $name | Out-Null }
        }
        if (-not $found) { throw "The '$name' plan is not available on this PC" }
        powercfg /setactive $found | Out-Null
    }
    "Power plan enabled: $name."
}
function Ensure-RestorePoint {
    if ($script:RPDone) { return }
    Set-Status 'Creating a restore point...'
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        New-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description 'Tweaks by yzemu' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    } catch { Set-Status 'Restore point was not created. Built-in rollback still works.' }
    finally {
        if ($null -ne $old) { New-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -Value $old -PropertyType DWord -Force | Out-Null }
        else { Remove-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
    }
    $script:RPDone = $true
}
function Invoke-Preset($key) {
    $todo = @($script:Tweaks | Where-Object { $script:Presets[$key] -contains $_.Id -and -not $script:Backup.ContainsKey($_.Id) })
    if (-not $todo.Count) { return 'All tweaks from this preset are already applied.' }
    Ensure-RestorePoint
    $n = 0; $err = @()
    foreach ($t in $todo) { try { Invoke-Apply $t; $n++ } catch { $err += $t.Title } }
    Save-Backup
    $m = "Preset applied: $n tweak(s)."
    if ($err.Count) { $m += ' Failed: ' + ($err -join ', ') + '.' }
    $m
}
$script:Actions = @{
    perf = @(
        @{ Top = $true; Title = 'Gaming preset'; Desc = 'One click: Game Mode, no Game DVR, more CPU for games, no mouse acceleration, no Sticky Keys popup, no startup delay.'; Label = 'Apply preset'; Run = { Invoke-Preset 'gaming' } }
    )
    privacy = @(
        @{ Top = $true; Title = 'Privacy preset'; Desc = 'One click: minimal telemetry, no advertising ID, no tailored ads, no activity history, no suggestions, no Bing in search.'; Label = 'Apply preset'; Run = { Invoke-Preset 'privacy' } }
    )
    power = @(
        @{ Title = 'Balanced'; Desc = 'Default Windows plan.'; Label = 'Enable'; Run = { Set-Scheme '381b4222-f694-41f0-9685-ff5bb260df2e' 'Balanced' } }
        @{ Title = 'High performance'; Desc = 'CPU drops its clocks less often.'; Label = 'Enable'; Run = { Set-Scheme '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 'High performance' } }
        @{ Title = 'Ultimate Performance'; Desc = 'Hidden desktop plan with zero power-saving latency. Created on first use.'; Label = 'Enable'; Run = { Set-Scheme 'e9a42b02-d5df-448d-aa00-03f14749eb61' 'Ultimate Performance' } }
        @{ Title = 'Power saver'; Desc = 'For laptops on battery.'; Label = 'Enable'; Run = { Set-Scheme 'a1841308-3541-4fab-bc81-f71556f20b4a' 'Power saver' } }
    )
    network = @(
        @{ Title = 'Cloudflare DNS (1.1.1.1)'; Desc = 'Fast DNS with a focus on privacy.'; Label = 'Apply'; Run = { Set-Dns @('1.1.1.1', '1.0.0.1'); 'Cloudflare DNS set.' } }
        @{ Title = 'Google DNS (8.8.8.8)'; Desc = 'Stable and fast.'; Label = 'Apply'; Run = { Set-Dns @('8.8.8.8', '8.8.4.4'); 'Google DNS set.' } }
        @{ Title = 'Quad9 DNS (9.9.9.9)'; Desc = 'Blocks malicious domains.'; Label = 'Apply'; Run = { Set-Dns @('9.9.9.9', '149.112.112.112'); 'Quad9 DNS set.' } }
        @{ Title = 'ISP DNS (default)'; Desc = 'Restore automatic DNS settings.'; Label = 'Restore'; Run = { Set-Dns $null; 'DNS restored to automatic.' } }
        @{ Title = 'Flush DNS cache'; Desc = 'Helps when sites will not open or open at an old address.'; Label = 'Flush'; Run = { Clear-DnsClientCache; 'DNS cache flushed.' } }
    )
    disk = @(
        @{ Title = 'Run TRIM on drive C:'; Desc = 'One-time SSD optimization. Safe.'; Label = 'Run'; Run = { Optimize-Volume -DriveLetter $env:SystemDrive.Substring(0, 1) -ReTrim -ErrorAction Stop; 'TRIM completed.' } }
    )
    clean = @(
        @{ Title = 'Temporary files'; Desc = 'User and Windows Temp folders. Files in use are skipped.'; Label = 'Clean'
           Run = {
               $paths = @($env:TEMP, "$env:windir\Temp")
               $before = 0; foreach ($p in $paths) { $before += Get-DirSize $p }
               foreach ($p in $paths) { Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
               $after = 0; foreach ($p in $paths) { $after += Get-DirSize $p }
               'Freed {0:N0} MB.' -f (($before - $after) / 1MB)
           } }
        @{ Title = 'Recycle Bin'; Desc = 'Empties the Recycle Bin on all drives.'; Label = 'Clean'; Run = { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; 'Recycle Bin emptied.' } }
        @{ Title = 'Thumbnail cache'; Desc = 'Thumbnails are rebuilt automatically.'; Label = 'Clean'; Run = { Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue; 'Thumbnail cache cleared.' } }
        @{ Title = 'Error reports and dumps'; Desc = 'WER files, minidumps and MEMORY.DMP.'; Label = 'Clean'
           Run = {
               foreach ($p in "$env:ProgramData\Microsoft\Windows\WER", "$env:windir\Minidump") { Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
               Remove-Item "$env:windir\MEMORY.DMP" -Force -ErrorAction SilentlyContinue
               'Reports and dumps removed.'
           } }
        @{ Title = 'Delivery Optimization cache'; Desc = 'Update files kept for sharing with other PCs.'; Label = 'Clean'; Run = { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; 'Cache cleared.' } }
        @{ Title = 'Component store cleanup (WinSxS)'; Desc = 'Removes old Windows component versions. Runs in the background and takes a few minutes.'; Label = 'Run'
           Run = { Enqueue-Job 'Component store cleanup' 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup' @(0, 3010); 'Started in the background.' } }
    )
    fix = @(
        @{ Title = 'System File Checker (SFC)'; Desc = 'Scans and repairs corrupted Windows files. Runs in the background.'; Label = 'Run'
           Run = { Enqueue-Job 'System File Checker' 'sfc.exe' '/scannow'; 'Started in the background.' } }
        @{ Title = 'Repair Windows image (DISM)'; Desc = 'DISM RestoreHealth repairs the component store. Needs internet and takes a while.'; Label = 'Run'
           Run = { Enqueue-Job 'DISM RestoreHealth' 'dism.exe' '/Online /Cleanup-Image /RestoreHealth' @(0, 3010); 'Started in the background.' } }
        @{ Title = 'Reset Windows Update'; Desc = 'Clears the update cache and restarts services. Helps when updates get stuck.'; Label = 'Reset'
           Run = {
               $svcs = 'wuauserv', 'bits', 'cryptSvc', 'msiserver'
               foreach ($s in $svcs) { Stop-Service $s -Force -ErrorAction SilentlyContinue }
               foreach ($p in "$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2") {
                   if (Test-Path "$p.old") { Remove-Item "$p.old" -Recurse -Force -ErrorAction SilentlyContinue }
                   if (Test-Path $p) { Rename-Item $p ((Split-Path $p -Leaf) + '.old') -ErrorAction SilentlyContinue }
               }
               foreach ($s in $svcs) { Start-Service $s -ErrorAction SilentlyContinue }
               'Windows Update components reset.'
           } }
        @{ Title = 'Reset network stack'; Desc = 'Winsock and IP reset. Fixes "connected, no internet". Restart required afterwards.'; Label = 'Reset'; Run = { netsh winsock reset | Out-Null; netsh int ip reset | Out-Null; 'Done. Restart your PC.' } }
        @{ Title = 'Restart Explorer'; Desc = 'Reloads the taskbar and desktop if they freeze or glitch.'; Label = 'Restart'; Run = { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; 'Explorer restarted.' } }
    )
    install = @(
        @{ Title = 'Update all programs'; Desc = 'Runs winget upgrade --all silently in the background.'; Label = 'Update'
           Run = { Test-Winget; Enqueue-Job 'Updating programs' 'cmd.exe' "/c winget upgrade --all $WingetFlags" $WingetOk; 'Update started in the background.' } }
    )
    revert = @(
        @{ Title = 'Create a restore point'; Desc = 'System snapshot in case you want to go back.'; Label = 'Create'; Run = { $script:RPDone = $false; Ensure-RestorePoint; 'Done.' } }
        @{ Title = 'Revert all changes'; Desc = 'Returns everything applied by Tweaks by yzemu to its original values.'; Label = 'Revert'
           Run = {
               $n = 0
               foreach ($id in @($script:Backup.Keys)) {
                   $t = $script:Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
                   if ($t) { try { Invoke-Undo $t; $n++ } catch {} }
               }
               Save-Backup
               "Reverted $n tweak(s). Some changes apply after a restart."
           } }
    )
}
$script:Meta = @{
    perf    = @{ Title = 'Performance'; Sub = 'Gaming tweaks for CPU, scheduler, mouse and graphics. Every one is reversible.' }
    power   = @{ Title = 'Power'; Sub = 'Power plans and fine CPU tuning. Settings apply to the active plan on AC power.' }
    privacy = @{ Title = 'Telemetry & Privacy'; Sub = 'Less tracking and fewer ads in Windows. Everything can be rolled back.' }
    system  = @{ Title = 'System'; Sub = 'Appearance, Explorer and convenience.' }
    network = @{ Title = 'Network'; Sub = 'Switch DNS for all active connections and flush the cache.' }
    updates = @{ Title = 'Updates'; Sub = 'Control updates without turning off protection. Disabling updates entirely is unsafe, so there is no such option.' }
    disk    = @{ Title = 'Disk & SSD'; Sub = 'Fewer needless writes and better SSD upkeep.' }
    clean   = @{ Title = 'Cleanup'; Sub = 'Temporary data only. These actions cannot be undone.' }
    fix     = @{ Title = 'Repair'; Sub = 'Windows recovery tools. Long tasks run in the background, no console windows.' }
    install = @{ Title = 'Apps'; Sub = 'Tick what you need and press Install. Uses the official winget, silent and in the background.' }
    revert  = @{ Title = 'Rollback'; Sub = 'Return the system to how it was before the tweaks.' }
    search  = @{ Title = 'Search'; Sub = '' }
}
$script:NavList = @(
    @{ Key = 'perf'; Icon = [string][char]0x26A1; Label = 'Performance' }, @{ Key = 'power'; Icon = [string][char]0x25C8; Label = 'Power' }
    @{ Key = 'privacy'; Icon = [string][char]0x25C9; Label = 'Privacy' }, @{ Key = 'system'; Icon = [string][char]0x2699; Label = 'System' }
    @{ Key = 'network'; Icon = [string][char]0x21C4; Label = 'Network' }, @{ Key = 'updates'; Icon = [string][char]0x27F3; Label = 'Updates' }
    @{ Key = 'disk'; Icon = [string][char]0x25A3; Label = 'Disk & SSD' }, @{ Key = 'clean'; Icon = [string][char]0x2726; Label = 'Cleanup' }
    @{ Key = 'fix'; Icon = [string][char]0x271A; Label = 'Repair' }, @{ Key = 'install'; Icon = [string][char]0x2B07; Label = 'Apps' }
    @{ Key = 'revert'; Icon = [string][char]0x21BA; Label = 'Rollback' }
)

# ---------- Localization (English / Russian) ----------
$script:RU = @{
    'Could not detect the active power plan' = 'Не удалось определить активную схему питания'
    'This setting is not available in the current power plan' = 'Этот параметр недоступен в текущей схеме питания'
    'winget not found. Install "App Installer" from the Microsoft Store.' = 'winget не найден. Установите «Установщик приложения» из Microsoft Store.'
    'Creating a restore point...' = 'Создаю точку восстановления...'
    'Restore point was not created. Built-in rollback still works.' = 'Точка восстановления не создана. Встроенный откат работает.'
    'All tweaks from this preset are already applied.' = 'Все твики из этого пресета уже применены.'
    'Working...' = 'Выполняю...'
    'Started in the background.' = 'Запущено в фоне.'
    'Update started in the background.' = 'Обновление запущено в фоне.'
    'Tick the apps you want to install.' = 'Отметьте программы для установки.'
    'No changes: the switches match the current state. Switch a tweak on or off first.' = 'Нет изменений: переключатели совпадают с текущим состоянием. Сначала включите или выключите твик.'
    'Some tweaks need a restart.' = 'Для части твиков нужна перезагрузка.'
    'Pick tweaks and press "Apply changes". A restore point is created first.' = 'Выберите твики и нажмите «Применить». Сначала создаётся точка восстановления.'
    'Cloudflare DNS set.' = 'DNS Cloudflare установлен.'
    'Google DNS set.' = 'DNS Google установлен.'
    'Quad9 DNS set.' = 'DNS Quad9 установлен.'
    'DNS restored to automatic.' = 'DNS возвращён к автоматическим.'
    'DNS cache flushed.' = 'Кэш DNS сброшен.'
    'TRIM completed.' = 'TRIM выполнен.'
    'Recycle Bin emptied.' = 'Корзина очищена.'
    'Thumbnail cache cleared.' = 'Кэш миниатюр очищен.'
    'Reports and dumps removed.' = 'Отчёты и дампы удалены.'
    'Cache cleared.' = 'Кэш очищен.'
    'Windows Update components reset.' = 'Компоненты Центра обновления сброшены.'
    'Done. Restart your PC.' = 'Готово. Перезагрузите ПК.'
    'Explorer restarted.' = 'Проводник перезапущен.'
    'Done.' = 'Готово.'
    'Component store cleanup' = 'Очистка хранилища компонентов'
    'System File Checker' = 'Проверка системных файлов'
    'DISM RestoreHealth' = 'Восстановление образа DISM'
    'Updating programs' = 'Обновление программ'
    'Search tweaks...' = 'Поиск твиков...'
    'Administrator mode' = 'Режим администратора'
    'Apply changes' = 'Применить изменения'
    'Install selected' = 'Установить выбранное'
    'Restart or sign-in required to take effect' = 'Нужна перезагрузка или повторный вход'
    'ACTIVE' = 'ВКЛЮЧЕНО'
    'Active power plan' = 'Активная схема питания'
    'Nothing applied yet.' = 'Пока ничего не применено.'
    'Currently applied' = 'Сейчас применено'
    'Nothing found' = 'Ничего не найдено'
    'Try a different word, for example: telemetry, gpu, dns, theme.' = 'Попробуйте другое слово, например: телеметрия, gpu, dns, тема.'
    'Performance' = 'Производительность'
    'Power' = 'Питание'
    'Privacy' = 'Приватность'
    'Telemetry & Privacy' = 'Телеметрия и приватность'
    'System' = 'Система'
    'Network' = 'Сеть'
    'Updates' = 'Обновления'
    'Disk & SSD' = 'Диск и SSD'
    'Cleanup' = 'Очистка'
    'Repair' = 'Исправления'
    'Apps' = 'Программы'
    'Rollback' = 'Откат'
    'Search' = 'Поиск'
    'Gaming tweaks for CPU, scheduler, mouse and graphics. Every one is reversible.' = 'Игровые твики для процессора, планировщика, мыши и графики. Каждый обратим.'
    'Power plans and fine CPU tuning. Settings apply to the active plan on AC power.' = 'Схемы питания и тонкая настройка процессора. Параметры применяются к активной схеме от сети.'
    'Less tracking and fewer ads in Windows. Everything can be rolled back.' = 'Меньше слежки и рекламы в Windows. Всё откатывается.'
    'Appearance, Explorer and convenience.' = 'Оформление, проводник и удобство.'
    'Switch DNS for all active connections and flush the cache.' = 'Смена DNS для всех активных подключений и сброс кэша.'
    'Control updates without turning off protection. Disabling updates entirely is unsafe, so there is no such option.' = 'Контроль обновлений без отключения защиты. Полностью выключать обновления небезопасно, поэтому такого пункта нет.'
    'Fewer needless writes and better SSD upkeep.' = 'Меньше лишних записей и поддержка скорости SSD.'
    'Temporary data only. These actions cannot be undone.' = 'Только временные данные. Эти действия нельзя откатить.'
    'Windows recovery tools. Long tasks run in the background, no console windows.' = 'Инструменты восстановления Windows. Долгие задачи идут в фоне, без консольных окон.'
    'Tick what you need and press Install. Uses the official winget, silent and in the background.' = 'Отметьте нужное и нажмите «Установить». Используется официальный winget, тихо и в фоне.'
    'Return the system to how it was before the tweaks.' = 'Вернуть систему к тому, что было до твиков.'
    'Windows Game Mode' = 'Игровой режим Windows'
    'Gives the running game priority and holds back background tasks.' = 'Система отдаёт приоритет игре и придерживает фоновые задачи.'
    'Disable Game DVR background recording' = 'Отключить фоновую запись игр (Game DVR)'
    'Stops Xbox Game Bar clip capture. Less CPU and GPU overhead while gaming.' = 'Убирает фоновый захват клипов Xbox Game Bar: меньше нагрузка на CPU и GPU.'
    'Hardware-accelerated GPU scheduling' = 'Аппаратное планирование GPU (HAGS)'
    'The graphics card manages its own task queue and memory. Usually helpful on modern GPUs.' = 'Видеокарта сама управляет очередью задач и памятью. На современных GPU обычно полезно.'
    'More CPU time for games' = 'Больше процессора для игр'
    'Lowers the share of CPU reserved for background multimedia tasks (from 20% to 10%).' = 'Уменьшает долю процессора, резервируемую под фоновые мультимедиа-задачи (с 20% до 10%).'
    'Disable mouse acceleration' = 'Отключить ускорение мыши'
    'Turns off "Enhance pointer precision" for predictable aim in shooters.' = 'Выключает «повышенную точность указателя»: прицел двигается предсказуемо, важно для шутеров.'
    'Disable Sticky Keys popup' = 'Отключить залипание клавиш'
    'No more popup after pressing Shift five times in the middle of a game.' = 'Убирает всплывающее окно после пяти нажатий Shift посреди игры.'
    'Remove startup delay' = 'Убрать задержку автозагрузки'
    'Startup apps launch right after sign-in without the built-in pause.' = 'Программы автозагрузки стартуют сразу, без искусственной паузы после входа.'
    'Disable transparency and window animations' = 'Отключить прозрачность и анимацию окон'
    'Lighter interface, especially on older PCs. Looks stricter.' = 'Интерфейс Windows легче, особенно на слабых ПК. Выглядит строже.'
    'Gaming preset' = 'Игровой пресет'
    'One click: Game Mode, no Game DVR, more CPU for games, no mouse acceleration, no Sticky Keys popup, no startup delay.' = 'В один клик: игровой режим, без Game DVR, больше процессора играм, без ускорения мыши, без залипания клавиш и задержки автозагрузки.'
    'Apply preset' = 'Применить пресет'
    'CPU always at full speed' = 'Процессор всегда на полной частоте'
    'Minimum processor state 100% on AC power: no dips under sudden load. Runs hotter and louder.' = 'Минимальное состояние процессора 100% от сети: нет просадок при резкой нагрузке. Греется и шумит больше.'
    'Disable core parking' = 'Отключить парковку ядер'
    'All CPU cores stay active, fewer latency spikes in games.' = 'Все ядра процессора всегда активны, меньше задержек в играх.'
    'Disable PCIe power saving (ASPM)' = 'Отключить энергосбережение PCIe (ASPM)'
    'GPU and NVMe never sleep between tasks. Fewer micro-stutters, slightly higher power draw.' = 'Видеокарта и NVMe не засыпают между задачами. Меньше микрофризов, чуть больше потребление.'
    'Disable hibernation' = 'Отключить гибернацию'
    'Deletes hiberfil.sys and frees several GB of disk space. Also disables Fast Startup.' = 'Удаляет hiberfil.sys и освобождает несколько ГБ на диске. Заодно отключает быстрый запуск.'
    'Balanced' = 'Сбалансированная'
    'Default Windows plan.' = 'Стандартная схема Windows.'
    'High performance' = 'Высокая производительность'
    'CPU drops its clocks less often.' = 'Процессор реже снижает частоты.'
    'Ultimate Performance' = 'Максимальная производительность (Ultimate)'
    'Hidden desktop plan with zero power-saving latency. Created on first use.' = 'Скрытая схема для ПК: нулевые задержки энергосбережения. Создаётся при первом включении.'
    'Power saver' = 'Экономия энергии'
    'For laptops on battery.' = 'Для ноутбука от батареи.'
    'Enable' = 'Включить'
    'Minimal Windows telemetry' = 'Минимальная телеметрия Windows'
    'Sets diagnostic data to the minimum and disables feedback prompts. On Home/Pro this equals "Basic".' = 'Сбор диагностики на минимум и отключение запросов отзывов. На Home/Pro это уровень «Базовый».'
    'Disable telemetry services' = 'Отключить службы телеметрии'
    'Stops DiagTrack (Connected User Experiences) and dmwappushservice.' = 'Останавливает DiagTrack (Connected User Experiences) и dmwappushservice.'
    'Disable data collection tasks' = 'Отключить задачи сбора данных'
    'Disables Compatibility Appraiser, CEIP and disk diagnostics scheduled tasks.' = 'Отключает плановые задачи Compatibility Appraiser, CEIP и диагностики дисков.'
    'Disable advertising ID' = 'Отключить рекламный идентификатор'
    'Apps no longer get a personal advertising identifier.' = 'Приложения не получают персональный рекламный ID.'
    'Disable tailored experiences' = 'Отключить персонализированные советы'
    'Windows stops using diagnostic data to pick tips and ads.' = 'Windows не использует диагностику для подбора рекомендаций и рекламы.'
    'Disable activity history' = 'Отключить историю действий'
    'Windows no longer collects or uploads your activity log (Timeline).' = 'Windows не собирает и не отправляет журнал ваших действий (Timeline).'
    'Deny location access' = 'Запретить определение местоположения'
    'Location services are off for all apps. Maps and weather will ask for a city.' = 'Геолокация выключена для всех приложений. Карты и погода будут просить город вручную.'
    'Disable feedback requests' = 'Отключить запросы отзывов'
    'Windows stops asking "how is Windows doing".' = 'Windows перестаёт спрашивать «как вам система».'
    'Disable error reporting' = 'Отключить отчёты об ошибках'
    'Crash reports are no longer sent to Microsoft.' = 'Windows не отправляет отчёты о сбоях в Microsoft.'
    'Block promoted app auto-install' = 'Отключить автоустановку рекламных приложений'
    'Windows stops adding promoted games and apps to the Start menu.' = 'Windows не подкидывает игры и приложения-«рекомендации» в Пуск.'
    'Remove suggestions and ads' = 'Убрать рекомендации и рекламу'
    'No tips in Settings, on the lock screen or in the Start menu.' = 'Нет советов в настройках, на экране блокировки и в меню Пуск.'
    'Disable Bing in Start search' = 'Отключить Bing в поиске Пуск'
    'Search looks only on this PC, with no web queries.' = 'Поиск ищет только на ПК, без запросов в интернет.'
    'Disable Copilot' = 'Отключить Copilot'
    'Removes the Windows Copilot AI assistant.' = 'Убирает ИИ-помощника Windows Copilot.'
    'Disable Recall (Windows 11)' = 'Отключить Recall (Windows 11)'
    'Blocks AI screen snapshots and analysis of your activity.' = 'Запрещает ИИ-снимки экрана и анализ ваших действий.'
    'Privacy preset' = 'Пресет приватности'
    'One click: minimal telemetry, no advertising ID, no tailored ads, no activity history, no suggestions, no Bing in search.' = 'В один клик: минимум телеметрии, без рекламного ID, без персонализированной рекламы, без истории действий, без рекомендаций и Bing в поиске.'
    'Windows dark theme' = 'Тёмная тема Windows'
    'Dark appearance for the system and apps.' = 'Тёмное оформление системы и приложений.'
    'Show file extensions' = 'Показывать расширения файлов'
    'Shows .exe, .txt and so on. Protects against fakes like "photo.jpg.exe".' = 'Видно .exe, .txt и т.д. Защищает от подделок вроде «фото.jpg.exe».'
    'Show hidden files' = 'Показывать скрытые файлы'
    'Hidden files and folders become visible in Explorer.' = 'В проводнике видны скрытые файлы и папки.'
    'Open Explorer on "This PC"' = 'Проводник открывается на «Этот компьютер»'
    'Instead of Home / Quick access.' = 'Вместо «Главная» / «Быстрый доступ».'
    'Disable widgets and news' = 'Отключить виджеты и новости'
    'Removes the widgets and news panel from the taskbar.' = 'Убирает панель виджетов и новостей на панели задач.'
    'Disable Cortana' = 'Отключить Cortana'
    'Turns off the voice assistant.' = 'Выключает голосовой помощник.'
    'Disable Fast Startup' = 'Отключить быстрый запуск'
    'Shutdown becomes a full shutdown. Fixes odd behavior and driver issues after "shutting down".' = 'Выключение станет полным, лечит странности после «выключения» и проблемы с драйверами.'
    'Classic context menu (Windows 11)' = 'Классическое контекстное меню (Windows 11)'
    'Right-click shows the full menu right away, no "Show more options". Explorer restarts briefly.' = 'Правый клик сразу показывает полное меню, без «Показать дополнительные параметры». Проводник кратко перезапустится.'
    'Defer feature updates by one year' = 'Отложить крупные обновления на год'
    'Big feature updates arrive after 365 days. Security patches come as usual.' = 'Большие обновления приходят через 365 дней, патчи безопасности как обычно.'
    'No drivers via Windows Update' = 'Не ставить драйверы через Центр обновления'
    'Your GPU driver will not be replaced with an older one behind your back.' = 'Драйвер видеокарты не заменится на устаревший без вашего ведома.'
    'No automatic restart after updates' = 'Не перезагружаться сам после обновлений'
    'No forced restart while you are signed in.' = 'Если вы вошли в систему, автоперезагрузка не произойдёт.'
    'Stop sharing updates with other PCs' = 'Отключить раздачу обновлений другим ПК'
    'Delivery Optimization will not use your internet to upload update files.' = 'Delivery Optimization не использует ваш интернет для раздачи файлов.'
    'Make sure TRIM is enabled' = 'Гарантировать TRIM для SSD'
    'TRIM helps an SSD keep its write speed. Usually already on; this guarantees it.' = 'TRIM помогает SSD сохранять скорость записи. Обычно уже включён, твик это гарантирует.'
    'Stop writing last-access time' = 'Не писать время последнего доступа к файлам'
    'Fewer needless disk writes every time a file is opened. Extends SSD life.' = 'Меньше лишних записей на диск при каждом открытии файла. Продлевает жизнь SSD.'
    'Disable SysMain (Superfetch)' = 'Отключить SysMain (Superfetch)'
    'Preloads apps into memory. Nearly useless on SSD. Keep it enabled on HDD.' = 'Подгрузка программ в память заранее. На SSD почти бесполезна, на HDD лучше оставить.'
    'Run TRIM on drive C:' = 'Прогнать TRIM по диску C:'
    'One-time SSD optimization. Safe.' = 'Разовая оптимизация SSD. Безопасно.'
    'Run' = 'Запустить'
    'Fast DNS with a focus on privacy.' = 'Быстрый DNS с упором на приватность.'
    'Stable and fast.' = 'Стабильный и быстрый.'
    'Blocks malicious domains.' = 'Блокирует вредоносные домены.'
    'ISP DNS (default)' = 'DNS от провайдера (по умолчанию)'
    'Restore automatic DNS settings.' = 'Вернуть автоматические настройки DNS.'
    'Restore' = 'Вернуть'
    'Flush DNS cache' = 'Сбросить кэш DNS'
    'Helps when sites will not open or open at an old address.' = 'Помогает, если сайты не открываются или открываются по старому адресу.'
    'Flush' = 'Сбросить'
    'Apply' = 'Применить'
    'Temporary files' = 'Временные файлы'
    'User and Windows Temp folders. Files in use are skipped.' = 'Папки Temp пользователя и Windows. Занятые файлы пропускаются.'
    'Clean' = 'Очистить'
    'Recycle Bin' = 'Корзина'
    'Empties the Recycle Bin on all drives.' = 'Очищает корзину на всех дисках.'
    'Thumbnail cache' = 'Кэш миниатюр'
    'Thumbnails are rebuilt automatically.' = 'Миниатюры пересоздадутся сами.'
    'Error reports and dumps' = 'Отчёты об ошибках и дампы'
    'WER files, minidumps and MEMORY.DMP.' = 'Файлы WER, минидампы и MEMORY.DMP.'
    'Delivery Optimization cache' = 'Кэш Delivery Optimization'
    'Update files kept for sharing with other PCs.' = 'Файлы обновлений, оставшиеся для раздачи другим ПК.'
    'Component store cleanup (WinSxS)' = 'Очистка хранилища компонентов (WinSxS)'
    'Removes old Windows component versions. Runs in the background and takes a few minutes.' = 'Удаляет старые версии компонентов Windows. Идёт в фоне, занимает несколько минут.'
    'System File Checker (SFC)' = 'Проверка системных файлов (SFC)'
    'Scans and repairs corrupted Windows files. Runs in the background.' = 'Ищет и чинит повреждённые файлы Windows. Работает в фоне.'
    'Repair Windows image (DISM)' = 'Восстановление образа Windows (DISM)'
    'DISM RestoreHealth repairs the component store. Needs internet and takes a while.' = 'DISM RestoreHealth чинит хранилище компонентов. Нужен интернет, занимает время.'
    'Reset Windows Update' = 'Сброс Центра обновления Windows'
    'Clears the update cache and restarts services. Helps when updates get stuck.' = 'Чистит кэш обновлений и перезапускает службы. Помогает, когда обновления зависают.'
    'Reset' = 'Сбросить'
    'Reset network stack' = 'Сброс сетевого стека'
    'Winsock and IP reset. Fixes "connected, no internet". Restart required afterwards.' = 'Сброс Winsock и IP. Лечит «сеть есть, интернета нет». Потом нужна перезагрузка.'
    'Restart Explorer' = 'Перезапуск проводника'
    'Reloads the taskbar and desktop if they freeze or glitch.' = 'Перезагружает панель задач и рабочий стол, если они зависли.'
    'Restart' = 'Перезапустить'
    'Update all programs' = 'Обновить все программы'
    'Update' = 'Обновить'
    'Web browser' = 'Браузер'
    'Browser with built-in ad blocking' = 'Браузер с блокировкой рекламы'
    'File archiver' = 'Архиватор'
    'Media player that opens almost anything' = 'Видеоплеер, открывает почти всё'
    'Voice and text chat' = 'Голосовой и текстовый чат'
    'Game store and library' = 'Магазин и библиотека игр'
    'Messenger' = 'Мессенджер'
    'Recording and streaming' = 'Запись и стрим'
    'Ad-free torrent client' = 'Торрент-клиент без рекламы'
    'Handy text editor' = 'Удобный текстовый редактор'
    'Code editor' = 'Редактор кода'
    'Programming language' = 'Язык программирования'
    'Version control' = 'Система контроля версий'
    'Temperatures, clocks and hardware sensors' = 'Температуры, частоты и датчики железа'
    'CPU, RAM and motherboard info' = 'Информация о процессоре, памяти и плате'
    'GPU monitoring and tuning' = 'Мониторинг и настройка видеокарты'
    'Instant file search' = 'Мгновенный поиск файлов'
    'Handy Windows utilities' = 'Полезные утилиты Windows'
    'Screenshots and screen recording' = 'Скриншоты и запись экрана'
    'Music' = 'Музыка'
    'Create a restore point' = 'Создать точку восстановления'
    'System snapshot in case you want to go back.' = 'Снимок системы на случай, если захочется вернуться.'
    'Create' = 'Создать'
    'Revert all changes' = 'Откатить все изменения'
    'Returns everything applied by Tweaks by yzemu to its original values.' = 'Возвращает всё, что применила Tweaks by yzemu, к исходным значениям.'
    'Revert' = 'Откатить'
}
$script:RuRx = @(
    @{ Rx = '^Power plan enabled: (.+)\.$'; Fmt = 'Включена схема питания: {0}.' }
    @{ Rx = '^The ''(.+)'' plan is not available on this PC$'; Fmt = 'Схема «{0}» недоступна на этом ПК' }
    @{ Rx = '^Freed (.+) MB\.$'; Fmt = 'Освобождено {0} МБ.' }
    @{ Rx = '^Preset applied: (\d+) tweak\(s\)\.(.*)$'; Fmt = 'Пресет применён, твиков: {0}. {1}' }
    @{ Rx = '^Reverted (\d+) tweak\(s\)\. Some changes apply after a restart\.$'; Fmt = 'Откачено твиков: {0}. Часть изменений применится после перезагрузки.' }
    @{ Rx = '^Done, changed: (\d+)\.(.*)$'; Fmt = 'Готово, изменено: {0}. {1}' }
    @{ Rx = '^Done: (\d+)\. Failed: (.*)$'; Fmt = 'Готово: {0}. Не удалось: {1}' }
    @{ Rx = '^\[(\d+)/(\d+)\] (.+)\.\.\.$'; Fmt = '[{0}/{1}] {2}...' }
    @{ Rx = '^Installing (.+)$'; Fmt = 'Установка: {0}' }
    @{ Rx = '^Finished: (\d+) OK, failed: (.*)$'; Fmt = 'Завершено: успешно {0}, с ошибками: {1}' }
    @{ Rx = '^Finished: all (\d+) task\(s\) completed\.$'; Fmt = 'Завершено: все задачи ({0}) выполнены.' }
    @{ Rx = '^(\d+) result\(s\) for "(.*)"$'; Fmt = 'Найдено: {0}. Запрос: «{1}»' }
    @{ Rx = '^(\d+) tweak\(s\) active$'; Fmt = 'Активных твиков: {0}' }
    @{ Rx = '^Failed: (.*)$'; Fmt = 'Не удалось: {0}' }
    @{ Rx = '^Error: (.*)$'; Fmt = 'Ошибка: {0}' }
)
function T($s) {
    if ($script:Lang -ne 'ru' -or [string]::IsNullOrEmpty($s)) { return $s }
    if ($script:RU.ContainsKey($s)) { return $script:RU[$s] }
    foreach ($r in $script:RuRx) {
        $m = [regex]::Match($s, $r.Rx)
        if ($m.Success) {
            $g = @(); for ($i = 1; $i -lt $m.Groups.Count; $i++) { $g += (T $m.Groups[$i].Value.Trim()) }
            return ($r.Fmt -f $g).Trim()
        }
    }
    $s
}

# ---------- UI (XAML) ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Tweaks by yzemu" Width="1040" Height="700" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize" FontFamily="Segoe UI" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Tog" TargetType="ToggleButton">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Grid Width="48" Height="26" Background="Transparent" Cursor="Hand">
            <Border x:Name="Track" CornerRadius="13" Background="#1A1230" BorderBrush="#4B3C7A" BorderThickness="1"/>
            <Ellipse x:Name="Thumb" Width="18" Height="18" HorizontalAlignment="Left" Margin="4,0,0,0" Fill="#B9A9E8">
              <Ellipse.RenderTransform><TranslateTransform x:Name="Tt" X="0"/></Ellipse.RenderTransform>
            </Ellipse>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Trigger.EnterActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="Tt" Storyboard.TargetProperty="X" To="22" Duration="0:0:0.2">
                  <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                </DoubleAnimation>
                <ColorAnimation Storyboard.TargetName="Track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#7C3AED" Duration="0:0:0.2"/>
                <ColorAnimation Storyboard.TargetName="Thumb" Storyboard.TargetProperty="(Shape.Fill).(SolidColorBrush.Color)" To="#FFFFFF" Duration="0:0:0.2"/>
              </Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="Tt" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.2">
                  <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                </DoubleAnimation>
                <ColorAnimation Storyboard.TargetName="Track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#1A1230" Duration="0:0:0.2"/>
                <ColorAnimation Storyboard.TargetName="Thumb" Storyboard.TargetProperty="(Shape.Fill).(SolidColorBrush.Color)" To="#B9A9E8" Duration="0:0:0.2"/>
              </Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" CornerRadius="10" Padding="20,9" Cursor="Hand">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#9333EA" Offset="0"/><GradientStop Color="#5B21B6" Offset="1"/></LinearGradientBrush></Border.Background>
            <Border.Effect><DropShadowEffect Color="#7C3AED" BlurRadius="16" ShadowDepth="0" Opacity="0.5"/></Border.Effect>
            <ContentPresenter HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.88"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.7"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Nav" TargetType="Button">
      <Setter Property="Foreground" Value="#CFC3F2"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" CornerRadius="10" Background="{TemplateBinding Background}" Padding="14,9" Margin="0,0,0,3" Cursor="Hand">
            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#26A855F7"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Foreground" Value="#CFC3F2"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" CornerRadius="8" Background="Transparent" Cursor="Hand">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#33A855F7"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Grid Background="Transparent">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#667C3AED" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Margin="14" CornerRadius="18" BorderThickness="1" BorderBrush="#3D2D6B" RenderTransformOrigin="0.5,0.5">
    <Border.RenderTransform><ScaleTransform x:Name="RootScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
    <Border.Effect><DropShadowEffect Color="#7C3AED" BlurRadius="30" ShadowDepth="0" Opacity="0.4"/></Border.Effect>
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop x:Name="G1" Color="#07040D" Offset="0"/>
        <GradientStop x:Name="G2" Color="#0D0719" Offset="0.55"/>
        <GradientStop x:Name="G3" Color="#170B2E" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Grid>
      <Canvas IsHitTestVisible="False">
        <Canvas.Clip><RectangleGeometry Rect="0,0,1012,672" RadiusX="18" RadiusY="18"/></Canvas.Clip>
        <Ellipse Width="460" Height="460" Canvas.Left="-150" Canvas.Top="-160">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#557C3AED" Offset="0"/><GradientStop Color="#007C3AED" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
          <Ellipse.RenderTransform><TranslateTransform x:Name="T1"/></Ellipse.RenderTransform>
        </Ellipse>
        <Ellipse Width="540" Height="540" Canvas.Left="560" Canvas.Top="300">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#449333EA" Offset="0"/><GradientStop Color="#009333EA" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
          <Ellipse.RenderTransform><TranslateTransform x:Name="T2"/></Ellipse.RenderTransform>
        </Ellipse>
        <Ellipse Width="320" Height="320" Canvas.Left="360" Canvas.Top="-140">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#336D28D9" Offset="0"/><GradientStop Color="#006D28D9" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
          <Ellipse.RenderTransform><TranslateTransform x:Name="T3"/></Ellipse.RenderTransform>
        </Ellipse>
      </Canvas>

      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="58"/><RowDefinition Height="*"/></Grid.RowDefinitions>

        <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
          <StackPanel Orientation="Horizontal" Margin="26,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="&#x25C6;" FontFamily="Segoe UI Symbol" FontSize="18" Foreground="#A78BFA" Margin="0,0,10,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="TitleText" Text="TWEAKS" FontSize="19" FontWeight="Bold" Foreground="#F5F0FF" VerticalAlignment="Center">
              <TextBlock.Effect><DropShadowEffect Color="#A78BFA" BlurRadius="10" ShadowDepth="0" Opacity="0.85"/></TextBlock.Effect>
            </TextBlock>
            <TextBlock Text="by yzemu" FontSize="13" FontStyle="Italic" Foreground="#9F86E0" Margin="9,4,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,16,0" VerticalAlignment="Center">
            <Button x:Name="BtnLang" Style="{StaticResource Chrome}" Width="64" Height="32" Margin="0,0,10,0" ToolTip="English / Русский"/>
            <Button x:Name="BtnMin" Style="{StaticResource Chrome}" Content="&#x2014;" Width="40" Height="32" Margin="0,0,4,0"/>
            <Button x:Name="BtnClose" Style="{StaticResource Chrome}" Content="&#x2715;" FontFamily="Segoe UI Symbol" Width="40" Height="32"/>
          </StackPanel>
          <Grid VerticalAlignment="Bottom" Height="2" ClipToBounds="True" Margin="20,0,20,0">
            <Border Width="280" HorizontalAlignment="Left">
              <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#00A78BFA" Offset="0"/><GradientStop Color="#FFA855F7" Offset="0.5"/><GradientStop Color="#00A78BFA" Offset="1"/></LinearGradientBrush></Border.Background>
              <Border.RenderTransform><TranslateTransform x:Name="Shimmer" X="-280"/></Border.RenderTransform>
            </Border>
          </Grid>
        </Grid>

        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Grid.Column="0" Margin="16,8,8,16" CornerRadius="16" Background="#55000000" BorderBrush="#221B3A" BorderThickness="1" Padding="10,12">
            <DockPanel>
              <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
                <TextBlock x:Name="NavInfo" FontSize="11.5" Foreground="#8B7BBF" HorizontalAlignment="Center"/>
                <TextBlock x:Name="AdminText" Text="Administrator mode" FontSize="11" Foreground="#5F5190" HorizontalAlignment="Center" Margin="0,2,0,0"/>
              </StackPanel>
              <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="NavPanel"/></ScrollViewer>
            </DockPanel>
          </Border>

          <Grid Grid.Column="1" Margin="8,4,0,0">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="8,4,24,12">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0">
                <TextBlock x:Name="PageTitle" FontSize="27" FontWeight="Bold" Foreground="#FFFFFF"/>
                <TextBlock x:Name="PageSub" FontSize="12.5" Foreground="#A99BD0" Margin="0,4,16,0" TextWrapping="Wrap"/>
              </StackPanel>
              <Border Grid.Column="1" Width="220" Height="36" CornerRadius="10" Background="#66000000" BorderBrush="#3A2D5E" BorderThickness="1" VerticalAlignment="Top" Margin="0,6,0,0">
                <Grid>
                  <TextBlock x:Name="SearchHint" Text="Search tweaks..." Foreground="#6E5F96" FontSize="13" VerticalAlignment="Center" Margin="13,0,0,0" IsHitTestVisible="False"/>
                  <TextBox x:Name="Search" Background="Transparent" BorderThickness="0" Foreground="#F5F0FF" CaretBrush="#A78BFA" FontSize="13" VerticalContentAlignment="Center" Padding="10,0"/>
                </Grid>
              </Border>
            </Grid>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="List" Margin="8,2,18,8"/>
            </ScrollViewer>
            <Grid Grid.Row="2" Margin="8,6,24,18">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Grid x:Name="BusyBar" Grid.Row="0" Grid.ColumnSpan="2" Height="3" ClipToBounds="True" Margin="0,0,0,10" Visibility="Collapsed">
                <Border Background="#221B3A" CornerRadius="2"/>
                <Border x:Name="BusyBlock" Width="140" HorizontalAlignment="Left" CornerRadius="2">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#007C3AED" Offset="0"/><GradientStop Color="#FFA855F7" Offset="0.5"/><GradientStop Color="#007C3AED" Offset="1"/></LinearGradientBrush></Border.Background>
                  <Border.RenderTransform><TranslateTransform x:Name="BusyShift" X="-140"/></Border.RenderTransform>
                </Border>
              </Grid>
              <TextBlock x:Name="Status" Grid.Row="1" Foreground="#CDBFF5" FontSize="12.5" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,16,0"/>
              <Button x:Name="ApplyBtn" Grid.Row="1" Grid.Column="1" Style="{StaticResource Btn}" Content="Apply changes"/>
            </Grid>
          </Grid>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$script:CardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="14" Padding="18,14" Margin="0,0,0,10" Background="#A6120B22" BorderBrush="#33283F" BorderThickness="1">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel>
      <TextBlock x:Name="T" FontSize="14.5" FontWeight="SemiBold" Foreground="#F5F0FF" TextWrapping="Wrap"/>
      <TextBlock x:Name="D" FontSize="12.5" Foreground="#A99BD0" Margin="0,4,0,0" TextWrapping="Wrap"/>
      <TextBlock x:Name="B" FontSize="11.5" FontWeight="SemiBold" Foreground="#A78BFA" Margin="0,5,0,0" Visibility="Collapsed"/>
      <TextBlock x:Name="N" FontSize="11.5" Foreground="#C4B5FD" Margin="0,4,0,0" Visibility="Collapsed"/>
    </StackPanel>
    <ContentControl x:Name="Slot" Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0"/>
  </Grid>
</Border>
'@

$script:Win = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'Root', 'TitleBar', 'BtnMin', 'BtnClose', 'NavPanel', 'NavInfo', 'PageTitle', 'PageSub', 'List', 'Status', 'ApplyBtn', 'Search', 'SearchHint', 'BusyBar', 'BtnLang', 'AdminText') {
    Set-Variable -Scope Script -Name $n -Value $script:Win.FindName($n)
}

# ---------- Animations ----------
function New-Brush($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
$script:BrIdle = New-Brush '#33283F'; $script:BrHover = New-Brush '#7C4DDB'
$script:BgIdle = New-Brush '#A6120B22'; $script:BgHover = New-Brush '#CC1D1236'
$script:NavOn = New-Brush '#4D7C3AED'; $script:NavOff = [Windows.Media.Brushes]::Transparent

function Animate($target, $prop, $from, $to, $ms, $delay = 0) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    if ($null -ne $from) { $a.From = [double]$from }
    $a.To = [double]$to
    $a.Duration = [TimeSpan]::FromMilliseconds($ms)
    $a.BeginTime = [TimeSpan]::FromMilliseconds($delay)
    $e = New-Object Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; $a.EasingFunction = $e
    $target.BeginAnimation($prop, $a)
}
function Loop-Double($target, $prop, $from, $to, $sec) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.From = [double]$from; $a.To = [double]$to
    $a.Duration = [TimeSpan]::FromSeconds($sec); $a.AutoReverse = $true
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $e = New-Object Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
    $target.BeginAnimation($prop, $a)
}
function Loop-Color($stop, $to, $sec) {
    $a = New-Object Windows.Media.Animation.ColorAnimation
    $a.To = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($to)
    $a.Duration = [TimeSpan]::FromSeconds($sec); $a.AutoReverse = $true
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $stop.BeginAnimation([Windows.Media.GradientStop]::ColorProperty, $a)
}
function Add-Scale($el) {
    $el.RenderTransformOrigin = [Windows.Point]::new(0.5, 0.5)
    $el.RenderTransform = New-Object Windows.Media.ScaleTransform 1, 1
    $el.Add_MouseEnter({ param($s, $e)
        Animate $s.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) $null 1.05 130
        Animate $s.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) $null 1.05 130 })
    $el.Add_MouseLeave({ param($s, $e)
        Animate $s.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) $null 1 130
        Animate $s.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) $null 1 130 })
}
function Add-CardFx($c) {
    $c.RenderTransform = New-Object Windows.Media.TranslateTransform 0, 0
    $c.Add_MouseEnter({ param($s, $e) $s.BorderBrush = $script:BrHover; $s.Background = $script:BgHover })
    $c.Add_MouseLeave({ param($s, $e) $s.BorderBrush = $script:BrIdle; $s.Background = $script:BgIdle })
}
function Set-Status($text) {
    $script:Status.Text = (T ([string]$text))
    Animate $script:Status ([Windows.UIElement]::OpacityProperty) 0 1 300
    $script:Win.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Render)
}

# ---------- Cards and pages ----------
function New-Card($title, $desc, $note, $badge = '') {
    $c = [Windows.Markup.XamlReader]::Parse($script:CardXaml)
    $c.FindName('T').Text = $title
    $c.FindName('D').Text = $desc
    if ($note) { $n = $c.FindName('N'); $n.Text = $note; $n.Visibility = 'Visible' }
    if ($badge) { $bb = $c.FindName('B'); $bb.Text = $badge; $bb.Visibility = 'Visible' }
    $c
}
function New-ActionButton($label, $action) {
    $b = New-Object Windows.Controls.Button
    $b.Content = $label; $b.Style = $script:Win.FindResource('Btn'); $b.Tag = $action
    Add-Scale $b
    $b.Add_Click({ param($s, $e)
        try { Set-Status 'Working...'; $msg = & $s.Tag.Run; Set-Status ([string]$msg) }
        catch { Set-Status "Error: $($_.Exception.Message)" }
        Show-Page $script:Page -Keep })
    $b
}
function Get-PageTweaks($name) {
    if ($name -eq 'search') {
        $q = $script:Query
        $script:Tweaks | Where-Object { (-not $_.Min -or $script:Build -ge $_.Min) -and ($_.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Desc.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) }
    } else {
        $script:Tweaks | Where-Object { $_.Page -eq $name -and (-not $_.Min -or $script:Build -ge $_.Min) }
    }
}
function Show-Page($name, [switch]$Keep) {
    $script:Page = $name
    $script:Toggles = @{}
    $script:List.Children.Clear()
    $meta = $script:Meta[$name]
    $script:PageTitle.Text = (T $meta.Title)
    $script:PageSub.Text = (T $meta.Sub)
    $script:ApplyBtn.Content = (T $(if ($name -eq 'install') { 'Install selected' } else { 'Apply changes' }))

    $items = @(if ($name -eq 'install') { $script:Apps } else { Get-PageTweaks $name })
    if ($name -eq 'search') { $script:PageSub.Text = (T "$($items.Count) result(s) for `"$($script:Query)`"") }
    $tcards = @()
    foreach ($t in $items) {
        $c = New-Card (T $t.Title) (T $t.Desc) $(if ($t.Reboot) { T 'Restart or sign-in required to take effect' } else { '' }) $(if ($name -ne 'install' -and $script:Backup.ContainsKey($t.Id)) { T 'ACTIVE' } else { '' })
        $tg = New-Object Windows.Controls.Primitives.ToggleButton
        $tg.Style = $script:Win.FindResource('Tog')
        $tg.IsChecked = $(if ($name -eq 'install') { $false } else { $script:Backup.ContainsKey($t.Id) })
        $script:Toggles[$t.Id] = $tg
        $c.FindName('Slot').Content = $tg
        $c.Tag = $tg
        $c.Add_MouseLeftButtonUp({ param($s, $e) if ($s.Tag) { $s.Tag.IsChecked = -not $s.Tag.IsChecked } })
        $tcards += $c
    }
    $top = @(); $acards = @()
    foreach ($a in $script:Actions[$name]) {
        $c = New-Card (T $a.Title) (T $a.Desc) ''
        $c.FindName('Slot').Content = (New-ActionButton (T $a.Label) $a)
        if ($a.Top) { $top += $c } else { $acards += $c }
    }
    $pre = @(); $post = @()
    if ($name -eq 'power') {
        $cur = (powercfg /getactivescheme | Out-String).Trim()
        if ($cur -match '\((.+)\)') { $cur = $Matches[1] }
        $pre += (New-Card (T 'Active power plan') $cur '')
        $cards = $pre + $acards + $tcards
    } else {
        if ($name -eq 'revert') {
            $applied = @($script:Tweaks | Where-Object { $script:Backup.ContainsKey($_.Id) } | ForEach-Object { T $_.Title })
            $txt = if ($applied.Count) { $applied -join "`n" } else { T 'Nothing applied yet.' }
            $post += (New-Card (T 'Currently applied') $txt '')
        }
        if ($name -eq 'search' -and -not $items.Count) { $post += (New-Card (T 'Nothing found') (T 'Try a different word, for example: telemetry, gpu, dns, theme.') '') }
        $cards = $top + $tcards + $acards + $post
    }
    $script:ApplyBtn.Visibility = $(if ($script:Toggles.Count) { 'Visible' } else { 'Collapsed' })

    $i = 0
    foreach ($c in $cards) {
        $script:List.Children.Add($c) | Out-Null
        Add-CardFx $c
        if (-not $Keep) {
            $c.Opacity = 0
            Animate $c ([Windows.UIElement]::OpacityProperty) 0 1 360 ([Math]::Min($i, 10) * 55)
            Animate $c.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) 22 0 420 ([Math]::Min($i, 10) * 55)
        }
        $i++
    }
    foreach ($k in $script:NavButtons.Keys) {
        $on = ($k -eq $name)
        $script:NavButtons[$k].Background = $(if ($on) { $script:NavOn } else { $script:NavOff })
        $script:NavButtons[$k].Foreground = New-Brush $(if ($on) { '#FFFFFF' } else { '#CFC3F2' })
    }
    $script:NavInfo.Text = (T "$($script:Backup.Count) tweak(s) active")
    if (-not $Keep) {
        Animate $script:PageTitle ([Windows.UIElement]::OpacityProperty) 0 1 340
        Animate $script:PageSub ([Windows.UIElement]::OpacityProperty) 0 1 480
    }
}

# ---------- Navigation and events ----------
$script:NavButtons = @{}; $script:NavLabels = @{}
$script:Query = ''; $script:Prev = 'perf'; $script:NoSearch = $false
foreach ($n in $script:NavList) {
    $b = New-Object Windows.Controls.Button
    $b.Style = $script:Win.FindResource('Nav'); $b.Tag = $n.Key
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $ic = New-Object Windows.Controls.TextBlock; $ic.Text = $n.Icon; $ic.FontFamily = 'Segoe UI Symbol'; $ic.FontSize = 15; $ic.Width = 26; $ic.VerticalAlignment = 'Center'
    $lb = New-Object Windows.Controls.TextBlock; $lb.Text = (T $n.Label); $lb.Tag = $n.Label; $script:NavLabels[$n.Key] = $lb; $lb.FontSize = 14; $lb.VerticalAlignment = 'Center'
    $sp.Children.Add($ic) | Out-Null; $sp.Children.Add($lb) | Out-Null
    $b.Content = $sp
    $b.Add_Click({ param($s, $e)
        $script:NoSearch = $true; $script:Search.Text = ''; $script:NoSearch = $false
        $script:SearchHint.Visibility = 'Visible'
        Show-Page $s.Tag })
    $script:NavPanel.Children.Add($b) | Out-Null
    $script:NavButtons[$n.Key] = $b
}

function Update-Chrome {
    foreach ($k in $script:NavLabels.Keys) { $script:NavLabels[$k].Text = (T $script:NavLabels[$k].Tag) }
    $script:SearchHint.Text = (T 'Search tweaks...')
    $script:AdminText.Text = (T 'Administrator mode')
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    foreach ($l in 'EN', 'RU') {
        $on = ($l.ToLower() -eq $script:Lang)
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $l; $tb.FontSize = 13
        $tb.FontWeight = $(if ($on) { 'Bold' } else { 'Normal' })
        $tb.Foreground = New-Brush $(if ($on) { '#FFFFFF' } else { '#6E5F96' })
        $sp.Children.Add($tb) | Out-Null
        if ($l -eq 'EN') { $sep = New-Object Windows.Controls.TextBlock; $sep.Text = ' | '; $sep.FontSize = 13; $sep.Foreground = New-Brush '#4B3C7A'; $sp.Children.Add($sep) | Out-Null }
    }
    $script:BtnLang.Content = $sp
}
function Set-Lang($l) {
    $script:Lang = $l
    try { Set-Content -Path $LangFile -Value $l -Encoding ASCII } catch {}
    Update-Chrome
    if ($script:Page -eq 'search') { Show-Page 'search' -Keep } else { Show-Page $script:Page -Keep }
}
$script:BtnLang.Add_Click({ Set-Lang $(if ($script:Lang -eq 'ru') { 'en' } else { 'ru' }) })
Update-Chrome
foreach ($b in $script:ApplyBtn) { Add-Scale $b }
$script:BtnMin.Add_Click({ $script:Win.WindowState = 'Minimized' })
$script:BtnClose.Add_Click({ $script:Win.Close() })
$script:TitleBar.Add_MouseLeftButtonDown({ try { $script:Win.DragMove() } catch {} })

$script:Search.Add_TextChanged({
    if ($script:NoSearch) { return }
    $q = $script:Search.Text.Trim()
    $script:SearchHint.Visibility = $(if ($script:Search.Text.Length) { 'Collapsed' } else { 'Visible' })
    if ($q.Length) {
        $script:Query = $q
        if ($script:Page -ne 'search') { $script:Prev = $script:Page; Show-Page 'search' } else { Show-Page 'search' -Keep }
    } elseif ($script:Page -eq 'search') { Show-Page $script:Prev }
})

$script:ApplyBtn.Add_Click({
    if ($script:Page -eq 'install') {
        $ids = @($script:Toggles.Keys | Where-Object { $script:Toggles[$_].IsChecked })
        if (-not $ids.Count) { Set-Status 'Tick the apps you want to install.'; return }
        try { Test-Winget } catch { Set-Status $_.Exception.Message; return }
        foreach ($id in $ids) {
            $app = $script:Apps | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            Enqueue-Job "Installing $($app.Title)" 'cmd.exe' "/c winget install --id $id -e $WingetFlags" $WingetOk
        }
        foreach ($tg in $script:Toggles.Values) { $tg.IsChecked = $false }
        return
    }
    $pending = @()
    foreach ($t in $script:Tweaks) {
        if (-not $script:Toggles.ContainsKey($t.Id)) { continue }
        if ([bool]$script:Toggles[$t.Id].IsChecked -ne $script:Backup.ContainsKey($t.Id)) { $pending += $t }
    }
    if (-not $pending.Count) { Set-Status 'No changes: the switches match the current state. Switch a tweak on or off first.'; return }
    if ($pending | Where-Object { [bool]$script:Toggles[$_.Id].IsChecked }) { Ensure-RestorePoint }
    $errs = @(); $reboot = $false; $changed = 0
    foreach ($t in $pending) {
        $want = [bool]$script:Toggles[$t.Id].IsChecked
        try {
            if ($want) { Invoke-Apply $t } else { Invoke-Undo $t }
            $changed++; if ($t.Reboot) { $reboot = $true }
        } catch { $errs += "$($t.Title): $($_.Exception.Message)" }
    }
    Save-Backup
    if ($errs.Count) { Set-Status ("Done: $changed. Failed: " + ($errs -join '; ')) }
    else { Set-Status ("Done, changed: $changed." + $(if ($reboot) { ' Some tweaks need a restart.' } else { '' })) }
    Show-Page $script:Page -Keep
})

$script:Win.Add_Loaded({
    try {
        $script:Win.Opacity = 0
        Animate $script:Win ([Windows.UIElement]::OpacityProperty) 0 1 450
        $rs = $script:Win.FindName('RootScale')
        Animate $rs ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.95 1 520
        Animate $rs ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.95 1 520
        Loop-Color ($script:Win.FindName('G1')) '#0E0720' 6
        Loop-Color ($script:Win.FindName('G2')) '#1A0D38' 8
        Loop-Color ($script:Win.FindName('G3')) '#2E1565' 7
        Loop-Double ($script:Win.FindName('T1')) ([Windows.Media.TranslateTransform]::XProperty) 0 160 9
        Loop-Double ($script:Win.FindName('T1')) ([Windows.Media.TranslateTransform]::YProperty) 0 90 11
        Loop-Double ($script:Win.FindName('T2')) ([Windows.Media.TranslateTransform]::XProperty) 0 -180 10
        Loop-Double ($script:Win.FindName('T2')) ([Windows.Media.TranslateTransform]::YProperty) 0 -110 12
        Loop-Double ($script:Win.FindName('T3')) ([Windows.Media.TranslateTransform]::XProperty) -60 120 8
        $sh = New-Object Windows.Media.Animation.DoubleAnimation(-280, 1000, [TimeSpan]::FromSeconds(2.8))
        $sh.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        ($script:Win.FindName('Shimmer')).BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $sh)
        $bs = New-Object Windows.Media.Animation.DoubleAnimation(-140, 900, [TimeSpan]::FromSeconds(1.5))
        $bs.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        ($script:Win.FindName('BusyShift')).BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $bs)
    } catch {}
    try { Loop-Double ($script:Win.FindName('TitleText')).Effect ([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 6 24 1.6 } catch {}
})

Show-Page 'perf'
Set-Status 'Pick tweaks and press "Apply changes". A restore point is created first.'
$script:Win.ShowDialog() | Out-Null

} catch {
    [Windows.MessageBox]::Show("Tweaks by yzemu crashed:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)", 'Tweaks by yzemu', 'OK', 'Error') | Out-Null
}
