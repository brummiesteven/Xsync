<#
.SYNOPSIS
    xsync - make the guest desktop invisible, so the TV shows black until a game
    appears.

.DESCRIPTION
    The handoff gives the TV to the VM well before there is anything worth
    looking at. Between the GPU changing hands and the game window opening the
    user sees, in order: the OVMF boot menu, the Windows boot animation, the
    sign-in spinner, and finally a desktop complete with wallpaper, icons and a
    taskbar. None of that is part of the experience being sold.

    There is no way to keep the host session on screen during this. There is one
    GPU and one display, so the moment the 4090 is unbound from nvidia the host
    can draw nothing at all. What CAN be done is make every one of those stages
    render as black, so the TV simply shows nothing until the game takes over.
    Visually that is the same outcome, and it costs nothing in risk.

    This script handles the guest-side stages. The OVMF boot menu is a domain
    XML setting and is handled by tools/xsync-setup.

    Also disables Windows' boot failure UI. xsync destroys the VM in some
    recovery paths, and by default the next boot would show "Windows did not
    shut down correctly" and sit on a recovery screen waiting for input that
    nobody is there to give - on a machine with no keyboard in front of it.

.PARAMETER Revert
    Put everything back: wallpaper, taskbar, boot animation, recovery UI.

.PARAMETER NoRestartExplorer
    Apply registry changes without restarting Explorer. The taskbar and desktop
    icon changes will not take effect until the next sign-in.
#>
[CmdletBinding()]
param(
    [switch]$Revert,
    [switch]$NoRestartExplorer,
    # Opt in to auto-hiding the taskbar. Off by default because a revealed
    # auto-hide taskbar draws on top of borderless-fullscreen games.
    [switch]$AutoHideTaskbar
)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\appearance.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}
function Say {
    param([string]$m, [string]$l = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $l, $m
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Set by any failure the caller must know about. firstboot treats a non-zero
# exit as a failed step, which is the only way these get noticed at all.
$Failed = $false

Say "=== xsync appearance ($(if ($Revert) { 'revert' } else { 'apply' })) ==="
Say "running as $($env:USERNAME), admin=$IsAdmin"

function Set-Reg {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord',
        [string]$What = ''
    )
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        if ($What) { Say "  $What" }
        return $true
    } catch {
        Say "  FAILED ${What}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Desktop: solid black, no icons
# ---------------------------------------------------------------------------
Say '--- desktop ---'

if ($Revert) {
    Set-Reg 'HKCU:\Control Panel\Desktop' 'Wallpaper' 'C:\Windows\Web\Wallpaper\Windows\img0.jpg' 'String' 'wallpaper restored'
    Set-Reg 'HKCU:\Control Panel\Colors' 'Background' '0 0 0' 'String' 'background colour left black'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideIcons' 0 'DWord' 'desktop icons shown'
} else {
    # An empty wallpaper path makes Windows paint COLOR_BACKGROUND instead, so
    # the two settings together give a genuinely black desktop rather than a
    # black image that still flashes the default one while it loads.
    Set-Reg 'HKCU:\Control Panel\Desktop' 'Wallpaper' '' 'String' 'no wallpaper image'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'WallpaperStyle' '0' 'String' 'wallpaper style centred'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'TileWallpaper' '0' 'String' 'no tiling'
    Set-Reg 'HKCU:\Control Panel\Colors' 'Background' '0 0 0' 'String' 'desktop colour black'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideIcons' 1 'DWord' 'desktop icons hidden'
}

# ---------------------------------------------------------------------------
# Taskbar: auto-hide
# ---------------------------------------------------------------------------
Say '--- taskbar ---'

# Auto-hide is OFF by default, and that is deliberate.
#
# Auto-hide seems like the obvious way to get a clean screen, and it is worse
# than useless here: a revealed auto-hide taskbar is drawn TOPMOST, so it
# renders over a borderless-fullscreen game. Enabling it put the Start button
# and the clock on top of Forza's title screen. A normal taskbar is an ordinary
# window that a fullscreen game covers completely, and the only time it is
# visible at all is the few seconds of black desktop between the handoff and
# the game appearing -- which is a far better trade.
#
# The flag itself lives in bit 0 of byte 8 of an opaque binary blob. There is
# no supported API for it and no separate DWORD.
$stuck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
try {
    $settings = (Get-ItemProperty -Path $stuck -Name 'Settings' -ErrorAction Stop).Settings
    if ($settings -and $settings.Length -gt 8) {
        $before = $settings[8]
        if ($AutoHideTaskbar -and -not $Revert) {
            $settings[8] = $settings[8] -bor 0x01
        } else {
            $settings[8] = $settings[8] -band 0xFE
        }
        Set-ItemProperty -Path $stuck -Name 'Settings' -Value $settings -ErrorAction Stop
        Say ("  taskbar auto-hide {0} (byte8 0x{1:X2} -> 0x{2:X2})" -f `
            $(if ($AutoHideTaskbar -and -not $Revert) { 'ON - may draw over games' } else { 'off' }), `
            $before, $settings[8])
    } else {
        Say '  StuckRects3 Settings missing or too short - skipping auto-hide' 'WARN'
    }
} catch {
    Say "  could not read StuckRects3: $($_.Exception.Message)" 'WARN'
}

# Strip the remaining clutter so that if the taskbar is ever revealed it is at
# least not advertising anything.
if (-not $Revert) {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    # Widgets: on 25H2 the per-user TaskbarDa value is write-protected and
    # setting it fails with "unauthorized operation" even from an elevated
    # session. The machine policy is the supported route and is not protected.
    if ($IsAdmin) {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 'DWord' 'widgets disabled by policy'
    }
    Set-Reg $adv 'TaskbarDa'  0 'DWord' 'no widgets button'
    Set-Reg $adv 'TaskbarMn'  0 'DWord' 'no chat button'
    Set-Reg $adv 'ShowTaskViewButton' 0 'DWord' 'no task view button'
    Set-Reg $adv 'TaskbarAl'  0 'DWord' 'start button left aligned'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0 'DWord' 'no search box'
}

# ---------------------------------------------------------------------------
# Notifications: nothing pops up over a game
# ---------------------------------------------------------------------------
Say '--- notifications ---'
$toastVal = if ($Revert) { 1 } else { 0 }
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' $toastVal 'DWord' "toasts enabled=$toastVal"
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' $toastVal 'DWord' "global toasts enabled=$toastVal"

# ---------------------------------------------------------------------------
# Sign-in: no lock screen, no logon background, no welcome animation
# ---------------------------------------------------------------------------
if ($IsAdmin) {
    Say '--- sign-in ---'
    if ($Revert) {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 0 'DWord' 'lock screen restored'
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DisableLogonBackgroundImage' 0 'DWord' 'logon background restored'
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 1 'DWord' 'sign-in animation restored'
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableStatusMessages' 0 'DWord' 'status messages restored'
    } else {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1 'DWord' 'lock screen disabled'
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DisableLogonBackgroundImage' 1 'DWord' 'logon background image disabled'
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 0 'DWord' 'sign-in animation disabled'
        # EnableFirstLogonAnimation only covers the *first* sign-in. The
        # "Welcome" / "Restarting" status text under the spinner is separate,
        # and this is the policy that removes it. Without it the TV shows the
        # account name and a spinner on black for the last ten seconds or so of
        # every boot.
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableStatusMessages' 1 'DWord' 'boot/logon status messages disabled'
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 0 'DWord' 'verbose status off'
        # LogonUI runs under the default profile, so its background colour comes
        # from HKU\.DEFAULT rather than from the user being logged in.
        Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Colors' 'Background' '0 0 0' 'String' 'logon screen colour black'

        # DisableLogonBackgroundImage alone does NOT give a black logon screen --
        # it gives the *accent colour*, which is why the sign-in tile still read
        # as dark grey rather than black in the boot captures. These machine
        # policies are what actually force black; per-user accent settings are
        # not consulted by LogonUI.
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'PersonalColors_Background' '#000000' 'String' 'logon background forced black'
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'PersonalColors_Accent'     '#000000' 'String' 'logon accent forced black'

        # Removes the account name from the sign-in screen. The generic glyph,
        # spinner and "Welcome" survive -- those cannot be removed on Windows 11
        # Pro at all. HideAutoLogonUI, the actual kill switch, requires
        # Enterprise/Education/IoT Enterprise.
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'dontdisplaylastusername' 1 'DWord' 'account name hidden at sign-in'
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DisableAcrylicBackgroundOnLogon' 1 'DWord' 'no acrylic blur at sign-in'
        # Harmless on Pro (ignored), correct on Enterprise/IoT. Costs nothing.
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon' 'HideAutoLogonUI' 1 'DWord' 'autologon UI hidden (Enterprise/IoT only)'
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon' 'AnimationDisabled' 1 'DWord' 'logon animation disabled (Enterprise/IoT only)'
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation' 'DisableStartupSound' 1 'DWord' 'startup sound disabled'
    }
} else {
    Say '--- sign-in --- skipped, needs admin' 'WARN'
}

# ---------------------------------------------------------------------------
# Boot: no animation, no recovery screen
# ---------------------------------------------------------------------------
if ($IsAdmin) {
    Say '--- boot ---'
    # Not named $Args: that collides with PowerShell's automatic variable.
    function Bcd {
        param([string[]]$BcdArgs, [string]$What, [switch]$Critical)
        $out = & bcdedit.exe @BcdArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Say "  $What"
        } elseif ($Critical) {
            # Not a warning. Without these two the next boot after any unclean
            # shutdown - which xsync performs deliberately in some recovery
            # paths - stops on a recovery screen that needs a keypress, on a
            # machine with no keyboard in front of it. The appliance is then
            # bricked until someone carries a keyboard to the TV.
            Say "  FAILED ${What}: $out" 'ERROR'
            $script:Failed = $true
        } else {
            Say "  FAILED ${What}: $out" 'WARN'
        }
    }
    if ($Revert) {
        Bcd @('/deletevalue', '{globalsettings}', 'bootuxdisabled') 'boot animation restored'
        Bcd @('/deletevalue', '{current}', 'quietboot')             'quiet boot off'
        Bcd @('/set', '{current}', 'bootstatuspolicy', 'DisplayAllFailures') 'boot failure display restored'
        Bcd @('/set', '{current}', 'recoveryenabled', 'Yes')        'recovery re-enabled'
    } else {
        Bcd @('/set', '{globalsettings}', 'bootuxdisabled', 'on')   'boot animation disabled'
        Bcd @('/set', '{current}', 'quietboot', 'on')               'quiet boot enabled'
        # Without this, any unclean shutdown - including the ones xsync performs
        # deliberately when a session has to be torn down - parks the next boot
        # on a recovery screen that only a keyboard can dismiss.
        Bcd @('/set', '{current}', 'bootstatuspolicy', 'ignoreallfailures') 'boot failure screens suppressed' -Critical
        Bcd @('/set', '{current}', 'recoveryenabled', 'No')         'automatic repair disabled' -Critical
        Bcd @('/timeout', '0')                                      'boot menu timeout 0'
    }
} else {
    Say '--- boot --- skipped, needs admin' 'WARN'
}

# ---------------------------------------------------------------------------
# Apply now
# ---------------------------------------------------------------------------
Say '--- applying ---'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class XsyncAppearance {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SystemParametersInfoW(uint action, uint param, string pv, uint winIni);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetSysColors(int count, int[] elements, int[] colors);
    public const uint SPI_SETDESKWALLPAPER = 0x0014;
    public const uint SPIF_UPDATEINIFILE = 0x01;
    public const uint SPIF_SENDCHANGE = 0x02;
    public const int COLOR_BACKGROUND = 1;
}
'@ -ErrorAction SilentlyContinue

try {
    $paper = if ($Revert) { 'C:\Windows\Web\Wallpaper\Windows\img0.jpg' } else { '' }
    [XsyncAppearance]::SystemParametersInfoW(
        [XsyncAppearance]::SPI_SETDESKWALLPAPER, 0, $paper,
        [XsyncAppearance]::SPIF_UPDATEINIFILE -bor [XsyncAppearance]::SPIF_SENDCHANGE) | Out-Null
    [XsyncAppearance]::SetSysColors(1, @([XsyncAppearance]::COLOR_BACKGROUND), @(0x000000)) | Out-Null
    Say '  wallpaper and desktop colour applied live'
} catch {
    Say "  live apply failed (registry values still set): $($_.Exception.Message)" 'WARN'
}

if ($NoRestartExplorer) {
    Say '  explorer left alone - taskbar changes apply at next sign-in'
} else {
    try {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Say '  explorer restarted'
        # Windows respawns Explorer on its own; starting a second one races it.
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
            Say '  explorer did not respawn - started manually'
        }
    } catch {
        Say "  could not restart explorer: $($_.Exception.Message)" 'WARN'
    }
}

if ($Failed) {
    Say '=== done, WITH FAILURES (see ERROR lines above) ===' 'ERROR'
    exit 1
}
Say '=== done ==='
exit 0
