<#
.SYNOPSIS
    xsync - make sure the guest can actually run Game Pass.

.DESCRIPTION
    Runs once at first logon, after the debloat pass. Windows 11 usually ships the
    Xbox app already, but Gaming Services (the component that actually installs and
    launches Game Pass titles) is frequently missing or stale on a fresh image, and
    a missing one produces a uniquely unhelpful error inside the Xbox app.

    This checks each required component and installs whatever is absent, so the
    first thing the user sees is a working Xbox app rather than a broken one.

    Signing in is deliberately left to the user: it needs a Microsoft account and
    likely 2FA, which is not something to automate or store on disk. Everything up
    to that point is handled here.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\provision.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}

function Say {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# Order matters: the Store and App Installer come first because everything after
# them may need the Store to be functional, and winget lives inside App Installer.
$Required = @(
    @{ Name = 'Microsoft.DesktopAppInstaller';  Id = '9NBLGGH4NNS1'; Label = 'App Installer (winget)' }
    @{ Name = 'Microsoft.WindowsStore';         Id = '';             Label = 'Microsoft Store' }
    @{ Name = 'Microsoft.StorePurchaseApp';     Id = '';             Label = 'Store Purchase App' }
    @{ Name = 'Microsoft.XboxIdentityProvider'; Id = '9WZDNCRD1HKW'; Label = 'Xbox Identity Provider' }
    @{ Name = 'Microsoft.GamingApp';            Id = '9MV0B5HZVK9Z'; Label = 'Xbox app' }
    @{ Name = 'Microsoft.GamingServices';       Id = '9MWPM2CQNLHN'; Label = 'Gaming Services' }
    @{ Name = 'Microsoft.Xbox.TCUI';            Id = '';             Label = 'Xbox TCUI' }
)

Say '=== provisioning Game Pass components ==='

# Give the Store stack a moment; at first logon it is often still settling.
Start-Sleep -Seconds 10

<#
    Re-register from the provisioned payload before trying anything else.

    On a fresh image these packages are *provisioned* (staged on disk under
    C:\Program Files\WindowsApps) but not yet *registered* for the user account,
    so Get-AppxPackage reports them missing and the Start menu shows dead tiles.
    Registering needs no network and no winget - which matters, because winget
    ships in Microsoft.DesktopAppInstaller and is itself one of the packages
    that goes missing. Reaching for winget first is therefore circular.
#>
function Register-StagedPackage {
    param([string]$NamePattern)

    $staged = Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like "$NamePattern*" -and $_.Name -match '_(x64|neutral)_' } |
              Sort-Object Name -Descending |
              Select-Object -First 1
    if (-not $staged) { return $false }

    $manifest = Join-Path $staged.FullName 'AppXManifest.xml'
    if (-not (Test-Path $manifest)) { return $false }

    try {
        Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
        return $true
    } catch {
        Say "register failed for ${NamePattern}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

$haveWinget = $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)

foreach ($item in $Required) {
    $pkg = Get-AppxPackage -Name $item.Name -ErrorAction SilentlyContinue
    if ($pkg) {
        Say "$($item.Label) present (v$($pkg.Version))"
        continue
    }

    Say "$($item.Label) missing - registering from staged payload"
    if (Register-StagedPackage -NamePattern $item.Name) {
        $pkg = Get-AppxPackage -Name $item.Name -ErrorAction SilentlyContinue
        if ($pkg) {
            Say "registered $($item.Label) (v$($pkg.Version))"
            continue
        }
    }

    Say "$($item.Label) still missing - trying winget"
    if (-not $haveWinget) {
        $haveWinget = $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)
    }
    if ($haveWinget) {
        try {
            & winget install --id $item.Id --source msstore --accept-package-agreements `
                --accept-source-agreements --silent 2>&1 | Out-Null
            $pkg = Get-AppxPackage -Name $item.Name -ErrorAction SilentlyContinue
            if ($pkg) { Say "installed $($item.Label)" }
            else { Say "winget ran but $($item.Label) still absent" 'WARN' }
        } catch {
            Say "winget failed for $($item.Label): $($_.Exception.Message)" 'WARN'
        }
    } else {
        Say "cannot install $($item.Label) automatically - open the Store and install it manually" 'WARN'
    }
}

# Gaming Services relies on these two services being able to start on demand.
foreach ($svc in @('GamingServices', 'GamingServicesNet')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        try {
            Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop
            Say "$svc set to automatic"
        } catch {
            Say "could not configure ${svc}: $($_.Exception.Message)" 'WARN'
        }
    } else {
        Say "$svc not registered yet (normal until the Xbox app first runs)" 'WARN'
    }
}

# Game Pass installs land here. Pre-creating it means the host-side enumerator has
# something to look at even before the first game is installed.
if (-not (Test-Path 'C:\XboxGames')) {
    New-Item -ItemType Directory -Path 'C:\XboxGames' -Force | Out-Null
    Say 'created C:\XboxGames'
}

Say '=== provisioning complete ==='
Say 'Remaining manual step: sign into the Xbox app with your Microsoft account.'
