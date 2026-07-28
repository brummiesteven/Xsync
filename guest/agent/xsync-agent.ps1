<#
.SYNOPSIS
    xsync guest agent - the Windows half of xsync.

.DESCRIPTION
    Enumerates installed Xbox Game Pass titles, launches them, watches for exit,
    and provides the Guide-button exit overlay that stands in for the Steam
    overlay (unavailable in handoff mode, because the host session is stopped).

    Deliberately PowerShell rather than a compiled binary: no Windows build
    toolchain is needed to work on xsync, and the XInput calls use inline C#
    compiled by the .NET that Windows already ships.

    Invoked by the host over qemu-guest-agent (see host/bin/guest.sh).

.PARAMETER Action
    enumerate  print installed games as JSON
    launch     launch a game (or the Xbox app) and start the watcher
    status     print JSON: whether a game is currently running
    downloading  'yes' if a Game Pass download/install is in progress
    watch      blocking watcher loop; shuts Windows down when play ends
    install    register the agent for autostart

.PARAMETER GameId
    Game slug from `enumerate`, or "xbox-app" for the launcher itself.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('enumerate', 'launch', 'status', 'watch', 'install', 'run-user', 'downloading', 'overlay')]
    [string]$Action,

    [string]$GameId = 'xbox-app',

    # For -Action run-user: the script to execute in the interactive session.
    [string]$ScriptPath = '',

    # Seconds the Guide button must be held to raise the exit overlay.
    [int]$GuideHoldSeconds = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$XsyncDir   = 'C:\ProgramData\xsync'
$StateFile  = Join-Path $XsyncDir 'state.json'
$LogFile    = Join-Path $XsyncDir 'agent.log'
$GamesRoot  = 'C:\XboxGames'

if (-not (Test-Path $XsyncDir)) { New-Item -ItemType Directory -Path $XsyncDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # Retry, because several xsync processes write this file at once and
    # Add-Content fails outright when another holds it. With
    # -ErrorAction SilentlyContinue that failure was invisible, so log lines
    # simply went missing -- and a missing line reads exactly like code that
    # never ran. That cost hours of wrong diagnosis: the launch DID start the
    # watcher, its log line just lost a race with the watcher's own writes.
    for ($i = 0; $i -lt 12; $i++) {
        try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop; break }
        catch { Start-Sleep -Milliseconds 40 }
    }
    Write-Verbose $line
}

# Stable, filesystem- and Steam-safe id derived from the display name.
function ConvertTo-Slug {
    param([string]$Name)
    $s = $Name.ToLowerInvariant()
    $s = $s -replace "[''`":.,!?()\[\]]", ''
    $s = $s -replace '[^a-z0-9]+', '-'
    return $s.Trim('-')
}

# ---------------------------------------------------------------- enumerate

<#
    Game Pass titles install to C:\XboxGames\<Title>\Content\, each with a
    MicrosoftGame.config naming the package identity and display name. That file
    is the authoritative source; Get-AppxPackage then resolves the package family
    name so we can build a launchable AUMID.
#>
function Get-InstalledXboxGames {
    $games = @()
    if (-not (Test-Path $GamesRoot)) {
        Write-Log "no $GamesRoot - nothing installed yet"
        return $games
    }

    foreach ($dir in Get-ChildItem -Path $GamesRoot -Directory -ErrorAction SilentlyContinue) {
        $cfgPath = Join-Path $dir.FullName 'Content\MicrosoftGame.config'
        if (-not (Test-Path $cfgPath)) { continue }

        try {
            [xml]$cfg = Get-Content $cfgPath -Raw -ErrorAction Stop
        } catch {
            Write-Log "unreadable config in $($dir.Name): $_" 'WARN'
            continue
        }

        $identity = $null; $display = $dir.Name; $exeName = $null
        try { $identity = $cfg.Game.Identity.Name } catch { }
        try {
            if ($cfg.Game.ShellVisuals -and $cfg.Game.ShellVisuals.DefaultDisplayName) {
                $display = $cfg.Game.ShellVisuals.DefaultDisplayName
            }
        } catch { }
        try {
            $exe = $cfg.Game.ExecutableList.Executable
            if ($exe -is [array]) { $exeName = $exe[0].Name } else { $exeName = $exe.Name }
        } catch { }

        if (-not $identity) {
            Write-Log "no package identity for $($dir.Name) - skipping" 'WARN'
            continue
        }

        # Resolve the package family name and app id to build the AUMID.
        $aumid = $null
        try {
            $pkg = Get-AppxPackage -Name $identity -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pkg) {
                $appId = 'App'
                try {
                    $manifest = Get-AppxPackageManifest -Package $pkg.PackageFullName -ErrorAction Stop
                    $app = $manifest.Package.Applications.Application
                    if ($app -is [array]) { $appId = $app[0].Id } else { $appId = $app.Id }
                } catch {
                    Write-Log "manifest unreadable for $identity, assuming App" 'WARN'
                }
                $aumid = "{0}!{1}" -f $pkg.PackageFamilyName, $appId
            }
        } catch {
            Write-Log "AppX lookup failed for ${identity}: $_" 'WARN'
        }

        if (-not $aumid) {
            Write-Log "no AUMID for $display - not launchable, skipping" 'WARN'
            continue
        }

        $games += [pscustomobject]@{
            id            = ConvertTo-Slug $display
            name          = $display
            aumid         = $aumid
            install_path  = $dir.FullName
            executable    = $exeName
        }
    }

    # Second source: games the Store installed outside C:\XboxGames.
    #
    # 'Sunset Overdrive' is installed, 28 GB of it, and was invisible to every
    # part of this project. It is a UWP-era title, so it lands in WindowsApps as
    # Microsoft.Sunflower with entry point SunsetGame.GameView -- no
    # MicrosoftGame.config, no GameLaunchHelper.exe wrapper, and no entry in the
    # GamingServices package repository. All three of the places we looked.
    #
    # There is no flag in the manifest that says "this is a game", so the
    # discriminator is size. Measured on a real library: every game was 4.9 GB or
    # larger (Conker 4.9, Sunset 28, Oblivion 121, Forza 149) and every inbox app
    # was under 900 MB (Photos 878, Snipping Tool 533, Paint 417, Xbox app 360).
    # A 1 GB floor separates them with an order of magnitude to spare.
    #
    # Crude, and honest about being crude: a sub-gigabyte indie title would be
    # missed. That is the failure this trades for, and it is the safer direction
    # -- a missing shortcut is an annoyance, Paint appearing in Steam is nonsense.
    $minBytes = 1GB
    if ($env:XSYNC_MIN_GAME_BYTES) { $minBytes = [int64]$env:XSYNC_MIN_GAME_BYTES }
    $seen = @{}
    foreach ($g in $games) { $seen[$g.aumid] = $true }

    foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
        if ($pkg.IsFramework) { continue }
        if (-not $pkg.InstallLocation) { continue }
        # System-signed packages are Windows itself, never a game.
        if ($pkg.SignatureKind -eq 'System') { continue }
        if (-not (Test-Path $pkg.InstallLocation)) { continue }

        $mf = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
        if (-not (Test-Path $mf)) { continue }

        $size = 0
        try {
            $size = (Get-ChildItem $pkg.InstallLocation -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Measure-Object Length -Sum).Sum
        } catch { }
        if (-not $size -or $size -lt $minBytes) { continue }

        $appId = $null; $display = $null; $exeName = $null
        try {
            [xml]$x = Get-Content $mf -Raw -ErrorAction Stop
            $display = $x.Package.Properties.DisplayName
            foreach ($a in @($x.Package.Applications.Application)) {
                $appId = $a.Id; $exeName = $a.Executable; break
            }
        } catch {
            Write-Log "manifest unreadable for $($pkg.Name) - skipping" 'WARN'
            continue
        }
        if (-not $appId) { continue }

        $aumid = "{0}!{1}" -f $pkg.PackageFamilyName, $appId
        if ($seen.ContainsKey($aumid)) { continue }

        # DisplayName is often 'ms-resource:...' which is a lookup key, not a
        # name. Nothing readable is better than a shortcut called ms-resource.
        if (-not $display -or $display -like 'ms-resource:*') { $display = $pkg.Name }

        $seen[$aumid] = $true
        $games += [pscustomobject]@{
            id            = ConvertTo-Slug $display
            name          = $display
            aumid         = $aumid
            install_path  = $pkg.InstallLocation
            executable    = $exeName
        }
        Write-Log ("found Store-installed game: {0} ({1:N1} GB)" -f $display, ($size / 1GB))
    }

    Write-Log "enumerated $($games.Count) game(s)"
    return $games
}

# ---------------------------------------------------------------- launch

function Start-XboxApp {
    Write-Log 'launching the Xbox app'
    # shell:appsFolder is how the shell itself launches packaged apps.
    Start-Process 'explorer.exe' -ArgumentList 'shell:appsFolder\Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'
}

function Start-XboxGame {
    param([string]$Id)

    $game = Get-InstalledXboxGames | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $game) {
        Write-Log "unknown game id '$Id' - falling back to the Xbox app" 'ERROR'
        Start-XboxApp
        return $null
    }

    Write-Log "launching $($game.name) [$($game.aumid)]"
    Start-Process 'explorer.exe' -ArgumentList ("shell:appsFolder\{0}" -f $game.aumid)
    return $game
}

# A Game Pass title runs from its own install directory, so "is it still
# running" is answered by looking for any process whose image lives there.
# NOTE: callers must wrap this in @(...) before touching .Count.
#
# PowerShell unrolls arrays on output, so `return @(...)` with a single match
# hands back a bare Process object, and under `Set-StrictMode -Version Latest`
# reading .Count on that throws "The property 'Count' cannot be found".
#
# This is not academic: it is exactly what broke session shutdown. Most games
# are a single process, so the watcher threw on its first check, died silently,
# and the VM then held the GPU indefinitely after the game exited.
function Get-GameProcesses {
    param([string]$InstallPath, [string]$Executable = '')

    # Match on the executable name first.
    #
    # Path matching alone is not enough: the host queries this over
    # qemu-guest-agent, which runs as Local System, and reading .Path on a
    # packaged (MSIX) game's process is denied even for SYSTEM. The catch below
    # then swallows the failure and reports "not running" while the game is very
    # much running - so the session never ends and the VM keeps the GPU.
    if ($Executable) {
        $base = [IO.Path]::GetFileNameWithoutExtension($Executable)
        $byName = @(Get-Process -Name $base -ErrorAction SilentlyContinue)
        if ($byName.Count -gt 0) { return $byName }
    }

    if (-not $InstallPath) { return @() }
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($InstallPath, 'OrdinalIgnoreCase') } catch { $false }
    })
}

# Is ANY Game Pass title running, whichever one it is?
#
# This exists for the browse-then-play path, which is the normal way somebody
# uses the Xbox app: launch the app from Steam, browse the catalogue, install
# something, and start it from inside the app. Some titles close or background
# the Xbox app when they launch. The watcher was looking only for the app's own
# process, so it saw the launcher disappear, concluded the session was over,
# and powered the VM off WITH THE NEW GAME RUNNING.
#
# Deliberately uses Win32_Process rather than Get-Process().Path. The host asks
# this question over qemu-guest-agent as Local System, and .Path on a packaged
# (MSIX) process is denied even to SYSTEM -- the exact trap documented in
# Get-GameProcesses. Win32_Process.ExecutablePath is readable, and it also
# catches a title installed moments ago that is in no cached game list yet.
# Is a Game Pass download or install actually in progress?
#
# This exists because closing the launcher -- or using the exit chord -- used to
# power the VM off underneath a download. Nothing in the watcher looked at
# transfers at all: it watched the Xbox app process and any process under
# C:\XboxGames, and a download is done by GamingServices, which is neither. So
# somebody who kicked off a 300 GB install and went to make a cup of tea came
# back to a machine that had thrown it away.
#
# Two independent signals, because neither alone is trustworthy:
#
#   1. Delivery Optimization. Reliable when it fires, but its job list is mostly
#      history -- on this guest it holds 33 entries, every one of them 'Caching',
#      i.e. finished. Only a genuinely active status counts.
#   2. Growth of C:\XboxGames across a short sample. Slower but Game-Pass
#      specific, and it catches the install/decompress phase after the bytes have
#      landed, which DO has already stopped reporting by then.
#
# Deliberately biased toward saying "yes": a false positive costs a headless VM
# that shuts itself down a few minutes later, a false negative costs the user
# their download.
function Test-DownloadActive {
    param([int]$SampleSeconds = 6)

    try {
        $do = @(Get-DeliveryOptimizationStatus -ErrorAction Stop |
                Where-Object { $_.Status -notmatch 'Caching|Complete|Paused' })
        if ($do.Count -gt 0) {
            Write-Log "download active: $($do.Count) Delivery Optimization job(s) transferring"
            return $true
        }
    } catch { }

    # Size sampling. Only counts as active if it grows by more than a trivial
    # amount, so ordinary log and save writes do not read as a download.
    $root = 'C:\XboxGames'
    if (-not (Test-Path $root)) { return $false }
    function _sz {
        try { return (Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
                      Measure-Object -Property Length -Sum).Sum } catch { return 0 }
    }
    $a = _sz
    Start-Sleep -Seconds $SampleSeconds
    $b = _sz
    $grew = $b - $a
    if ($grew -gt 8MB) {
        Write-Log ("download active: C:\XboxGames grew {0:N0} bytes in {1}s" -f $grew, $SampleSeconds)
        return $true
    }
    return $false
}

function Get-AnyXboxGameProcess {
    try {
        $root = $GamesRoot.TrimEnd('\') + '\'
        return @(Get-CimInstance Win32_Process -ErrorAction Stop |
                 Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, 'OrdinalIgnoreCase') })
    } catch {
        return @()
    }
}

# Frame-timing capture around a session.
#
# Optional and always non-fatal: performance logging must never be the reason a
# game fails to start. If PresentMon is absent the helper script exits quietly.
function Start-PerfCapture {
    param([string]$Executable = '')
    try {
        $s = 'C:\ProgramData\xsync\xsync-perf.ps1'
        if (-not (Test-Path $s)) { return }
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $s, '-Action', 'start')
        if ($Executable) { $a += @('-ProcessName', $Executable) }
        Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden
    } catch { }
}

function Stop-PerfCapture {
    try {
        $s = 'C:\ProgramData\xsync\xsync-perf.ps1'
        if (-not (Test-Path $s)) { return }
        Start-Process powershell.exe -WindowStyle Hidden -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $s, '-Action', 'stop')
    } catch { }
}

# Identifies the current boot. State from an earlier boot is meaningless and
# actively dangerous - see Get-State.
function Get-BootId {
    try { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o') }
    catch { return 'unknown' }
}

function Save-State {
    param([hashtable]$State)
    $State['boot_id'] = Get-BootId
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

<#
    Read session state, ignoring anything left over from a previous boot.

    Any forced teardown - the host watchdog, xsync-recover, virsh destroy - leaves
    state.json describing a game that is no longer running. The logon-triggered
    watcher would then read it on the *next* boot, see no matching process, and
    call Stop-Computer about 90 seconds in: right as the user's newly launched
    game is still loading. Stamping and checking the boot id makes stale state
    inert.
#>
function Get-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try { $s = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $s) { return $null }
    $stamped = if ($s.PSObject.Properties['boot_id']) { $s.boot_id } else { $null }
    if ($stamped -ne (Get-BootId)) {
        Write-Log "ignoring state from a previous boot (stamped: $stamped)" 'WARN'
        return $null
    }
    return $s
}

# ---------------------------------------------------------------- xinput

<#
    The Guide (Xbox) button is masked out of the documented XInputGetState.
    XInputGetStateEx - ordinal 100, undocumented but stable since 2007 and what
    Steam and every overlay uses - exposes it as bit 0x0400.
#>
$script:XInputLoaded = $false
function Initialize-XInput {
    if ($script:XInputLoaded) { return $true }
    $source = @'
using System;
using System.Runtime.InteropServices;

public static class XInputEx
{
    [StructLayout(LayoutKind.Sequential)]
    public struct XInputGamepad {
        public ushort wButtons;
        public byte bLeftTrigger, bRightTrigger;
        public short sThumbLX, sThumbLY, sThumbRX, sThumbRY;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct XInputState {
        public uint dwPacketNumber;
        public XInputGamepad Gamepad;
    }

    [DllImport("xinput1_4.dll", EntryPoint = "#100")]
    private static extern uint XInputGetStateEx14(uint idx, out XInputState state);
    [DllImport("xinput1_3.dll", EntryPoint = "#100")]
    private static extern uint XInputGetStateEx13(uint idx, out XInputState state);

    public const ushort BACK  = 0x0020;   // View button
    public const ushort START = 0x0010;   // Menu button
    public const ushort GUIDE = 0x0400;
    // Stick clicks. These are the exit chord under the Xbox full screen
    // experience, because FSE reserves the obvious buttons for itself:
    // Menu opens its menus, View and a long Xbox press drive its task
    // switcher, and Xbox opens Game Bar. A background poller never sees any
    // of them -- confirmed on a real machine, where XInputGetState returns
    // success for the pad while wButtons stays 0x0000 through sustained
    // presses of View, Menu, Guide, A and B.
    //
    // L3+R3 is not bound by the FSE shell, needs two deliberate hands, and is
    // very unlikely to be pressed by accident mid-game.
    // A way out that does not depend on the controller.
    //
    // The exit chord is the only route to the prompt, and it needs a pad that
    // Windows has enumerated as XInput. The pad reaches this guest over a
    // Bluetooth radio on a passed-through USB controller -- a chain with several
    // ways to fail, none of which the user can diagnose from the sofa, and all
    // of which end with a game they cannot quit.
    //
    // The wireless keyboard sits on that same passed-through controller, so it
    // is present whenever the pad should be. GetAsyncKeyState reads physical key
    // state regardless of which window has focus, so a background watcher can
    // see this behind a fullscreen game.
    //
    // Ctrl+Alt+Q: three keys, no game binds it, and it cannot be hit by accident.
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    private const int VK_CONTROL = 0x11, VK_MENU = 0x12, VK_Q = 0x51;
    public static bool ExitHotkey()
    {
        try {
            return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0
                && (GetAsyncKeyState(VK_MENU)    & 0x8000) != 0
                && (GetAsyncKeyState(VK_Q)       & 0x8000) != 0;
        } catch { return false; }
    }

    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    public static void ForceForeground(IntPtr h) {
        try { ShowWindow(h, 5); SetForegroundWindow(h); } catch { }
    }

    public const ushort LTHUMB = 0x0040;  // L3 (left stick click)
    public const ushort RTHUMB = 0x0080;  // R3 (right stick click)
    public const ushort A = 0x1000;
    public const ushort B = 0x2000;

    // ERROR_DEVICE_NOT_CONNECTED. Returned for an empty slot, and the reason a
    // pad that is merely switched off is not an error condition.
    public const uint NOT_CONNECTED = 1167;

    public static ushort GetButtons(uint idx)
    {
        XInputState s;
        try { if (XInputGetStateEx14(idx, out s) == 0) return s.Gamepad.wButtons; }
        catch { }
        try { if (XInputGetStateEx13(idx, out s) == 0) return s.Gamepad.wButtons; }
        catch { }
        return 0;
    }

    // The status behind GetButtons, which cannot express it.
    //
    // GetButtons returns 0 for "connected, nothing pressed" AND for "no such
    // controller" -- and the watcher only logs non-zero values, so a pad that
    // is off, asleep, or never enumerated in the guest looks exactly like a pad
    // sitting idle on the sofa. Every report of "I pressed the chord and
    // nothing happened" is consistent with both, which is why none of them
    // could be diagnosed from the log.
    public static uint GetStatus(uint idx)
    {
        XInputState s;
        try { return XInputGetStateEx14(idx, out s); } catch { }
        try { return XInputGetStateEx13(idx, out s); } catch { }
        return NOT_CONNECTED;
    }

    public static int ConnectedCount()
    {
        int n = 0;
        for (uint i = 0; i < 4; i++) { if (GetStatus(i) == 0) n++; }
        return n;
    }

    // A one-line snapshot of what XInput is actually handing us.
    //
    // "Nothing in the log" has meant three different things so far: the watcher
    // was dead, the pad was absent, or the API was returning a connected pad
    // with every button zeroed. Only the last one is the interesting case, and
    // dwPacketNumber is what separates it: if the packet number advances while
    // wButtons stays 0, the device is live and the input is being withheld --
    // which is what Windows does to a background process while a game has focus.
    public static string Snapshot()
    {
        string outp = "";
        for (uint i = 0; i < 4; i++) {
            XInputState s; s.dwPacketNumber = 0; s.Gamepad = new XInputGamepad();
            uint rc = NOT_CONNECTED;
            try { rc = XInputGetStateEx14(i, out s); }
            catch { try { rc = XInputGetStateEx13(i, out s); } catch { } }
            if (rc == 0) {
                outp += string.Format("[{0}] rc=0 pkt={1} btn=0x{2:X4} lt={3} rt={4} lx={5} ly={6} ",
                    i, s.dwPacketNumber, s.Gamepad.wButtons,
                    s.Gamepad.bLeftTrigger, s.Gamepad.bRightTrigger,
                    s.Gamepad.sThumbLX, s.Gamepad.sThumbLY);
            } else if (rc != NOT_CONNECTED) {
                outp += string.Format("[{0}] rc={1} ", i, rc);
            }
        }
        return outp.Length == 0 ? "no controllers in any slot" : outp.Trim();
    }

    // Any controller, so the user can pick up whichever pad is to hand.
    public static ushort GetAnyButtons()
    {
        ushort combined = 0;
        for (uint i = 0; i < 4; i++) combined |= GetButtons(i);
        return combined;
    }
}
'@
    try {
        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        $script:XInputLoaded = $true
        # "XInput initialised" was read as "the controller works". It only means
        # the P/Invoke bound; say how many pads actually answered.
        Write-Log ('XInput initialised ({0} controller(s) connected)' -f [XInputEx]::ConnectedCount())
        return $true
    } catch {
        Write-Log "XInput unavailable, Guide overlay disabled: $_" 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------- raw input

<#
    Controller input that survives a game having focus.

    XInput cannot do this. Measured on this machine, with a pad connected and a
    game running: dwPacketNumber climbed 4 -> 366 -> 1168 -> 2434 over ninety
    seconds while wButtons, both triggers and both thumbsticks stayed at exactly
    zero. The device was streaming ~27 packets a second and every one of them was
    rest values. That is Windows deliberately withholding input from a background
    process while the foreground app owns the pad, and it is documented behaviour
    for the XInput-on-GameInput path that ships in Windows 11.

    So every exit chord ever written here -- L3+R3, View+Menu, Guide -- was
    unreachable for reasons that had nothing to do with the chord, the overlay, or
    the Xbox shell. Those were all downstream of this.

    Raw Input with RIDEV_INPUTSINK is the documented way to receive device input
    when you are NOT the foreground window. It needs a real HWND and a message
    pump, so this runs a message-only window on its own STA thread and decodes
    the HID button usages with HidP_GetUsages.

    Verified on hardware before being wired in: 391 reports received and buttons
    "9,10" decoded while Oblivion was in the foreground.
#>
$script:RawPadLoaded = $false
function Initialize-RawInput {
    if ($script:RawPadLoaded) { return $true }
    $src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class XsyncRawPad
{
    const int  RIDEV_INPUTSINK    = 0x00000100;
    const int  RID_INPUT          = 0x10000003;
    const int  RIDI_PREPARSEDDATA = 0x20000005;
    const int  WM_INPUT           = 0x00FF;
    const uint HIDP_STATUS_SUCCESS = 0x00110000;

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTDEVICE { public ushort UsagePage, Usage; public int Flags; public IntPtr Target; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint num, uint size);
    [DllImport("user32.dll")]
    static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hdrSize);
    [DllImport("user32.dll")]
    static extern uint GetRawInputDeviceInfo(IntPtr dev, uint cmd, IntPtr data, ref uint size);
    [DllImport("hid.dll")]
    static extern uint HidP_GetUsages(int type, ushort page, ushort link, [In,Out] ushort[] list,
                                      ref uint len, IntPtr prep, IntPtr report, uint reportLen);

    [StructLayout(LayoutKind.Sequential)]
    struct WNDCLASSEX {
        public uint cbSize; public uint style; public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

    delegate IntPtr WndProcDelegate(IntPtr h, uint msg, IntPtr w, IntPtr l);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassEx(ref WNDCLASSEX c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(
        int ex, string cls, string name, int style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);

    static readonly object Lock = new object();
    static HashSet<int> pressed = new HashSet<int>();
    static int reports = 0;
    // The delegate must outlive the window. Without a managed reference the GC
    // collects it, the window procedure becomes a dangling pointer, and the
    // thread dies silently the first time a report arrives.
    static WndProcDelegate keepAlive;
    public static string LastError = "";

    public static int Reports { get { lock (Lock) { return reports; } } }
    public static bool IsDown(int button) { lock (Lock) { return pressed.Contains(button); } }
    public static string Pressed {
        get {
            lock (Lock) {
                if (pressed.Count == 0) return "-";
                string s = "";
                foreach (int b in pressed) { if (s.Length > 0) s += ","; s += b.ToString(); }
                return s;
            }
        }
    }

    static IntPtr Proc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        if (msg == WM_INPUT) { try { Handle(l); } catch { } }
        return DefWindowProc(h, msg, w, l);
    }

    static void Handle(IntPtr hRaw)
    {
        uint hdr = (uint)(4 + 4 + IntPtr.Size + IntPtr.Size);
        uint size = 0;
        GetRawInputData(hRaw, RID_INPUT, IntPtr.Zero, ref size, hdr);
        if (size == 0) return;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (GetRawInputData(hRaw, RID_INPUT, buf, ref size, hdr) != size) return;
            if (Marshal.ReadInt32(buf, 0) != 2) return;              // RIM_TYPEHID
            IntPtr hDevice = Marshal.ReadIntPtr(buf, 8);
            int off     = (int)hdr;
            int sizeHid = Marshal.ReadInt32(buf, off);
            int count   = Marshal.ReadInt32(buf, off + 4);
            if (count < 1 || sizeHid < 1) return;
            IntPtr report = new IntPtr(buf.ToInt64() + off + 8);

            uint psize = 0;
            GetRawInputDeviceInfo(hDevice, RIDI_PREPARSEDDATA, IntPtr.Zero, ref psize);
            if (psize == 0) return;
            IntPtr prep = Marshal.AllocHGlobal((int)psize);
            try {
                GetRawInputDeviceInfo(hDevice, RIDI_PREPARSEDDATA, prep, ref psize);
                ushort[] usages = new ushort[64];
                uint len = (uint)usages.Length;
                uint rc = HidP_GetUsages(0, 0x09, 0, usages, ref len, prep, report, (uint)sizeHid);
                lock (Lock) {
                    reports++;
                    if (rc == HIDP_STATUS_SUCCESS) {
                        pressed.Clear();
                        for (int i = 0; i < len; i++) pressed.Add(usages[i]);
                    }
                }
            } finally { Marshal.FreeHGlobal(prep); }
        } finally { Marshal.FreeHGlobal(buf); }
    }

    public static void Start()
    {
        Thread t = new Thread(delegate () {
            try {
                keepAlive = new WndProcDelegate(Proc);
                WNDCLASSEX c = new WNDCLASSEX();
                c.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
                c.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(keepAlive);
                c.hInstance = GetModuleHandle(null);
                c.lpszClassName = "XsyncRawPad";
                RegisterClassEx(ref c);
                // HWND_MESSAGE (-3): a message-only window, never visible, still a
                // legal Raw Input target.
                IntPtr hwnd = CreateWindowEx(0, "XsyncRawPad", "XsyncRawPad", 0, 0, 0, 0, 0,
                                             new IntPtr(-3), IntPtr.Zero, c.hInstance, IntPtr.Zero);
                if (hwnd == IntPtr.Zero) { LastError = "CreateWindowEx failed " + Marshal.GetLastWin32Error(); return; }

                // Generic desktop page, gamepad (5) and joystick (4).
                RAWINPUTDEVICE[] rid = new RAWINPUTDEVICE[2];
                rid[0].UsagePage = 1; rid[0].Usage = 5; rid[0].Flags = RIDEV_INPUTSINK; rid[0].Target = hwnd;
                rid[1].UsagePage = 1; rid[1].Usage = 4; rid[1].Flags = RIDEV_INPUTSINK; rid[1].Target = hwnd;
                if (!RegisterRawInputDevices(rid, 2, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE))))
                    { LastError = "RegisterRawInputDevices failed " + Marshal.GetLastWin32Error(); return; }

                MSG m;
                while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref m); DispatchMessage(ref m); }
            } catch (Exception e) { LastError = e.Message; }
        });
        t.IsBackground = true;
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
    }
}
'@
    try {
        Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
        [XsyncRawPad]::Start()
        Start-Sleep -Milliseconds 800
        $err = [XsyncRawPad]::LastError
        if ($err) { Write-Log "raw input failed to start: $err" 'ERROR'; return $false }
        $script:RawPadLoaded = $true
        Write-Log 'raw input started (gamepad reports delivered even when a game has focus)'
        return $true
    } catch {
        Write-Log "raw input unavailable: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------- overlay

<#
    Minimal controller-navigable confirmation. Deliberately not a full UI: it has
    to be legible from a sofa and dismissible without a keyboard, nothing more.
#>
function Show-ExitOverlay {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # The overlay reads XInput to wait for button release and to read the
    # answer, so [XInputEx] must exist before any of that runs. When it did not,
    # the release-wait threw "Unable to find type [XInputEx]" the instant the
    # window was shown; the exception unwound past $form.Close() and the form
    # died with the scope. On screen that is a flash and nothing else, with no
    # error anywhere the user can see -- which is exactly how it was reported,
    # and what sent me chasing four wrong theories about the Xbox shell.
    if (-not ('XInputEx' -as [type])) {
        try { Initialize-XInput | Out-Null } catch { }
    }
    if (-not ('XInputEx' -as [type])) {
        Write-Log 'XInputEx is unavailable - cannot show the exit overlay' 'ERROR'
        return $false
    }

    # Size the overlay from the text and the actual screen, never from fixed
    # pixels.
    #
    # This used to be a hardcoded 760x260 box with 30pt/18pt fonts, which is
    # fine at 1080p and wrong everywhere else. On a 4K TV the DPI scaling grows
    # the text past the box and both button hints get clipped at the edges --
    # so the one screen the user must be able to read, on the one device that
    # has no keyboard, was the one that did not fit.
    #
    # Scale the type to the display height, then measure the rendered strings
    # and make the form fit them with padding. That cannot clip regardless of
    # resolution or scaling factor.
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $titleSize = [int]([math]::Max(24, [math]::Min(64, $screen.Height / 40)))
    $hintSize  = [int]([math]::Max(14, [math]::Min(34, $screen.Height / 72)))

    $titleFont = New-Object System.Drawing.Font('Segoe UI', $titleSize, [System.Drawing.FontStyle]::Bold)
    $hintFont  = New-Object System.Drawing.Font('Segoe UI', $hintSize)

    $titleText = 'Exit to Steam?'
    $hintText  = '(A) Yes, quit     (B) Keep playing        Enter / Esc'

    $tm = [System.Windows.Forms.TextRenderer]::MeasureText($titleText, $titleFont)
    $hm = [System.Windows.Forms.TextRenderer]::MeasureText($hintText,  $hintFont)

    $pad = [int]($screen.Height / 20)
    $gap = [int]($pad / 2)

    # Fill the screen, and centre the text block within it.
    #
    # A snug box sized to the measured text is the obvious design and it is
    # wrong here: the Xbox full screen experience forces every window fullscreen,
    # so the form became 1280x720 while the labels stayed the width the text
    # needed -- a correct prompt pinned to the top-left of a black screen, which
    # reads as broken. Sizing to the screen up front makes the layout identical
    # whether or not anything resizes us, with no event handler to get wrong.
    $w = [int]$screen.Width
    $h = [int]$screen.Height
    $blockH = [int]($tm.Height + $gap + $hm.Height)
    $blockTop = [int](($h - $blockH) / 2)
    if ($blockTop -lt $pad) { $blockTop = $pad }

    $form                 = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.BackColor       = [System.Drawing.Color]::FromArgb(16, 16, 20)
    $form.TopMost         = $true
    $form.StartPosition   = 'CenterScreen'
    $form.AutoScaleMode   = 'None'
    $form.Size            = New-Object System.Drawing.Size($w, $h)
    $form.Opacity         = 0.96

    # Explicit bounds, NOT Dock.
    #
    # Docking these two hid the instructions completely. WinForms resolves
    # docking from the LAST-added control first, so 'Fill' on the hint claimed
    # the entire client area and centred its text vertically in the whole form
    # -- then the 'Top' title docked over the upper half and covered it. The
    # title rendered, the line telling the user which button does what did not,
    # on the one screen that exists to tell them exactly that, on a device with
    # no keyboard.
    #
    # Positioning both explicitly removes the layout engine's opinion from it
    # entirely: the geometry is computed from measured text above, so it still
    # cannot clip at any resolution, and the order controls are added no longer
    # changes what is on screen.
    $label                = New-Object System.Windows.Forms.Label
    $label.Text           = $titleText
    $label.ForeColor      = [System.Drawing.Color]::White
    $label.Font           = $titleFont
    $label.TextAlign      = 'MiddleCenter'
    $label.AutoSize       = $false
    $label.SetBounds(0, $blockTop, $w, [int]$tm.Height)
    $form.Controls.Add($label)

    $hint                 = New-Object System.Windows.Forms.Label
    $hint.Text            = $hintText
    $hint.ForeColor       = [System.Drawing.Color]::FromArgb(170, 170, 180)
    $hint.Font            = $hintFont
    $hint.TextAlign       = 'MiddleCenter'
    $hint.AutoSize        = $false
    $hint.SetBounds(0, [int]($blockTop + $tm.Height + $gap), $w, [int]$hm.Height)
    $form.Controls.Add($hint)

    # Take the foreground, do not just draw.
    #
    # The overlay was created WS_EX_NOACTIVATE and shown without activating, so
    # it never stole focus from a running game -- correct on the desktop. Under
    # the Xbox full screen experience it is wrong: FSE presents one surface at a
    # time, so an unactivated window is composited and then immediately covered
    # again when the shell re-presents. The user sees it flash up and vanish, and
    # concludes the overlay is broken. Observed exactly that way.
    #
    # Activating costs a focus change the game will notice, which is a real
    # trade -- but a confirmation prompt nobody can read is worth nothing, and
    # the user is in the act of asking to quit anyway.
    $form.Show()
    $form.Refresh()
    try {
        $form.TopMost = $false
        $form.TopMost = $true
        $form.Activate()
        $form.BringToFront()
        [XInputEx]::ForceForeground($form.Handle) | Out-Null
    } catch { Write-Log "could not foreground the overlay: $($_.Exception.Message)" 'WARN' }
    [System.Windows.Forms.Application]::DoEvents()

    # Wait for every trigger button to be released before reading an answer, so
    # the press that opened this overlay is not immediately taken as one. Covers
    # the View+Menu chord as well as Guide.
    #
    # Bounded, because this wait got materially more dangerous when the chord was
    # added. It used to watch GUIDE alone -- a button nothing else binds. It now
    # also watches View and Menu, which are ordinary buttons games do bind, and
    # GetAnyButtons ORs pads 0-3. A second controller down the back of the sofa
    # with Menu held keeps that bit set forever, and an unbounded wait here hangs
    # the watcher with the overlay drawn TopMost over the game. A hang is not an
    # exception, so the catch, the hard deadline and the finally that calls
    # Stop-Computer are all skipped -- the guest loses its exit path entirely.
    #
    # Worse with two buttons wedged: the chord reads as pressed with no user
    # involvement at all.
    #
    # Three seconds is far longer than a human takes to lift a thumb. Falling
    # through afterwards is safe: the decision loop below is itself bounded, and
    # a still-held button simply reads as a fresh press there.
    $triggers = [XInputEx]::GUIDE -bor [XInputEx]::BACK -bor [XInputEx]::START `
                -bor [XInputEx]::LTHUMB -bor [XInputEx]::RTHUMB
    $releaseBy = (Get-Date).AddSeconds(3)
    while ((([XInputEx]::GetAnyButtons() -band $triggers) -ne 0) -and ((Get-Date) -lt $releaseBy)) {
        Start-Sleep -Milliseconds 50
    }
    if (([XInputEx]::GetAnyButtons() -band $triggers) -ne 0) {
        Write-Log 'a trigger button is still held after 3s (stuck pad?) - continuing anyway' 'WARN'
    }
    Write-Log ('overlay shown; screen {0}x{1}; form {2}; label {3}; hint {4}; blockTop {5}; tm {6}; hm {7}' -f $screen.Width, $screen.Height, $form.Bounds.ToString(), $label.Bounds.ToString(), $hint.Bounds.ToString(), $blockTop, $tm.ToString(), $hm.ToString())

    # Logged, because this loop closes the overlay and four separate theories
    # about WHY it closes immediately have now been wrong. The window itself is
    # provably fine -- an identical bare window stays visible and foreground for
    # twelve seconds under FSE -- so whatever ends it is in here, and guessing
    # again is worth less than one line of evidence.
    # Answerable from the keyboard as well as the pad.
    #
    # A prompt that only a controller can dismiss is worthless in the one case
    # that matters -- the controller not working - and it is drawn TopMost over
    # the game, so leaving it up for the full twenty seconds is not neutral.
    $script:overlayKey = $null
    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($eventSender, $e)
        switch ($e.KeyCode) {
            'Enter'  { $script:overlayKey = $true }
            'Y'      { $script:overlayKey = $true }
            'Escape' { $script:overlayKey = $false }
            'N'      { $script:overlayKey = $false }
        }
    })

    $decision = $false
    $reason   = 'timeout'
    $ticks    = 0
    $firstBtn = -1
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($null -ne $script:overlayKey) {
            $decision = [bool]$script:overlayKey
            $reason   = "keyboard ($(if ($decision) { 'Enter/Y' } else { 'Esc/N' }))"
            break
        }
        $btn = [XInputEx]::GetAnyButtons()
        if ($firstBtn -lt 0) { $firstBtn = $btn }
        $ticks++
        if (($btn -band [XInputEx]::A) -ne 0) { $decision = $true;  $reason = ('A (0x{0:X4})' -f $btn); break }
        if (($btn -band [XInputEx]::B) -ne 0) { $decision = $false; $reason = ('B (0x{0:X4})' -f $btn); break }
        Start-Sleep -Milliseconds 60
    }
    Write-Log ("overlay closed: {0} after {1} tick(s); first read 0x{2:X4}; visible={3}" -f `
        $reason, $ticks, $firstBtn, $form.Visible)

    $form.Close()
    $form.Dispose()
    return $decision
}

# ---------------------------------------------------------------- watch

<#
    The session's main loop. Ends the VM when play is over, which is what returns
    the user to Steam: the host is blocked waiting for this domain to stop.

    Three ways out, matching PLAN.md section 6:
      1. the game exits on its own
      2. the user holds Guide and confirms
      3. the game never started at all (nothing to wait for)
#>
function Start-Watcher {
    # WAIT for a session, do not exit when there is not one yet.
    #
    # This used to return immediately when no state existed for the current boot,
    # which threw away the one watcher instance that is actually reliable. The
    # logon-triggered task starts at every logon, in its own task tree, and
    # survives whatever else comes and goes -- and it was being discarded seconds
    # before the host wrote the state it was waiting for.
    #
    # That left the whole exit path depending on the launch spawning a watcher of
    # its own, which is fragile in exactly the way that has cost a whole evening:
    # a process started from inside a scheduled task dies when that task
    # completes, and Start-ScheduledTask races an instance that has just exited.
    #
    # Inverting it removes the class of bug entirely. The watcher is already
    # running and idle before the game starts; the launch only has to write state.
    $state = Get-State
    if (-not $state) {
        $waitUntil = (Get-Date).AddSeconds([int]$env:XSYNC_WATCHER_WAIT_SECONDS)
        if (-not $env:XSYNC_WATCHER_WAIT_SECONDS) { $waitUntil = (Get-Date).AddMinutes(15) }
        Write-Log 'no session state yet - waiting for a launch'
        while (-not $state -and (Get-Date) -lt $waitUntil) {
            Start-Sleep -Seconds 2
            $state = Get-State
        }
        if (-not $state) {
            Write-Log 'no session was started - watcher exiting'
            return
        }
        Write-Log 'session state appeared - taking over'
    }

    $installPath = $null
    $gameName = 'Xbox app'
    if ($state.PSObject.Properties['install_path']) { $installPath = $state.install_path }
    $executable = ''
    if ($state.PSObject.Properties['executable']) { $executable = $state.executable }
    if ($state.PSObject.Properties['name'])         { $gameName    = $state.name }

    # Initialise BEFORE the loop. Set-StrictMode -Version Latest makes reading an
    # unset variable a terminating error, and the watcher loop catches per
    # iteration -- so an uninitialised $script: variable does not crash loudly,
    # it turns every iteration into "watcher iteration failed" and silently
    # disables the exit chord for the whole session. Which is exactly what my own
    # instrumentation did, twenty minutes after I added it.
    $script:lastBtn        = 0
    $script:noXInputLogged = $false
    # -1 so the first reading always logs, and initialised HERE because under
    # Set-StrictMode reading an unset variable is a terminating error -- which is
    # exactly how $script:lastBtn took the watcher down for twenty minutes.
    $script:lastPads       = -1
    $script:nextBeat       = Get-Date
    $hasRaw = Initialize-RawInput

    $hasXInput = Initialize-XInput
    Write-Log "watcher started for '$gameName'"

    # Give the title time to get going before treating "no process" as "exited".
    $startupGrace = (Get-Date).AddSeconds(90)
    $everSeen = $false
    $guideHeldSince = $null
    # Must be initialised: Set-StrictMode makes reading an undefined variable a
    # terminating error, and this is read inside the watch loop.
    $script:sawLauncherGame = $false

    # Backstop. Without this the Xbox-app case had no exit condition whatsoever:
    # install_path is null, so the process check is skipped, and if XInput failed
    # to initialise or no controller is attached the loop could never terminate -
    # leaving the host session torn down indefinitely.
    $hardDeadline = (Get-Date).AddHours(6)

    # The whole loop is wrapped, and the shutdown lives in `finally`.
    #
    # Every statement below runs under $ErrorActionPreference='Stop' plus
    # Set-StrictMode -Version Latest, and the ONLY route to Stop-Computer was a
    # `break`. So any throw at all - a transient Get-Process, a WinForms failure
    # in Show-ExitOverlay, an XInput marshalling fault - unwound straight past
    # the shutdown and exited 0, leaving the VM holding the GPU with the host
    # session already torn down. That is the single worst outcome this project
    # has, and it had a dozen ways to happen.
    #
    # Per-iteration errors are caught separately: one bad poll must not end a
    # live game, but it must not be fatal to the watcher either.
    try {
      while ($true) {
        Start-Sleep -Milliseconds 500

        if ((Get-Date) -gt $hardDeadline) {
            Write-Log 'session hit the 6 hour ceiling - ending session' 'WARN'
            break
        }

        try {
        if ($installPath) {
            $procs = @(Get-GameProcesses -InstallPath $installPath -Executable $executable)
            if ($procs.Count -gt 0) {
                if (-not $everSeen) { Start-PerfCapture -Executable $executable }
                $everSeen = $true
            } elseif ($everSeen) {
                Write-Log 'game process exited - ending session'
                break
            } elseif ((Get-Date) -gt $startupGrace) {
                Write-Log 'game never started within the grace period - ending session' 'WARN'
                break
            }
        } else {
            # Xbox-app session. The app itself is the thing being used, so
            # closing it is the natural way to finish -- but only if nothing it
            # launched is still running.
            #
            # The browse-then-play path is the normal way people use this:
            # launch the Xbox app from Steam, find something, install it, and
            # start it from inside the app. Titles that close or background the
            # launcher on start would otherwise look exactly like "user closed
            # the Xbox app", and the session would end with the game running --
            # powering the VM off underneath somebody who just waited for a
            # 100 GB download.
            $app  = @(Get-Process -Name 'XboxPcApp', 'GamingApp', 'Xbox' -ErrorAction SilentlyContinue)
            $game = @(Get-AnyXboxGameProcess)
            if ($app.Count -gt 0 -or $game.Count -gt 0) {
                $everSeen = $true
                # Once a game is up, it becomes the thing being watched: closing
                # the launcher behind it must not end the session.
                if ($game.Count -gt 0 -and $app.Count -eq 0) {
                    if (-not $script:sawLauncherGame) {
                        Write-Log "a game launched from the Xbox app is running - watching it instead of the launcher"
                        $script:sawLauncherGame = $true
                    }
                }
            } elseif ($everSeen) {
                Write-Log 'Xbox app closed and no game running - ending session'
                break
            } elseif ((Get-Date) -gt $startupGrace) {
                Write-Log 'Xbox app never appeared - ending session' 'WARN'
                break
            }
        }

        if (-not $hasXInput) {
            if (-not $script:noXInputLogged) {
                Write-Log 'XInput unavailable in the watcher - only the Ctrl+Alt+Q hotkey can reach the exit prompt' 'ERROR'
                $script:noXInputLogged = $true
            }
        }
        if ($hasXInput) {
            $btn = [XInputEx]::GetAnyButtons()

            # Log what the WATCHER actually reads, throttled to changes only.
            #
            # A separate test process polling the same pad saw every button
            # (union 0xF7FF) while a game was running, yet the watcher never
            # reached Show-ExitOverlay -- so the two processes disagree about
            # what the controller is doing, and that disagreement is invisible
            # from outside the watcher. One line per change settles it.
            if ($btn -ne $script:lastBtn) {
                $script:lastBtn = $btn
                if ($btn -ne 0) { Write-Log ('pad: 0x{0:X4}' -f $btn) }
            }

            # Say when a controller appears or disappears.
            #
            # Without this the log cannot distinguish "the user pressed nothing"
            # from "there was no controller to press" -- the two readings are
            # both 0x0000 and only one of them is a fault. A chord that does
            # nothing on the TV is now answerable from the log alone.
            # Heartbeat.
            #
            # Every log this loop produced was change-triggered, so a watcher
            # that was alive and being handed all-zeros looked exactly like a
            # watcher that was dead. That ambiguity cost a whole test session on
            # the TV: the process was polling the entire time and the log had
            # nothing in it to say so. Thirty seconds is cheap and makes silence
            # mean silence.
            if ((Get-Date) -gt $script:nextBeat) {
                $rawState = if ($hasRaw) {
                    'rawpad: {0} report(s), pressed {1}' -f [XsyncRawPad]::Reports, [XsyncRawPad]::Pressed
                } else { 'rawpad: unavailable' }
                Write-Log ('xinput: ' + [XInputEx]::Snapshot() + ' | ' + $rawState)
                $script:nextBeat = (Get-Date).AddSeconds(30)
            }

            $pads = [XInputEx]::ConnectedCount()
            if ($pads -ne $script:lastPads) {
                if ($pads -eq 0) {
                    Write-Log 'no controller connected - the exit chord cannot be pressed' 'WARN'
                } else {
                    Write-Log ('{0} controller(s) connected' -f $pads)
                }
                $script:lastPads = $pads
            }

            # Two ways in, on purpose.
            #
            # Guide-hold is the natural gesture, but the Xbox Full Screen
            # Experience rebinds Guide to its own task switcher, so relying on
            # it alone means enabling FSE silently removes the only way out of
            # a game. View+Menu together is not claimed by FSE, is not used by
            # games as a chord, and is awkward enough to press by accident that
            # it does not need a hold timer of its own.
            # HID button numbers, confirmed by probing this controller with a
            # game in the foreground: L3 is 9 and R3 is 10, View is 7 and Menu
            # is 8. Read through Raw Input, which is the only path that sees
            # them at all while a game holds focus.
            $rawChord = $false
            if ($hasRaw) {
                $rawChord = ([XsyncRawPad]::IsDown(9) -and [XsyncRawPad]::IsDown(10)) `
                            -or ([XsyncRawPad]::IsDown(7) -and [XsyncRawPad]::IsDown(8))
            }

            $chord = $rawChord `
                     -or ((($btn -band [XInputEx]::BACK) -ne 0) -and (($btn -band [XInputEx]::START) -ne 0)) `
                     -or ((($btn -band [XInputEx]::LTHUMB) -ne 0) -and (($btn -band [XInputEx]::RTHUMB) -ne 0)) `
                     -or [XInputEx]::ExitHotkey()
            $guide = ($btn -band [XInputEx]::GUIDE) -ne 0

            if ($chord -or $guide) {
                if (-not $guideHeldSince) { $guideHeldSince = Get-Date }
                # The chord is deliberate enough to act on quickly; Guide needs
                # the full hold so a normal Guide press still reaches the game.
                $needed = if ($chord) { 0.4 } else { $GuideHoldSeconds }
                if (((Get-Date) - $guideHeldSince).TotalSeconds -ge $needed) {
                    # Quit straight away. No confirmation.
                    #
                    # There was a confirmation overlay here, and it was three
                    # separate bugs and an entire class of failure -- a window
                    # that had to draw over a fullscreen game, take focus from
                    # it, and read a second round of input -- all to guard
                    # against something that does not happen. L3+R3 needs two
                    # deliberate thumbs; nobody hits it reaching for a snack.
                    #
                    # The cost of a false positive is a dropped game. The cost of
                    # the overlay was no way out at all whenever any part of it
                    # misbehaved, which was every time it was tested.
                    Write-Log $(if ($chord) { 'exit chord pressed - quitting' } else { 'Guide held - quitting' })
                    $guideHeldSince = $null
                    if ($installPath) {
                        foreach ($p in @(Get-GameProcesses -InstallPath $installPath -Executable $executable)) {
                            try { $p.CloseMainWindow() | Out-Null } catch { }
                        }
                        Start-Sleep -Seconds 3
                        foreach ($p in @(Get-GameProcesses -InstallPath $installPath -Executable $executable)) {
                            try { $p.Kill() } catch { }
                        }
                    }
                    break
                }
            } else {
                $guideHeldSince = $null
            }
        }
        } catch {
            # A single failed poll is not a reason to end someone's game, but it
            # is also not a reason to abandon the watch. Log and carry on.
            Write-Log "watcher iteration failed: $($_.Exception.Message)" 'WARN'
        }
      }
    } catch {
        Write-Log "watcher loop aborted: $($_.Exception.Message)" 'ERROR'
    } finally {
        Write-Log 'shutting down Windows - control returns to the host'
        # Stop the capture before the machine goes away, so PresentMon gets the
        # chance to flush its CSV rather than losing the tail of the session.
        Stop-PerfCapture
        try { Save-State @{ playing = $false; ended_at = (Get-Date).ToString('o') } } catch { }

        # Give the host a chance to read the installed-game list before dying.
        #
        # Installing something from the Xbox app and quitting is the single most
        # common thing anyone does in a session, and it was the one thing that did
        # not reach Steam. The host captures the list at launch -- before the
        # install exists -- and again at teardown, except teardown runs after
        # `vm.sh wait` has already confirmed the domain is gone, so that call has
        # never once succeeded. A periodic capture every three minutes was
        # covering it, which works right up until somebody installs a game and
        # quits inside those three minutes.
        #
        # The host cannot pull from a guest that has powered off, and the guest
        # has no way to push. So the guest waits: the host takes its final
        # enumeration, writes this marker back through the agent channel, and we
        # shut down immediately on seeing it. Exit stays about as quick as before
        # because the host acts on its very next poll rather than waiting for the
        # full miss count.
        $marker = Join-Path $XsyncDir 'captured'
        $waitUntil = (Get-Date).AddSeconds([int]$(if ($env:XSYNC_EXIT_GRACE_SECONDS) { $env:XSYNC_EXIT_GRACE_SECONDS } else { 45 }))
        Write-Log 'session over - waiting for the host to take the final game list'
        while (-not (Test-Path $marker) -and (Get-Date) -lt $waitUntil) { Start-Sleep -Milliseconds 500 }
        if (Test-Path $marker) {
            Write-Log 'host has the final game list - shutting down'
            Remove-Item $marker -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log 'host never collected the final game list - shutting down anyway' 'WARN'
        }

        try { Stop-Computer -Force } catch {
            Write-Log "Stop-Computer failed: $($_.Exception.Message)" 'ERROR'
        }
        # Belt and braces. If Stop-Computer was blocked (a wedged service, a
        # pending-reboot state, an app refusing to close), fall back to a forced
        # shutdown rather than leaving the VM up holding the GPU.
        Start-Sleep -Seconds 20
        try { & shutdown.exe /s /f /t 0 } catch { }
    }
}

# ---------------------------------------------------------------- run-as-user

<#
    Run a script in the interactive desktop session.

    The host talks to this VM over qemu-guest-agent, which executes everything as
    Local System. That is fine for querying state, but a whole class of operations
    simply refuse to work as SYSTEM:

      * Per-user AppX registration fails outright with 0x80073CF9,
        "the Local System account is not allowed to perform this operation".
      * Launching a packaged app via shell:appsFolder from SYSTEM does not put a
        window on the user's desktop, so a game would appear to start and then be
        invisible and uncontrollable.

    A scheduled task with an Interactive principal is the standard way across the
    session boundary: register, run, wait, clean up.
#>
function Invoke-InUserSession {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 600,
        # Elevation is opt-in because it breaks the most common use.
        # Packaged (UWP/MSIX) apps refuse to start from an elevated process, so
        # launching a game via shell:appsFolder from a RunLevel=Highest task
        # silently does nothing: the task reports success and no window appears.
        # Admin work like AppX registration does need elevation, hence the switch.
        [switch]$Elevated
    )

    if (-not (Test-Path $Path)) { throw "script not found: $Path" }

    # The console user, i.e. whoever is actually logged in at the desktop.
    $user = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $user) { throw 'no interactive user is logged on' }
    Write-Log "running $Path as $user"

    $taskName = 'xsync-runas'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Path)
    $runLevel = if ($Elevated) { 'Highest' } else { 'Limited' }
    Write-Log "run level: $runLevel"
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $runLevel
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromSeconds($TimeoutSeconds)) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        Start-Sleep -Seconds 2
        while ((Get-Date) -lt $deadline) {
            $info = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $info -or $info.State -ne 'Running') { break }
            Start-Sleep -Seconds 2
        }
        $result = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue).LastTaskResult
        Write-Log "user-session task finished with result $result"
        return $result
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- install

function Install-Agent {
    $target = 'C:\Program Files\xsync'
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    # Copying the agent over itself is an error, not a no-op.
    #
    # The normal way to reach this now is: the host pushes xsync-agent.ps1 into
    # C:\Program Files\xsync and then runs it with -Action install. $PSCommandPath
    # and the destination are then the same file, and Copy-Item -Force does not
    # forgive that -- it throws "Cannot overwrite the item ... with itself", which
    # aborted Install-Agent before it registered ANY scheduled task.
    #
    # So re-running install against an already-installed agent, the most obvious
    # possible repair action, was the one guaranteed way to make it fail.
    $installed = Join-Path $target 'xsync-agent.ps1'
    if ($PSCommandPath -and
        (Resolve-Path -LiteralPath $PSCommandPath).Path -ne $installed) {
        Copy-Item -Path $PSCommandPath -Destination $installed -Force
        Write-Log "agent installed to $target"
    } else {
        Write-Log "agent already running from $target - skipping self-copy"
    }

    Import-Module ScheduledTasks -ErrorAction SilentlyContinue

    # The watcher must run in the interactive session: it shows a window and
    # reads controller input, neither of which work from session 0.
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Program Files\xsync\xsync-agent.ps1" -Action watch'
    # `New-ScheduledTaskLogonTrigger` does not exist. It was used here from the
    # start, so this registration has ALWAYS failed with CommandNotFound and the
    # logon-triggered watcher was never actually created on any install -- and
    # because Register-ScheduledTask -Force deletes before it re-adds, re-running
    # install would remove a task that had been created some other way.
    #
    # The real cmdlet is New-ScheduledTaskTrigger -AtLogOn.
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    # The interactive user, NOT whoever is running this.
    #
    # Install-Agent is reached two ways: from firstboot (running as the autologon
    # user, where $env:USERNAME is right) and over qemu-guest-agent as Local
    # System, where it evaluates to "WORKGROUP\<HOSTNAME>$" - a machine account.
    # Register-ScheduledTask then either fails or registers a logon-triggered
    # task that can never fire, so the watcher silently never runs.
    $interactiveUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $interactiveUser) {
        throw 'no interactive user is logged on; cannot register the watcher task. Run this after autologon has completed.'
    }
    Write-Log "registering watcher for interactive user $interactiveUser"
    $princ   = New-ScheduledTaskPrincipal -UserId $interactiveUser -RunLevel Highest -LogonType Interactive

    Register-ScheduledTask -TaskName 'xsync-watcher' -Action $action -Trigger $trigger `
        -Settings $set -Principal $princ -Force | Out-Null
    Write-Log 'registered xsync-watcher scheduled task'

}

# ---------------------------------------------------------------- dispatch

switch ($Action) {
    'enumerate' {
        # AppX packages are registered per user, so Get-AppxPackage run as Local
        # System sees essentially nothing - it would report an empty library no
        # matter how many games are installed. Bounce into the user session, have
        # that copy write the result to disk, then read it back.
        $out = Join-Path $XsyncDir 'games.json'
        if (([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem) {
            $shim = Join-Path $XsyncDir 'enumerate-shim.ps1'
            "& '$PSCommandPath' -Action enumerate | Set-Content -Path '$out' -Encoding UTF8" |
                Set-Content -Path $shim -Encoding UTF8
            # Elevated: Get-AppxPackageManifest needs admin to read the manifest,
            # and without it the AUMID cannot be resolved, so every game is
            # silently skipped and the library looks empty. Safe to elevate here
            # because this only reads package metadata - unlike the launch path,
            # which must stay unelevated or UWP apps refuse to start.
            # Delete any previous result first. Otherwise a failed dispatch falls
            # through to Test-Path succeeding against the LAST run's games.json,
            # and a stale library is returned as current with no indication that
            # anything went wrong.
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            $rc = Invoke-InUserSession -Path $shim -TimeoutSeconds 120 -Elevated
            if ($rc -ne 0) { throw "enumerate task in the user session failed with result $rc" }
            if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { Get-Content $out -Raw } else { '[]' }
        } else {
            $games = Get-InstalledXboxGames
            # Force an array so a single game still serialises as a JSON list.
            ConvertTo-Json -InputObject @($games) -Depth 5 -Compress
        }
    }

    'downloading' {
        # Asked by the host before it powers the guest off, on every exit path.
        if (Test-DownloadActive) { 'yes' } else { 'no' }
    }

    'run-user' {
        if (-not $ScriptPath) { throw '-ScriptPath is required for run-user' }
        # Host-driven maintenance (AppX registration, service config) needs admin.
        #
        # Test the result. This emitted LastTaskResult to stdout and exited 0
        # regardless, so a user-session script that failed was reported to the
        # host as a success -- the same defect the 'enumerate' and 'launch' arms
        # were explicitly fixed for. It matters most for the documented FSE
        # procedure: xsync-fse.ps1 exits 1 when the Xbox app is not registered,
        # the operator saw success, rebooted expecting Xbox mode, and got an
        # unchanged desktop with the cause buried in a guest log file.
        $rc = Invoke-InUserSession -Path $ScriptPath -Elevated
        if ($rc -ne 0) { throw "user-session script failed with result $rc" }
    }

    'launch' {
        # Clear any marker left behind by a previous session.
        #
        # The watcher deletes this once it has seen it, but a guest that is killed
        # rather than shut down cleanly leaves it on disk -- and a stale marker
        # means the next session's watcher sees it instantly, skips the wait, and
        # powers off before the host can take the final game list. Exactly the bug
        # this whole mechanism exists to fix, reintroduced by its own leftovers.
        Remove-Item (Join-Path $XsyncDir 'captured') -Force -ErrorAction SilentlyContinue

        # The host reaches us as Local System. Launching a packaged app from there
        # puts no window on the user's desktop, so bounce into the interactive
        # session first and let that copy do the real work.
        if (([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem) {
            Write-Log "running as SYSTEM - re-dispatching launch into the user session"
            $shim = Join-Path $XsyncDir 'launch-shim.ps1'
            # -Encoding UTF8 writes a BOM on Windows PowerShell 5.1, which is what
            # keeps this parseable if the game name carries non-ASCII characters.
            "& '$PSCommandPath' -Action launch -GameId '$GameId'" |
                Set-Content -Path $shim -Encoding UTF8
            # Propagate failure. Discarding this reported "launched" to the host
            # even when the user-session task never ran, so the host tore down
            # the display session and waited for a game that was never started.
            $rc = Invoke-InUserSession -Path $shim -TimeoutSeconds 180
            if ($rc -ne 0) { throw "launch task in the user session failed with result $rc" }
            'launched'
            break
        }

        if ($GameId -eq 'xbox-app' -or [string]::IsNullOrWhiteSpace($GameId)) {
            Start-XboxApp
            Save-State @{ playing = $true; id = 'xbox-app'; name = 'Xbox app'; install_path = $null }
        } else {
            $game = Start-XboxGame -Id $GameId
            if ($game) {
                Save-State @{
                    playing      = $true
                    id           = $game.id
                    name         = $game.name
                    install_path = $game.install_path
                    executable   = $game.executable
                    started_at   = (Get-Date).ToString('o')
                }
            } else {
                # State MUST be saved even when the id did not resolve.
                #
                # Start-XboxGame logs an error, falls back to the Xbox app and
                # returns $null. Skipping Save-State here left the guest with no
                # session state for this boot, so the watcher returned at its
                # boot_id check -- before the try block whose finally calls
                # Stop-Computer. The host's backstop was dead too: status reports
                # playing=false forever, so the exit monitor never armed, while
                # the watchdog stayed happy because the agent still answered
                # pings. The VM held the GPU until XSYNC_MAX_SESSION_SECONDS,
                # twelve hours later, with a black TV.
                #
                # A stale slug is entirely ordinary: shortcuts outlive titles
                # rotating out of Game Pass, and nothing validates the id.
                Write-Log "could not resolve '$GameId' - supervising the Xbox app so there is still a way out" 'WARN'
                Save-State @{
                    playing      = $true
                    id           = 'xbox-app'
                    name         = 'Xbox app'
                    install_path = $null
                    started_at   = (Get-Date).ToString('o')
                }
            }
        }
        # The watcher runs detached so this call can return to the host promptly.
        # Start the watcher as its OWN scheduled task, not as a child process.
        #
        # Start-Process here spawned the watcher as a child of the scheduled task
        # that runs this launch in the user session -- and when a scheduled task
        # completes, the task engine terminates its whole process tree. So the
        # watcher was created and immediately killed, every single time.
        #
        # The symptom is as bad as it gets on a TV: the game runs with no exit
        # overlay at all, so neither the Guide button nor the View+Menu chord
        # does anything, on a machine with no keyboard. Confirmed live with
        # 'watcher procs: 0' while a session was running.
        #
        # xsync-watcher is already registered (Install-Agent) with the right
        # principal and run level, so starting it is enough -- and a task lives
        # in its own tree, outliving whatever asked for it.
        $started = $false
        try {
            Start-ScheduledTask -TaskName 'xsync-watcher' -ErrorAction Stop
            $started = $true
            Write-Log 'watcher started via its scheduled task'
        } catch {
            Write-Log "could not start the xsync-watcher task: $($_.Exception.Message)" 'WARN'
        }
        if (-not $started) {
            # Last resort. Same lifetime problem, but better than no watcher.
            Start-Process 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', "`"$PSCommandPath`"", '-Action', 'watch'
            )
            Write-Log 'watcher started as a child process (may not survive)' 'WARN'
        }
        'launched'
    }

    'status' {
        $state = Get-State
        $playing = $false
        if ($state -and $state.PSObject.Properties['install_path'] -and $state.install_path) {
            $exe = ''
            if ($state.PSObject.Properties['executable']) { $exe = $state.executable }
            $playing = @(Get-GameProcesses -InstallPath $state.install_path -Executable $exe).Count -gt 0
        } elseif ($state) {
            # Xbox-app session: install_path is deliberately null, so the branch
            # above never runs and this used to report playing:false forever.
            #
            # That silently disabled the host's exit monitor for the Xbox app,
            # because the host waits to see playing:true at least once before it
            # will act on playing:false (host/bin/xsync-session). The one
            # independent check on the guest agent doing its job was inert for
            # exactly the session the user gets on a fresh install.
            # Same reasoning as the watcher: a game started from inside the Xbox
            # app keeps the session alive even after the launcher goes away.
            # Without this the HOST's exit monitor would independently decide
            # the session was over and shut the VM down mid-game -- both the
            # guest watcher and its backstop agreeing on the same wrong answer.
            $playing = (@(Get-Process -Name 'XboxPcApp', 'GamingApp', 'Xbox' -ErrorAction SilentlyContinue).Count -gt 0) `
                    -or (@(Get-AnyXboxGameProcess).Count -gt 0)
        }
        [pscustomobject]@{
            playing = $playing
            game    = if ($state -and $state.PSObject.Properties['id']) { $state.id } else { $null }
        } | ConvertTo-Json -Compress
    }

    'watch'   { Start-Watcher }
    'install' { Install-Agent }

    # Show the exit prompt on demand, with no game and no chord.
    #
    # The prompt could previously only be reached by pressing a controller chord
    # during a real session on the TV -- so every check of the one screen the
    # user cannot do without meant booting the play profile, launching a game,
    # and taking over the television. It was tested that way exactly as often as
    # that is convenient, which is to say hardly ever, and it shipped broken
    # three times running: an unreachable type, a leaked return value that read
    # every answer as "quit", and a docking order that hid the instructions.
    #
    # Being able to render it in the maint profile and screenshot the result
    # turns all three of those into a thing a machine can catch.
    'overlay' {
        if (-not (Initialize-XInput)) { Write-Log 'XInput unavailable' 'WARN' }
        $pads = if ('XInputEx' -as [type]) { [XInputEx]::ConnectedCount() } else { 0 }
        Write-Log ("overlay test: {0} controller(s) connected" -f $pads)
        $answer = Show-ExitOverlay
        Write-Log ("overlay test returned: {0}" -f $answer)
        [pscustomobject]@{ controllers = $pads; answer = $answer } | ConvertTo-Json -Compress
    }
}
