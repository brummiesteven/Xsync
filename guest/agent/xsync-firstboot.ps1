<#
.SYNOPSIS
    xsync - first-boot setup, run once from the xsync unattend disc.

.DESCRIPTION
    autounattend.xml hands off here rather than running a list of hardcoded
    commands, for two reasons:

      * Drive letters are not deterministic. Both the virtio disc and this one
        get whatever letters Windows feels like assigning, so both are located
        by volume label / content search rather than assumed.
      * FirstLogonCommands failures are effectively invisible. Sequencing this
        in PowerShell means every step is logged to a file that can be read
        afterwards to see what actually happened.

    Steps run in dependency order: virtio guest tools first (they provide
    qemu-guest-agent, which is how the host talks to this VM at all), then
    debloat, then the agent, then Game Pass provisioning.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$XsyncDir = 'C:\ProgramData\xsync'
$LogFile  = Join-Path $XsyncDir 'firstboot.log'
if (-not (Test-Path $XsyncDir)) { New-Item -ItemType Directory -Path $XsyncDir -Force | Out-Null }

function Say {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

Say '=== xsync first-boot setup starting ==='

# ------------------------------------------------------------- locate media

# Where this script is running from is the xsync disc, by definition.
$Self = Split-Path -Parent $PSCommandPath
Say "xsync disc: $Self"

function Find-VirtioRoot {
    # Prefer the guest-tools installer as the marker: it only exists at the root
    # of the virtio-win ISO, so finding it identifies the disc unambiguously.
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $candidate = Join-Path $d.Root 'virtio-win-guest-tools.exe'
        if (Test-Path $candidate) { return $d.Root }
    }
    return $null
}

$VirtioRoot = Find-VirtioRoot
if ($VirtioRoot) { Say "virtio disc: $VirtioRoot" }
else { Say 'virtio disc not found - guest agent will be unavailable' 'ERROR' }

# ------------------------------------------------------------- steps

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Say "--- $Name ---"
    try {
        $global:LASTEXITCODE = 0
        & $Body
        # An external command that fails does not throw, so without this a script
        # that died on a parse error is cheerfully reported as "ok" - which is
        # exactly how a broken provisioning step went unnoticed once already.
        if ($LASTEXITCODE -ne 0) {
            throw "exited with code $LASTEXITCODE"
        }
        Say "${Name}: ok"
    } catch {
        # A failed step must not abort the rest: a VM that boots with, say, no
        # debloat is recoverable, whereas one that stops half-configured is not.
        Say "${Name}: FAILED - $($_.Exception.Message)" 'ERROR'
    }
}

# This is the important one. qemu-guest-agent is the host's only control channel;
# without it the VM boots but xsync cannot launch games, enumerate the library, or
# tell whether the guest is alive.
Invoke-Step 'virtio guest tools' {
    if (-not $VirtioRoot) { throw 'virtio disc not present' }
    $exe = Join-Path $VirtioRoot 'virtio-win-guest-tools.exe'
    $p = Start-Process -FilePath $exe -ArgumentList '/install', '/passive', '/norestart' -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "installer exited with $($p.ExitCode)"
    }
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name 'QEMU-GA' -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
        Say 'qemu-guest-agent running'
    } else {
        Say 'qemu-guest-agent service not found after install' 'WARN'
    }
}

Invoke-Step 'clock' {
    # Read the RTC as UTC, matching <clock offset='utc'/> in the domain.
    #
    # Without this pair the guest takes the HOST's wall-clock time and reinterprets
    # it in its own timezone. On the reference machine (host Asia/Muscat +04, guest
    # Europe/London +01) that put the guest three hours ahead of real UTC, and it
    # is not cosmetic: Microsoft Store licence validation is time-sensitive.
    # Sunset Overdrive returned 0x80070BFF ("a licensing operation is being
    # performed") on nine consecutive activations and launched on the first
    # attempt once the clock was corrected. Titles whose licences were already
    # cached were unaffected, which is what made it look title-specific.
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' `
        -Name 'RealTimeIsUniversal' -Value 1 -Type DWord -Force
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' `
        -Name RealTimeIsUniversal -ErrorAction SilentlyContinue).RealTimeIsUniversal
    if ($v -ne 1) { throw 'RealTimeIsUniversal did not stick' }
    Say 'RealTimeIsUniversal=1'

    # Belt and braces: keep it corrected even if the RTC drifts.
    Set-Service -Name w32time -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name w32time -ErrorAction SilentlyContinue
    w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:manual /update 2>&1 | Out-Null
    w32tm /resync /force 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
    Say ("guest UTC now {0}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
}

Invoke-Step 'power configuration' {
    # Fast startup makes "shutdown" a hibernate, which would leave the VM holding
    # the GPU. The host's whole lifecycle depends on a real power-off.
    #
    # Invoke-Step only inspects $LASTEXITCODE once, after the whole block, so a
    # chain of native commands only ever reports the last one. That made the
    # single most important line here - `powercfg /h off` - fail invisibly.
    # Check it directly, and verify the outcome rather than trusting the code.
    powercfg /h off 2>&1 | Out-Null
    $hiberboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($null -ne $hiberboot -and $hiberboot -ne 0) {
        throw 'fast startup is still enabled; guest "shutdown" would hibernate and keep the GPU'
    }
    Say 'fast startup disabled (shutdown is a real power-off)'

    powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
    powercfg /change monitor-timeout-ac 0 2>&1 | Out-Null
    powercfg /change disk-timeout-ac 0 2>&1 | Out-Null
    # Swallow any residual non-zero from the timeout calls; they are advisory.
    $global:LASTEXITCODE = 0
}

Invoke-Step 'debloat' {
    $s = Join-Path $Self 'xsync-debloat.ps1'
    if (-not (Test-Path $s)) { throw "not found: $s" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s
}

Invoke-Step 'appearance' {
    # Runs after debloat so it has the last word on the taskbar, and before the
    # agent so the very first handoff already shows a black screen rather than a
    # desktop. Explorer is left alone here because first boot restarts it anyway.
    $s = Join-Path $Self 'xsync-appearance.ps1'
    if (-not (Test-Path $s)) { throw "not found: $s" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s -NoRestartExplorer
}

Invoke-Step 'install xsync agent' {
    $s = Join-Path $Self 'xsync-agent.ps1'
    if (-not (Test-Path $s)) { throw "not found: $s" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s -Action install
}

Invoke-Step 'provision Game Pass components' {
    $s = Join-Path $Self 'xsync-provision.ps1'
    if (-not (Test-Path $s)) { throw "not found: $s" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s
}

Invoke-Step 'Xbox full screen experience' {
    # The console-style shell. This is the thing that makes the guest look like
    # an Xbox rather than a Windows desktop, and it was the last step still being
    # done by hand -- written, working, and called by nothing.
    #
    # It was held back originally because it re-binds Guide to the FSE task
    # switcher, which would have broken the Guide exit overlay. Both halves of
    # that objection are gone: the overlay was removed, and the exit chord now
    # reads the pad through Raw Input, which was verified working underneath FSE.
    #
    # Non-fatal on purpose. The feature ids depend on the Windows build, so on an
    # unexpected build this can legitimately do nothing -- and a guest that boots
    # to a normal desktop is a cosmetic disappointment, not a broken install.
    if (-not (Test-Path (Join-Path $Self 'fse.enabled'))) {
        Say 'FSE not enabled in config - skipping'
        return
    }
    $s = Join-Path $Self 'xsync-fse.ps1'
    if (-not (Test-Path $s)) { Say "not found: $s" 'WARN'; return }
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s
        Say 'FSE applied - takes effect after the next guest reboot'
    } catch {
        Say "FSE setup failed (continuing): $($_.Exception.Message)" 'WARN'
    }
}

# Leave a marker the host can read to confirm setup actually completed, rather
# than inferring it from the VM merely having booted.
@{
    completed_at = (Get-Date).ToString('o')
    virtio_root  = $VirtioRoot
    xsync_disc   = $Self
} | ConvertTo-Json | Set-Content -Path (Join-Path $XsyncDir 'firstboot-complete.json') -Encoding UTF8

Say '=== xsync first-boot setup complete ==='
Say 'Remaining manual step: sign into the Xbox app with your Microsoft account.'
