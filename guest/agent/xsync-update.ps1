<#
.SYNOPSIS
    xsync - install pending Windows updates in the guest.

.DESCRIPTION
    A guest that is never updated rots, and a Big Picture user has no route to
    Windows Update: no keyboard, no desktop, no Settings app they can reach with
    a gamepad. So the host drives it over qemu-guest-agent instead.

    Uses the Windows Update Agent COM API rather than UsoClient. UsoClient is
    deprecated, undocumented, and -- the part that matters here -- returns
    immediately with no result, so a caller cannot tell success from failure or
    know when it has finished. The COM API reports per-update outcomes and
    whether a reboot is required, which is what makes this automatable at all.

    Deliberately does NOT reboot. The host owns the guest lifecycle: it decides
    when the VM restarts, and a guest rebooting itself mid-handoff would look
    exactly like a crash. The exit code tells the caller what is needed.

.PARAMETER SearchCriteria
    WUA search filter. The default takes software updates only and leaves
    drivers alone -- the GPU driver is installed deliberately by
    xsync-gpu-driver.ps1 at a pinned version, and letting Windows Update
    substitute its own behind that would make the guest's driver state
    unpredictable.

.OUTPUTS
    Exit 0   nothing to do, or updates installed and no reboot needed
    Exit 10  updates installed, REBOOT REQUIRED
    Exit 1   something failed
#>
[CmdletBinding()]
param(
    [string]$SearchCriteria = "IsInstalled=0 and Type='Software' and IsHidden=0",
    [int]$MaxUpdates = 50
)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\update.log'
if (-not (Test-Path 'C:\ProgramData\xsync')) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\xsync' -Force | Out-Null
}
function Say {
    param([string]$m, [string]$l = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $l, $m
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say 'must run elevated' 'ERROR'; exit 1 }

# Servicing health, checked before anything else.
#
# A damaged component store is invisible from every direction that matters: the
# guest boots, games run at full speed, the agent responds, and chkdsk reports a
# perfectly clean filesystem -- because the corruption is logical, in the
# servicing metadata. The only symptom is that updates stop installing, and
# nothing surfaces that until someone goes looking.
#
# This matters beyond one machine: xsync force-destroys the VM in its own
# recovery paths (vm.sh kill, and the watchdog when the guest stops answering),
# and a hard kill during servicing is exactly what produces this. Any user whose
# guest hangs once can end up here, so it has to be detected rather than assumed.
# Match the healthy sentence explicitly rather than grepping for "corrupt".
#
# DISM reports health as "No component store corruption detected." -- which
# contains the word "corruption". A substring match for corrupt|repairable is
# therefore true for BOTH outcomes, and reports a perfectly healthy store as
# damaged. Negation-blind matching on prose is not a check, it is a coin flip
# that happens to land the same way every time.
$health = & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1
$healthText = ($health | Out-String)
$isHealthy = $healthText -match 'No component store corruption detected'
$isDamaged = ($healthText -match 'The component store is repairable') -or
             ($healthText -match 'component store corruption detected' -and -not $isHealthy)

if ($LASTEXITCODE -ne 0 -or $isDamaged -or -not $isHealthy) {
    Say 'COMPONENT STORE IS DAMAGED - updates will not install' 'ERROR'
    ($health | Where-Object { $_ -match 'corrupt|repairable|Error' }) | ForEach-Object { Say "  $_" 'ERROR' }
    Say 'run xsync-repair.ps1, and if that fails repair from install media:'
    Say '  dism /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:6 /LimitAccess'
    exit 2
}

$before = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -EA SilentlyContinue).CurrentBuildNumber
$beforeUBR = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -EA SilentlyContinue).UBR
Say "=== windows update === (currently $before.$beforeUBR)"

# A pending reboot blocks package staging outright, and the failure is
# thoroughly misleading when it happens: Download() returns success without
# downloading anything, then the install fails with 0x80246007
# (WU_E_DM_NOTDOWNLOADED) on a payload that was never fetched, and the servicing
# log says "failed to be changed to the Staged state". Nothing in that chain
# mentions the reboot that actually caused it.
#
# So check first and tell the caller to reboot, rather than burning a download
# and an install attempt to arrive at the same place.
$pendingKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
foreach ($k in $pendingKeys) {
    if (Test-Path $k) {
        Say "a reboot is already pending ($k) - staging will fail until it happens" 'WARN'
        Say 'asking the host to reboot the guest and run again'
        exit 10
    }
}

# The service is Manual/trigger-start by default and may well be stopped.
foreach ($svc in 'wuauserv', 'BITS', 'DoSvc', 'cryptsvc') {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        if ($s.StartType -eq 'Disabled') {
            Say "$svc is Disabled - enabling for this run" 'WARN'
            Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue
        }
        if ($s.Status -ne 'Running') { Start-Service -Name $svc -ErrorAction SilentlyContinue }
    } catch { Say "could not prepare ${svc}: $($_.Exception.Message)" 'WARN' }
}

try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'xsync'
    $searcher = $session.CreateUpdateSearcher()
} catch {
    Say "cannot create an update session: $($_.Exception.Message)" 'ERROR'
    exit 1
}

Say "searching: $SearchCriteria"
try {
    $result = $searcher.Search($SearchCriteria)
} catch {
    Say "search failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

$found = @($result.Updates)
Say "$($found.Count) update(s) available"
if ($found.Count -eq 0) { Say 'nothing to do'; exit 0 }

$toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
$n = 0
foreach ($u in $found) {
    if ($n -ge $MaxUpdates) { Say "capping at $MaxUpdates updates this run" 'WARN'; break }
    # EULAs cannot be accepted interactively here, so accept up front or skip.
    if (-not $u.EulaAccepted) {
        try { $u.AcceptEula() } catch { Say "skipping (EULA): $($u.Title)" 'WARN'; continue }
    }
    $mb = [math]::Round($u.MaxDownloadSize / 1MB)
    Say ("  + {0} ({1} MB)" -f $u.Title, $mb)
    $toInstall.Add($u) | Out-Null
    $n++
}
if ($toInstall.Count -eq 0) { Say 'nothing installable'; exit 0 }

Say "downloading $($toInstall.Count) update(s) - this can take a while"
try {
    $dl = $session.CreateUpdateDownloader()
    $dl.Updates = $toInstall
    $dlr = $dl.Download()
    Say "download result code $($dlr.ResultCode)"   # 2 = succeeded
    if ($dlr.ResultCode -ne 2 -and $dlr.ResultCode -ne 3) {
        Say 'download did not succeed' 'ERROR'; exit 1
    }
} catch {
    Say "download failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

Say 'installing'
try {
    $inst = $session.CreateUpdateInstaller()
    $inst.Updates = $toInstall
    $ir = $inst.Install()
} catch {
    Say "install failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# 2 = succeeded, 3 = succeeded with errors, 4 = failed, 5 = aborted
Say "install result code $($ir.ResultCode), reboot required: $($ir.RebootRequired)"
for ($i = 0; $i -lt $toInstall.Count; $i++) {
    try {
        $r  = $ir.GetUpdateResult($i)
        $rc = $r.ResultCode
        $tag = switch ($rc) { 2 { 'ok' } 3 { 'ok (with errors)' } 4 { 'FAILED' } 5 { 'aborted' } default { "rc=$rc" } }
        # The HRESULT is the only part that says anything useful about WHY.
        # Logging just the result code, as this did, turns a diagnosable failure
        # into "it didn't work".
        $hr = '0x{0:X8}' -f $r.HResult
        Say ("  {0}  hr={1}  {2}" -f $tag, $hr, $toInstall.Item($i).Title)
    } catch { }
}

if ($ir.ResultCode -eq 4 -or $ir.ResultCode -eq 5) {
    Say 'installation failed' 'ERROR'
    exit 1
}

if ($ir.RebootRequired) {
    Say 'REBOOT REQUIRED - the host will restart the guest'
    exit 10
}

Say 'done, no reboot required'
exit 0
