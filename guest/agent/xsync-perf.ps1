<#
.SYNOPSIS
    xsync - record real frame timings for a play session.

.DESCRIPTION
    GPU utilisation is not framerate. A card sitting at 56% might be comfortably
    vsync-locked at 60fps with headroom, or it might be CPU-bound and dropping
    frames -- the number looks identical either way. That ambiguity cost real
    time during one performance investigation, where the only evidence available
    was utilisation and clocks, and three separate theories were chased before
    the actual cause turned up in an event log.

    PresentMon reads Windows' presentation ETW stream, so it records every frame
    the game actually puts on screen: frame times, presentation mode, and
    latency. No overlay, no injection into the game, no configuration by the
    user.

    Frame TIMES matter more than average FPS here. A VM whose vCPUs float across
    CCDs produces occasional long frames while the average stays respectable --
    exactly the stutter XSYNC_VM_CPUSET exists to prevent, and exactly what an
    average hides. The 1% lows are the number worth watching.

.PARAMETER Action
    start   begin capturing for a process
    stop    stop any running capture
    summary print avg/p95/p99 frame times from the newest capture

.PARAMETER ProcessName
    Executable to watch, e.g. forzahorizon6.exe. Without it, PresentMon captures
    every presenting process, which is noisier but still useful.
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'summary')]
    [string]$Action = 'summary',
    [string]$ProcessName = '',
    [string]$PresentMon = 'C:\ProgramData\xsync\PresentMon.exe',
    [string]$OutDir = 'C:\ProgramData\xsync\perf'
)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\perf.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}
function Say {
    param([string]$m, [string]$l = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $l, $m
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Stop-Capture {
    $procs = @(Get-Process -Name 'PresentMon*' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $false }
    foreach ($p in $procs) {
        # PresentMon flushes its CSV on a clean exit; killing it outright can
        # truncate the last rows, so ask first.
        try { $p.CloseMainWindow() | Out-Null } catch { }
    }
    Start-Sleep -Seconds 2
    foreach ($p in @(Get-Process -Name 'PresentMon*' -ErrorAction SilentlyContinue)) {
        try { $p.Kill() } catch { }
    }
    return $true
}

switch ($Action) {

    'start' {
        if (-not (Test-Path $PresentMon)) {
            # Absent is not an error: performance logging is optional, and a
            # missing tool must never stop a game from launching.
            Say "PresentMon not present at $PresentMon - skipping capture"
            exit 0
        }
        New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction SilentlyContinue | Out-Null
        Stop-Capture | Out-Null

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $tag   = if ($ProcessName) { ($ProcessName -replace '\.exe$', '') } else { 'session' }
        $csv   = Join-Path $OutDir "$stamp-$tag.csv"

        $args = @('--output_file', "`"$csv`"", '--stop_existing_session', '--terminate_on_proc_exit')
        if ($ProcessName) { $args += @('--process_name', $ProcessName) }

        try {
            Start-Process -FilePath $PresentMon -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop
            Say "capturing to $csv (process: $(if ($ProcessName) { $ProcessName } else { 'all' }))"
        } catch {
            Say "could not start PresentMon: $($_.Exception.Message)" 'WARN'
        }
        exit 0
    }

    'stop' {
        if (Stop-Capture) { Say 'capture stopped' } else { Say 'no capture running' }
        exit 0
    }

    'summary' {
        if (-not (Test-Path $OutDir)) { Say 'no captures'; exit 0 }
        $latest = Get-ChildItem $OutDir -Filter '*.csv' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { Say 'no captures'; exit 0 }

        $rows = @(Import-Csv $latest.FullName -ErrorAction SilentlyContinue)
        if ($rows.Count -eq 0) { Say "empty capture: $($latest.Name)" 'WARN'; exit 0 }

        # Column naming differs between PresentMon 1.x and 2.x.
        $col = @('msBetweenPresents', 'MsBetweenPresents', 'FrameTime') |
               Where-Object { $rows[0].PSObject.Properties.Name -contains $_ } |
               Select-Object -First 1
        if (-not $col) {
            Say "no frame-time column in $($latest.Name); columns: $(($rows[0].PSObject.Properties.Name) -join ',')" 'WARN'
            exit 0
        }

        $ft = @($rows | ForEach-Object { [double]$_.$col } | Where-Object { $_ -gt 0 } | Sort-Object)
        if ($ft.Count -lt 10) { Say 'too few frames to summarise' 'WARN'; exit 0 }

        $avg = ($ft | Measure-Object -Average).Average
        # Percentiles on frame TIME: the 99th percentile frame time is the worst
        # frames, i.e. the 1% low expressed the useful way round.
        $p95 = $ft[[int][math]::Floor($ft.Count * 0.95)]
        $p99 = $ft[[int][math]::Floor($ft.Count * 0.99)]

        Say "capture: $($latest.Name)  frames=$($ft.Count)"
        Say ("  avg   {0,7:N2} ms  ({1,6:N1} fps)" -f $avg, (1000 / $avg))
        Say ("  p95   {0,7:N2} ms  ({1,6:N1} fps)" -f $p95, (1000 / $p95))
        Say ("  p99   {0,7:N2} ms  ({1,6:N1} fps)   <- the stutter number" -f $p99, (1000 / $p99))
        exit 0
    }
}
