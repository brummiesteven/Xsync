<#
.SYNOPSIS
    xsync - enable the Xbox Full Screen Experience ("Xbox mode") in the guest.

.DESCRIPTION
    FSE is the console-style, gamepad-navigable Xbox shell Microsoft ships on the
    ROG Xbox Ally handhelds. On a machine whose only job is running Game Pass
    titles on a TV, it is a far better fit than the Windows desktop: no taskbar,
    no Explorer, controller-first navigation, and a home experience that looks
    like a console rather than a PC that happens to be in the living room.

    Implemented natively rather than shelling out to a third-party installer, so
    there is no external binary to trust and every change is visible here.

    Two independent pieces are required:

      1. Feature flags, toggled through ntdll!RtlSetFeatureConfigurations - the
         same API ViVeTool drives. Applied to both Runtime and Boot config.
      2. DeviceForm = 46 ("Gaming handheld") under the OEM key. Without it
         Windows offers only a bare "enable Xbox mode" toggle, with no home-app
         picker and no boot-to-Xbox option - which is precisely the part that
         makes this useful for a VM that should come up as a console.

    The panel-dimension spoofing that older guides describe (a kernel driver,
    Secure Boot off, test signing on) is NOT needed on current builds, and would
    break anti-cheat besides. It is deliberately not done here.

.PARAMETER Disable
    Revert: reset the feature flags and remove DeviceForm / GamingHomeApp.
#>
[CmdletBinding()]
param([switch]$Disable)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\fse.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}
function Say {
    param([string]$m, [string]$l = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $l, $m
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# Feature ids depend on the build, and using the wrong set is silently useless.
#
#   Legacy  26200.7015 - 26200.8327 : 52580392, 50902630
#           ...and a non-handheld ALSO needs a panel-dimension override to pass
#           the activation check, which this script does not do.
#   Native  26100/26200 >= .8328    : 52580392, 50902630, 59765208
#           no panel override needed.
#
# 58989070 only unhides the Settings page on retail .8328+; the reference tool
# never applies it.
$Build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -EA SilentlyContinue).CurrentBuildNumber
$UBR   = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -EA SilentlyContinue).UBR
$IsNative = ($Build -ge 26100 -and $UBR -ge 8328)

if ($IsNative) {
    $FeatureIds = @(52580392, 50902630, 59765208)
} else {
    $FeatureIds = @(52580392, 50902630)
}

$XboxAumid = 'Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ViVe {
    [StructLayout(LayoutKind.Sequential)]
    public struct FeatureUpdate {
        public uint FeatureId;
        public uint Priority;
        public uint EnabledState;
        public uint EnabledStateOptions;
        public uint Variant;
        public uint VariantPayloadKind;
        public uint VariantPayload;
        public uint Operation;
    }

    [DllImport("ntdll.dll")]
    private static extern int RtlSetFeatureConfigurations(
        ref ulong changeStamp, uint configType, FeatureUpdate[] updates, uint count);

    // configType: 0 = Boot, 1 = Runtime
    // EnabledState: 0 default, 1 disabled, 2 enabled
    // Operation: 1 FeatureState, 2 VariantState, 4 ResetState
    // Priority: 8 = User
    public static int Apply(uint id, uint state, uint operation, uint configType) {
        ulong stamp = 0;
        var u = new FeatureUpdate {
            FeatureId = id, Priority = 8, EnabledState = state,
            EnabledStateOptions = 0, Variant = 0, VariantPayloadKind = 0,
            VariantPayload = 0, Operation = operation
        };
        return RtlSetFeatureConfigurations(ref stamp, configType, new[]{u}, 1);
    }
}
'@

# Feature ids are stored in the registry under an OBFUSCATED form of the id.
# This is the transform the feature manager uses; without it the Boot store
# entries are written under keys Windows never looks at.
function Get-ObfuscatedId {
    param([uint32]$Id)
    $m = [uint32]::MaxValue
    $x = [uint32](($Id -bxor 0x74161A4E) -band $m)
    $x = [uint32]((($x -shr 16) -bor ($x -shl 16)) -band $m)
    $x = [uint32](((($x -band 0xFF00FF00) -shr 8) -bor (($x -band 0x00FF00FF) -shl 8)) -band $m)
    $x = [uint32](($x -bxor 0x8FB23D4F) -band $m)
    $x = [uint32]((($x -shr 31) -bor ($x -shl 1)) -band $m)
    return [uint32](($x -bxor 0x833EA8FF) -band $m)
}

# Apply a feature to BOTH stores -- by two different mechanisms, which is the
# whole point.
#
# RtlSetFeatureConfigurations only accepts the RUNTIME store. Passing
# configType 0 (Boot) is invalid and returns STATUS_INVALID_PARAMETER. The
# previous version of this looped `foreach ($cfg in 0, 1)` and called the API
# for both, which is why exactly half the calls failed:
#
#   feature 52580392 cfg=0 -> NTSTATUS 0xC000000D
#
# Runtime-only also means nothing survived a reboot, so the feature could never
# actually take effect. The Boot store is a registry hive, not an API.
function Set-Feature {
    param([uint32]$Id, [switch]$Reset)
    $ok = $true

    # --- runtime store: the ntdll call, configType 1 ONLY ---
    $op    = if ($Reset) { 4 } else { 3 }   # 4 ResetState, 3 FeatureState|VariantState
    $state = if ($Reset) { 0 } else { 2 }   # 0 default, 2 enabled
    $rc = [ViVe]::Apply($Id, $state, $op, 1)
    if ($rc -ne 0) {
        $ok = $false
        Say "feature $Id runtime -> NTSTATUS 0x$('{0:X8}' -f $rc)" 'ERROR'
    }

    # --- boot store: registry under the obfuscated id ---
    $obf  = Get-ObfuscatedId -Id $Id
    $base = "HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\$obf"
    try {
        if ($Reset) {
            Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            if (-not (Test-Path $base)) { New-Item -Path $base -Force -ErrorAction Stop | Out-Null }
            foreach ($kv in @{ EnabledState = 2; EnabledStateOptions = 0; Variant = 0
                               VariantPayload = 0; VariantPayloadKind = 0 }.GetEnumerator()) {
                New-ItemProperty -Path $base -Name $kv.Key -Value $kv.Value `
                    -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            }
        }
    } catch {
        $ok = $false
        Say "feature $Id boot store -> $($_.Exception.Message)" 'ERROR'
    }

    return $ok
}

# Boot-store overrides are ignored entirely on the next boot if the boot status
# data file does not exist. A debloated guest is a prime candidate for that,
# because the file is normally created by telemetry -- and xsync-debloat.ps1
# disables DiagTrack. So create it if it is missing, then flag a pending change.
function Set-BootStatusPending {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class XsyncBsd {
    [DllImport("ntdll.dll")]
    public static extern int RtlSetSystemBootStatus(int type, ref int data, int size, IntPtr ret);
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    public static extern int RtlCreateBootStatusDataFile(string path);
}
'@ -ErrorAction SilentlyContinue
        $v = 1   # BootPending
        $rc = [XsyncBsd]::RtlSetSystemBootStatus(17, [ref]$v, 4, [IntPtr]::Zero)
        if ($rc -eq [int]0xC0000034) {   # STATUS_OBJECT_NAME_NOT_FOUND
            Say 'boot status data file missing (DiagTrack disabled?) - creating it'
            [XsyncBsd]::RtlCreateBootStatusDataFile($null) | Out-Null
            $rc = [XsyncBsd]::RtlSetSystemBootStatus(17, [ref]$v, 4, [IntPtr]::Zero)
        }
        if ($rc -ne 0) { Say "boot status update -> 0x$('{0:X8}' -f $rc)" 'WARN' }
        else { Say 'boot status flagged pending' }
    } catch {
        Say "could not update boot status: $($_.Exception.Message)" 'WARN'
    }
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

$OemKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\OEM'

# Per-user settings must land in the hive of the person who actually uses this
# machine, which is NOT what HKCU: means here.
#
# The host drives this script over qemu-guest-agent, so it runs as
# NT AUTHORITY\SYSTEM and HKCU: resolves to HKU\S-1-5-18 -- Local System's own
# hive. Writing GamingHomeApp there succeeds, logs success, and is invisible to
# the user: the Xbox home-app picker stays unset and FSE comes up with nothing
# selected, with nothing in any log to say why.
#
# Resolve the real account instead. LastLoggedOnUserSID is what LogonUI records
# and it survives the user not being logged in right now, which matters because
# maintenance runs against a guest nobody is sitting at. Fall back to HKCU: only
# when we are genuinely running as that user (someone ran this by hand).
function Get-UserHive {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().Name -ne 'NT AUTHORITY\SYSTEM') {
        return 'HKCU:'
    }
    $sid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' `
            -Name LastLoggedOnUserSID -ErrorAction SilentlyContinue).LastLoggedOnUserSID
    if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) { return "Registry::HKEY_USERS\$sid" }
    Say 'could not resolve the interactive user hive - falling back to HKCU (SYSTEM)' 'WARN'
    return 'HKCU:'
}

$UserHive  = Get-UserHive
$GamingKey = "$UserHive\Software\Microsoft\Windows\CurrentVersion\GamingConfiguration"
$DialogKey = "$GamingKey\SystemDialogResults"

if ($Disable) {
    Say '=== reverting Xbox Full Screen Experience ==='
    foreach ($id in $FeatureIds) { Set-Feature -Id $id -Reset | Out-Null; Say "reset feature $id" }
    Remove-ItemProperty -Path $OemKey -Name 'DeviceForm' -ErrorAction SilentlyContinue
    Set-Reg $GamingKey 'GamingHomeApp' '' 'String'
    Say 'reverted - reboot to complete'
    exit 0
}

Say '=== enabling Xbox Full Screen Experience ==='

$build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
$ubr   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
Say "Windows build $build.$ubr"

# -AllUsers is load-bearing, not defensive.
#
# This script is driven from the host over qemu-guest-agent, which runs it as
# NT AUTHORITY\SYSTEM. AppX packages are registered per user, so a bare
# Get-AppxPackage asks "is the Xbox app installed for SYSTEM?" -- and the answer
# is always no, on every machine, however healthy.
#
# The result was a script that refused to do anything and blamed the guest:
# "Xbox app is not installed" on a VM that had been installing and running Game
# Pass titles through that exact app. The precondition was never testable in the
# context it runs in, so FSE had never once been applied.
#
# xsync-debloat.ps1 already passes -AllUsers, and xsync-agent.ps1 documents this
# same trap, so this was the one place that missed the lesson.
if (-not (Get-AppxPackage -AllUsers -Name 'Microsoft.GamingApp' -ErrorAction SilentlyContinue)) {
    Say 'Xbox app is not installed for any user - FSE has nothing to host' 'ERROR'
    exit 1
}

Say '--- feature flags ---'
foreach ($id in $FeatureIds) {
    # Reset first, exactly as the reference implementation does, so a stale
    # user-priority value cannot mask the new one.
    Set-Feature -Id $id -Reset | Out-Null
    if (Set-Feature -Id $id) { Say "enabled feature $id" }
}

Say '--- device form ---'
# 46 = "Gaming handheld". This is what unlocks the home-app picker and the
# boot-to-Xbox toggle; without it Windows shows a cut-down PC version of Xbox
# mode that cannot be made the startup experience.
Set-Reg $OemKey 'DeviceForm' 46
Say 'DeviceForm = 46 (gaming handheld)'

Say '--- gaming configuration ---'
Set-Reg $GamingKey 'GamingHomeApp' $XboxAumid 'String'
Set-Reg $GamingKey 'ShowOnDesktopSwitcher' 1
# Inverted polarity: 1 SUPPRESSES the confirmation dialogs. An unattended VM
# must never stop on "Switching to Xbox mode - are you sure?".
Set-Reg $DialogKey 'EnterGamingPostureConfirmation_NoReboot' 1
Set-Reg $DialogKey 'ExitGamingPostureConfirmation_Minimal' 1
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'TaskSwitcherNexusInjectionEnabled' 1
Say "GamingHomeApp = $XboxAumid"

Say '=== done ==='
Say 'A guest reboot is required for the feature flags to take effect.'
Say 'After rebooting, Xbox mode can be toggled with Win+F11.'
