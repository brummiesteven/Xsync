<#
.SYNOPSIS
    xsync - capture the guest's primary display to a PNG.

.DESCRIPTION
    During a play session the guest drives the TV through the passed-through GPU
    and there is no virtual display, so the host has no way to see what is on
    screen. That makes anything interactive - navigating a game menu, confirming
    a title actually reached gameplay, reading a benchmark result - impossible to
    verify from the outside.

    This grabs the primary display with GDI and writes a PNG the host can pull
    back over the guest agent.

    Caveat: a game running in exclusive fullscreen will usually capture as black,
    because GDI cannot see the flip-model swapchain. Borderless/windowed modes
    capture fine. A black result is therefore informative rather than a failure:
    it means the title is genuinely in exclusive fullscreen on the real GPU.

    Must run in the interactive session - Local System captures a blank desktop.
#>
[CmdletBinding()]
param([string]$Path = 'C:\ProgramData\xsync\screen.png')

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Become DPI aware BEFORE asking how big the screen is.
#
# Without this the capture silently returns the top-left corner of the display
# rather than the display. PowerShell is not DPI aware by default, so
# PrimaryScreen.Bounds hands back DPI-*virtualised* pixels -- on this guest, a
# 3840x2160 TV at 300% scaling reports 1280x720 -- while CopyFromScreen works in
# real, physical pixels. The mismatch means a 1280x720 rectangle is copied from
# the physical origin: a corner of the frame, correctly exposed and perfectly
# in focus, which is exactly why it took a human noticing the car was missing to
# spot it. Two of the screenshots shipped in docs/ were captured this way.
#
# SetProcessDpiAwarenessContext (Win10 1703+) is the right call;
# SetProcessDPIAware is the older one and is enough for a single display. Both
# must run before any Windows Forms screen query, and both are no-ops if the
# process is already aware, so the fallback chain is safe.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class XsyncDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    static readonly IntPtr PerMonitorV2 = new IntPtr(-4);
    public static string Apply() {
        try { if (SetProcessDpiAwarenessContext(PerMonitorV2)) return "per-monitor-v2"; } catch { }
        try { if (SetProcessDPIAware()) return "system"; } catch { }
        return "none";
    }
}
'@
$dpiMode = [XsyncDpi]::Apply()

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$gfx.Dispose()
$bmp.Dispose()

"captured $($bounds.Width)x$($bounds.Height) (dpi awareness: $dpiMode) -> $Path"
