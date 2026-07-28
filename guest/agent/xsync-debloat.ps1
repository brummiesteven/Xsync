<#
.SYNOPSIS
    xsync - trim Windows down to a gaming-only appliance.

.DESCRIPTION
    This VM exists to run Game Pass titles and nothing else. Nobody browses the
    web on it, reads mail on it, or looks at its desktop. Everything that isn't
    gaming is dead weight: background CPU that costs frametimes, RAM out of the
    20 GiB the guest has, and disk churn on the same NVMe the games stream from.

    The important part of this script is what it REFUSES to touch. Most Windows
    debloat scripts break Game Pass, because Game Pass depends on components that
    look like bloat from the outside:

      Microsoft.GamingServices        installs and launches every Game Pass title
      Microsoft.XboxIdentityProvider  sign-in; without it, nothing authenticates
      Microsoft.GamingApp             the Xbox app itself
      Microsoft.WindowsStore          Game Pass installs come through the Store
      Microsoft.DesktopAppInstaller   dependency resolution for packaged apps
      Microsoft.VCLibs / .NET / UI.Xaml   runtime dependencies of the above
      XblAuthManager, XblGameSave, XboxGipSvc, XboxNetApiSvc, GamingServices*

    Those are hard-protected below: the removal loop skips anything matching them
    even if a pattern would otherwise select it. Nothing here disables Defender or
    Windows Update either - the first is a security decision that isn't mine to
    make silently, and the second is how Gaming Services keeps itself working.
    Defender gets a scan exclusion for the games directory instead, which is the
    performance win without the exposure.

.PARAMETER DryRun
    Report what would change without changing anything.
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Continue'

$LogFile = 'C:\ProgramData\xsync\debloat.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}

function Say {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

if ($DryRun) { Say 'DRY RUN - nothing will be changed' 'WARN' }

# ============================================================== protected list

# Anything matching these is never removed or disabled, regardless of what the
# removal patterns below would otherwise select. Game Pass depends on all of it.
$ProtectedApps = @(
    '*GamingServices*'
    '*XboxIdentityProvider*'
    '*GamingApp*'
    '*WindowsStore*'
    '*StorePurchaseApp*'
    '*DesktopAppInstaller*'
    '*VCLibs*'
    '*NET.Native*'
    '*UI.Xaml*'
    '*WindowsAppRuntime*'
    '*DirectXRuntime*'
    '*XboxGameCallableUI*'
    '*XboxSpeechToTextOverlay*'
    '*SecHealthUI*'
    '*Winget*'
)

$ProtectedServices = @(
    'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc',
    'GamingServices', 'GamingServicesNet',
    'BITS', 'wuauserv', 'DoSvc', 'InstallService',
    'AudioSrv', 'Audiosrv', 'AudioEndpointBuilder',
    'WlanSvc', 'Dhcp', 'Dnscache', 'NlaSvc',
    'WinDefend', 'SecurityHealthService', 'wscsvc'
)

function Test-Protected {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}

# ============================================================== appx removal

# Safe to remove: none of these are referenced by Game Pass, the Store, or any
# game runtime.
$RemoveApps = @(
    'Microsoft.BingNews'
    'Microsoft.BingWeather'
    'Microsoft.BingSearch'
    'Microsoft.BingFinance'
    'Microsoft.BingSports'
    'Clipchamp.Clipchamp'
    'Microsoft.Copilot'
    'Microsoft.Windows.Ai.Copilot.Provider'
    'Microsoft.549981C3F5F10'              # Cortana
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'                 # Tips
    'microsoft.windowscommunicationsapps'  # Mail and Calendar
    'Microsoft.WindowsMaps'
    'Microsoft.MixedReality.Portal'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.Office.OneNote'
    'Microsoft.OutlookForWindows'
    'Microsoft.People'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.SkypeApp'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MicrosoftStickyNotes'
    'MicrosoftTeams'
    'MSTeams'
    'Microsoft.Todos'
    'Microsoft.Whiteboard'
    'Microsoft.WindowsAlarms'
    'Microsoft.WindowsCamera'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.YourPhone'                  # Phone Link
    'Microsoft.ZuneMusic'                  # Media Player
    'Microsoft.ZuneVideo'                  # Movies & TV
    'Microsoft.Windows.DevHome'
    'MicrosoftCorporationII.QuickAssist'
    'MicrosoftWindows.Client.WebExperience' # Widgets
    'Microsoft.Wallet'
    'Microsoft.3DBuilder'
    'Microsoft.Print3D'
    'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftJournal'
    'Microsoft.Family'
)

Say '--- removing non-gaming apps ---'
$removed = 0; $skipped = 0
foreach ($app in $RemoveApps) {
    if (Test-Protected -Name $app -Patterns $ProtectedApps) {
        Say "PROTECTED, skipping: $app" 'WARN'; $skipped++; continue
    }
    $pkgs = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
    foreach ($pkg in $pkgs) {
        if (Test-Protected -Name $pkg.Name -Patterns $ProtectedApps) {
            Say "PROTECTED, skipping: $($pkg.Name)" 'WARN'; $skipped++; continue
        }
        if ($DryRun) { Say "would remove: $($pkg.Name)"; $removed++; continue }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Say "removed: $($pkg.Name)"; $removed++
        } catch {
            Say "could not remove $($pkg.Name): $($_.Exception.Message)" 'WARN'
        }
    }
    # Also drop the provisioned copy so it doesn't reappear for new users.
    $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $app }
    foreach ($p in $prov) {
        if ($DryRun) { Say "would deprovision: $($p.DisplayName)"; continue }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
            Say "deprovisioned: $($p.DisplayName)"
        } catch { }
    }
}
Say "apps removed: $removed, protected/skipped: $skipped"

# ============================================================== services

# Disabled because a gaming-only VM genuinely never uses them. Windows Search in
# particular is worth killing: indexing a 512 GB disk full of game assets burns
# IO for a feature nobody will ever invoke here.
$DisableServices = @(
    @{ Name = 'DiagTrack';         Why = 'telemetry' }
    @{ Name = 'dmwappushservice';  Why = 'telemetry' }
    @{ Name = 'WSearch';           Why = 'search indexing - pure IO cost here' }
    @{ Name = 'SysMain';           Why = 'superfetch - counterproductive on NVMe' }
    @{ Name = 'Spooler';           Why = 'printing' }
    @{ Name = 'Fax';               Why = 'fax' }
    @{ Name = 'RemoteRegistry';    Why = 'remote registry' }
    @{ Name = 'WerSvc';            Why = 'error reporting' }
    @{ Name = 'MapsBroker';        Why = 'maps' }
    @{ Name = 'RetailDemo';        Why = 'retail demo' }
    @{ Name = 'WalletService';     Why = 'wallet' }
    @{ Name = 'PhoneSvc';          Why = 'phone' }
    @{ Name = 'MessagingService';  Why = 'messaging' }
    @{ Name = 'PimIndexMaintenanceSvc'; Why = 'contacts indexing' }
    @{ Name = 'OneSyncSvc';        Why = 'mail/contacts sync' }
    @{ Name = 'CDPUserSvc';        Why = 'connected devices' }
    @{ Name = 'lfsvc';             Why = 'geolocation' }
)

Say '--- disabling non-gaming services ---'
foreach ($svc in $DisableServices) {
    if (Test-Protected -Name $svc.Name -Patterns $ProtectedServices) {
        Say "PROTECTED, skipping service: $($svc.Name)" 'WARN'; continue
    }
    $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
    if (-not $s) { continue }
    if ($DryRun) { Say "would disable: $($svc.Name) ($($svc.Why))"; continue }
    try {
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
        Say "disabled: $($svc.Name) ($($svc.Why))"
    } catch {
        Say "could not disable $($svc.Name): $($_.Exception.Message)" 'WARN'
    }
}

# ============================================================== registry

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$Why = '')
    if ($DryRun) { Say "would set: $Path\$Name = $Value  ($Why)"; return }
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Say "set: $Name = $Value  ($Why)"
    } catch {
        Say "could not set $Path\${Name}: $($_.Exception.Message)" 'WARN'
    }
}

Say '--- registry: telemetry and suggestions ---'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 'DWord' 'minimise telemetry'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 'DWord' 'stop auto-installing suggested apps'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1 'DWord' 'no tips'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0 'DWord' 'no silent app installs'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 'DWord' 'no Start suggestions'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'DWord' 'no advertising ID'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 'DWord' 'no activity history'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 'DWord' 'no Cortana'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1 'DWord' 'no web results in Start'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 'DWord' 'no widgets'

Say '--- registry: gaming ---'
# Game DVR runs a background recorder during every game. Pure overhead here.
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord' 'no background recording'
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2 'DWord' 'no fullscreen optimisations interference'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 'DWord' 'no Game DVR'
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'DWord' 'Game Mode on'
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 'DWord' 'Game Mode on'

# This one matters for xsync specifically. By default the Guide button opens the
# Xbox Game Bar, which would fight the xsync exit overlay bound to the same
# button. Turning it off leaves the Guide button free for us.
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 'DWord' 'free the Guide button for the xsync exit overlay'

# Hardware-accelerated GPU scheduling: lower latency on the passthrough 4090.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 'DWord' 'hardware GPU scheduling'

# ============================================================== start menu

<#
    Windows 11 pins promotional tiles (WhatsApp, LinkedIn, Spotify and friends)
    that are NOT installed applications - they are cloud-delivered placeholders
    that download on first click. Removing the packages does nothing because
    there are no packages; the pins live in the Start layout and the cloud
    content store. On a gaming appliance nobody should ever see them.
#>
Say '--- clearing promoted Start menu tiles ---'

# Stop new ones arriving.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1 'DWord' 'no cloud-delivered tiles'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 1 'DWord' 'no account-driven tiles'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 0 'DWord' 'no preinstalled promos'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 0 'DWord' 'no OEM promos'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 0 'DWord' 'no content delivery'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0 'DWord' 'no suggested Start apps'

# Clear the pins that are already there. start2.bin holds the current layout;
# removing it makes Windows regenerate a default (unpinned) one at next logon.
if (-not $DryRun) {
    $startBin = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'
    if (Test-Path $startBin) {
        try {
            Remove-Item $startBin -Force -ErrorAction Stop
            Say 'cleared the pinned Start layout'
        } catch {
            Say "could not clear Start layout: $($_.Exception.Message)" 'WARN'
        }
    }
    # Also drop the cached promo manifests so they are not re-pinned.
    $cdm = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\LocalState\Cache'
    if (Test-Path $cdm) {
        Remove-Item "$cdm\*" -Recurse -Force -ErrorAction SilentlyContinue
        Say 'cleared content delivery cache'
    }
} else {
    Say 'would clear start2.bin and the content delivery cache'
}

Say '--- registry: visuals and shell ---'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0 'DWord' 'tidy taskbar'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0 'DWord' 'no widgets button'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 0 'DWord' 'no chat button'
Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String' 'lighter window drags'
# Best performance, minus font smoothing which makes menus unreadable on a TV.
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 'DWord' 'performance visual effects'

# ============================================================== scheduled tasks

$DisableTasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
    '\Microsoft\Windows\Application Experience\StartupAppTask'
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
    '\Microsoft\Windows\Feedback\Siuf\DmClient'
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
    '\Microsoft\Windows\Retail Demo\CleanupOfflineContent'
)

Say '--- disabling telemetry scheduled tasks ---'
foreach ($t in $DisableTasks) {
    if ($DryRun) { Say "would disable task: $t"; continue }
    try {
        $path = Split-Path $t; $name = Split-Path $t -Leaf
        $task = Get-ScheduledTask -TaskPath "$path\" -TaskName $name -ErrorAction SilentlyContinue
        if ($task) { Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null; Say "disabled task: $name" }
    } catch { }
}

# ============================================================== defender

# Not disabling Defender: that's a security decision, and it would also upset the
# Store. Excluding the games directory is the performance win without the risk -
# real-time scanning of multi-hundred-GB game installs is expensive and pointless.
Say '--- Defender exclusion for the games directory ---'
if ($DryRun) {
    Say 'would add exclusion: C:\XboxGames'
} else {
    try {
        Add-MpPreference -ExclusionPath 'C:\XboxGames' -ErrorAction Stop
        Say 'excluded C:\XboxGames from real-time scanning'
    } catch {
        Say "could not add Defender exclusion: $($_.Exception.Message)" 'WARN'
    }
}

# ============================================================== power

Say '--- power ---'
if (-not $DryRun) {
    powercfg /setactive SCHEME_MIN 2>&1 | Out-Null       # High performance
    powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
    powercfg /change monitor-timeout-ac 0 2>&1 | Out-Null
    powercfg /change disk-timeout-ac 0 2>&1 | Out-Null
    powercfg /hibernate off 2>&1 | Out-Null
    Say 'high performance profile, no sleep, no hibernate'
}

Say '=== debloat complete ==='
Say 'Game Pass components were protected and left intact.'
if ($DryRun) { Say 'DRY RUN - no changes were actually made' 'WARN' }
