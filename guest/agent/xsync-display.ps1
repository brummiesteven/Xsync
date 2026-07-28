<#
.SYNOPSIS
    xsync - force the guest display into its best mode before a game launches.

.DESCRIPTION
    If the TV is in standby when the VM boots, Windows sees no EDID on the
    passed-through GPU and falls back to a safe 1280x720 desktop. The TV then
    wakes up when the GPU starts driving HDMI, but Windows does not revisit the
    decision - so the desktop, and every game launched on it, stays at 720p.

    The symptom is deeply misleading: everything "works", the GPU is bound
    correctly, the game runs, and a 4090 sits at 40% utilisation producing a
    720p image on a 4K TV. Nothing errors.

    This picks the best available mode for the primary display and applies it.
    Run it after the guest agent confirms a display is attached, and before
    launching a game.

.PARAMETER Width / Height / Refresh
    Target mode. Defaults to the highest resolution the display reports, and
    the highest refresh rate available at that resolution.
#>
[CmdletBinding()]
param(
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Refresh = 0
)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\display.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}
function Say {
    param([string]$m, [string]$l = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $l, $m
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class Disp {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY;
        public int dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);

    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int CDS_UPDATEREGISTRY = 0x01;
    public const int DM_PELSWIDTH = 0x80000, DM_PELSHEIGHT = 0x100000, DM_DISPLAYFREQUENCY = 0x400000;

    public static List<string> Modes() {
        var r = new List<string>();
        var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        for (int i = 0; EnumDisplaySettings(null, i, ref dm); i++)
            if (dm.dmBitsPerPel >= 32)
                r.Add(dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency);
        return r;
    }

    public static string Current() {
        var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm);
        return dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency;
    }

    public static int Set(int w, int h, int hz) {
        var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm);
        dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmDisplayFrequency = hz;
        dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
        return ChangeDisplaySettings(ref dm, CDS_UPDATEREGISTRY);
    }
}
'@

Say "current mode: $([Disp]::Current())"

$modes = [Disp]::Modes() | Sort-Object -Unique
Say "$($modes.Count) modes available"

# Parse into objects so the best can be chosen properly.
$parsed = $modes | ForEach-Object {
    if ($_ -match '^(\d+)x(\d+)@(\d+)$') {
        [pscustomobject]@{ W = [int]$Matches[1]; H = [int]$Matches[2]; Hz = [int]$Matches[3] }
    }
}

if (-not $parsed) { Say 'no usable modes reported - is a display attached?' 'ERROR'; exit 1 }

if ($Width -and $Height) {
    $cands = $parsed | Where-Object { $_.W -eq $Width -and $_.H -eq $Height }
} else {
    $best = $parsed | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
    $cands = $parsed | Where-Object { $_.W -eq $best.W -and $_.H -eq $best.H }
}
if (-not $cands) { Say "requested resolution not available" 'ERROR'; exit 1 }

# Try every refresh rate at the target resolution, highest first, and stop at
# the first one that actually applies.
#
# Taking only the highest and giving up on failure was wrong on the reference
# hardware, and wrong in the most damaging way. The TV advertises 144/120/100 Hz
# at 3840x2160 in its EDID, but the HDMI link negotiates at 600 MHz TMDS
# (HDMI 2.0), so every mode above 60 Hz returns DISP_CHANGE_BADMODE. The script
# would report an error and exit, leaving the desktop on the 1280x720 fallback
# it exists to replace - a 4090 rendering 720p on a 4K TV, with nothing
# obviously broken. See docs/FINDINGS.md, "4K120".
$ordered = if ($Refresh) {
    @($cands | Where-Object { $_.Hz -eq $Refresh }) + @($cands | Where-Object { $_.Hz -ne $Refresh } | Sort-Object Hz -Descending)
} else {
    @($cands | Sort-Object Hz -Descending)
}

Say "modes at $($ordered[0].W)x$($ordered[0].H): $(($ordered | ForEach-Object { $_.Hz }) -join ', ') Hz"

$applied = $null
foreach ($mode in $ordered) {
    Say "trying $($mode.W)x$($mode.H)@$($mode.Hz)"
    $rc = [Disp]::Set($mode.W, $mode.H, $mode.Hz)
    # 0 = DISP_CHANGE_SUCCESSFUL, 1 = DISP_CHANGE_RESTART (applied, wants a reboot)
    if ($rc -eq 0 -or $rc -eq 1) {
        $applied = $mode
        break
    }
    # -2 = DISP_CHANGE_BADMODE: enumerated but not actually achievable over this
    # link. Expected here, and not worth an ERROR on its own.
    Say "  rejected (ChangeDisplaySettings returned $rc)" 'WARN'
}

if ($applied) {
    Start-Sleep -Seconds 3
    Say "SUCCESS - now at $([Disp]::Current())"
    exit 0
} else {
    Say "no mode at $($ordered[0].W)x$($ordered[0].H) could be applied" 'ERROR'
    exit 1
}
