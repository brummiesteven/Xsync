<#
.SYNOPSIS
    xsync - install the GPU driver inside the guest.

.DESCRIPTION
    A passed-through GPU is useless without its vendor driver. Windows will
    happily boot with the card present but unclaimed, falling back to "Microsoft
    Basic Display Adapter" with the real device sitting at Status: Error. Games
    still launch, but they render through WARP on the CPU - so everything works
    and performance is catastrophic, which is a genuinely confusing failure to
    diagnose from the host side.

    This must run while the GPU is actually attached to the VM (i.e. during a
    play session), because the installer will not install a driver for a device
    that is not present.

.PARAMETER Version
    Driver branch to install. Defaults to whatever the host passed in.

.PARAMETER Url
    Full download URL, overriding the constructed one.
#>
[CmdletBinding()]
param(
    [string]$Version = '596.36',
    [string]$Url = '',
    # Reinstall even when the target version is already present. The installer
    # runs with -clean, so this is also the way to repair corrupted driver or
    # device state rather than merely change version.
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\gpu-driver.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}

function Say {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

Say "=== GPU driver provisioning (target $Version) ==="

# Is a real driver already bound, and is it the one we want?
#
# This used to exit as soon as ANY vendor driver was present, with no version
# comparison at all -- so it could provision a bare guest but could never
# update one. Since there is no way for a Big Picture user to boot Windows and
# run an installer by hand, "can never update" means the guest's driver is
# frozen at whatever shipped on install day, forever.
#
# Windows reports the driver as 32.0.15.9186 while NVIDIA calls the same build
# 591.86. The last five digits of the Windows version are the NVIDIA version
# without its dot, so 9186 -> 591.86 and 596.36 -> ...59636. Comparing on that
# is more reliable than trying to map the whole string.
$gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -notmatch 'Basic Display|VirtIO|Remote' } |
       Select-Object -First 1

if ($gpu -and -not $Force) {
    # Windows reports 32.0.15.9186 for what NVIDIA calls 591.86. The mapping is
    # the last five digits with the dots removed -- 15 and 9186 concatenate to
    # 159186, whose last five are 59186, i.e. 591.86.
    #
    # Matching '(\d{5})$' against the raw string does NOT work: it ends in
    # ".9186", only four digits, so the match always failed and this reported
    # "could not be parsed" every time -- reinstalling the driver on every run
    # instead of only when the version actually differs.
    $installed = ''
    $digits = ($gpu.DriverVersion -replace '[^0-9]', '')
    if ($digits.Length -ge 5) {
        $installed = $digits.Substring($digits.Length - 5).Insert(3, '.')
    }
    $want = $Version
    if ($installed -eq $want) {
        Say "driver $installed is already installed and current"
        Say 'nothing to do'
        exit 0
    }
    if ($installed) {
        Say "driver $installed is installed, target is $want - upgrading"
    } else {
        Say "a vendor driver is active ($($gpu.DriverVersion)) but its version could not be parsed - reinstalling"
    }
} elseif ($gpu -and $Force) {
    Say "-Force given: reinstalling over $($gpu.Name) ($($gpu.DriverVersion))"
}

# Confirm the card is actually attached; installing without it is pointless.
$dev = Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -like '*VEN_10DE*' -and $_.Class -eq 'Display' }
if (-not $dev) {
    Say 'no NVIDIA display device present - is the GPU passed through?' 'ERROR'
    exit 1
}
Say "found device: $($dev.FriendlyName) [$($dev.Status)]"

if (-not $Url) {
    $Url = "https://us.download.nvidia.com/Windows/$Version/$Version-desktop-win10-win11-64bit-international-dch-whql.exe"
}
$installer = "C:\ProgramData\xsync\nvidia-$Version.exe"

if (Test-Path $installer) {
    Say "installer already downloaded: $installer"
} else {
    Say "downloading $Url"
    try {
        # BITS is dramatically faster than Invoke-WebRequest for ~1 GB and does
        # not buffer the whole payload in memory.
        Start-BitsTransfer -Source $Url -Destination $installer -ErrorAction Stop
        Say "downloaded $([math]::Round((Get-Item $installer).Length/1MB)) MB"
    } catch {
        Say "BITS failed ($($_.Exception.Message)); falling back to WebClient" 'WARN'
        try {
            (New-Object Net.WebClient).DownloadFile($Url, $installer)
            Say "downloaded $([math]::Round((Get-Item $installer).Length/1MB)) MB"
        } catch {
            Say "download failed: $($_.Exception.Message)" 'ERROR'
            exit 1
        }
    }
}

Say 'installing silently (this takes several minutes)'
# -s silent, -noreboot so the host keeps control of the VM lifecycle,
# -clean discards any previous profile, -noeula/-nofinish suppress UI.
$p = Start-Process -FilePath $installer `
        -ArgumentList '-s', '-noreboot', '-clean', '-noeula', '-nofinish' `
        -Wait -PassThru
Say "installer exit code: $($p.ExitCode)"

Start-Sleep -Seconds 10
$gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -notmatch 'Basic Display|VirtIO|Remote' } |
       Select-Object -First 1
if ($gpu) {
    Say "SUCCESS: $($gpu.Name) driver $($gpu.DriverVersion)"
    exit 0
}

# Exit code 1 from the NVIDIA installer usually means "reboot required".
Say 'driver not active yet - a guest reboot is probably required' 'WARN'
exit 0
