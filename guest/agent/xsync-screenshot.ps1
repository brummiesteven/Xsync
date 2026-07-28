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

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$gfx.Dispose()
$bmp.Dispose()

"captured $($bounds.Width)x$($bounds.Height) -> $Path"
