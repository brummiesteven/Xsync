<#
.SYNOPSIS
    xsync - repair the Windows component store and reset the update cache.

.DESCRIPTION
    Run when an update fails with a corruption HRESULT -- 0x80070570
    (ERROR_FILE_CORRUPT) being the usual one. Two independent things can be
    wrong and both are worth fixing before retrying:

      1. The component store (WinSxS) is damaged, so servicing cannot apply the
         package. DISM /RestoreHealth repairs it against Windows Update.
      2. The downloaded payload in SoftwareDistribution is itself corrupt, in
         which case Windows will cheerfully re-use the bad copy forever.
         Renaming the folder forces a genuinely fresh download.

    A VM that has been force-killed mid-servicing is a strong candidate for
    both. This guest was hard-stopped several times during passthrough testing.

    Long-running: DISM alone can take twenty minutes or more. It reports
    progress to stdout, which the host captures.

.PARAMETER SkipCache
    Repair the store but leave SoftwareDistribution alone.
#>
[CmdletBinding()]
param([switch]$SkipCache)

$ErrorActionPreference = 'Continue'
$LogFile = 'C:\ProgramData\xsync\repair.log'
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

Say '=== component store repair ==='

Say 'checking store health (DISM /ScanHealth)'
& dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 |
    Where-Object { $_ -match 'corrupt|Error|error|completed|repairable' } |
    ForEach-Object { Say "  $_" }

Say 'repairing (DISM /RestoreHealth) - this can take 20+ minutes'
& dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 |
    Where-Object { $_ -match 'corrupt|Error|error|completed|repaired|source' } |
    ForEach-Object { Say "  $_" }
$dismRc = $LASTEXITCODE
Say "DISM exit code: $dismRc"

Say 'verifying system files (sfc /scannow)'
& sfc.exe /scannow 2>&1 |
    Where-Object { $_ -match 'violation|corrupt|repaired|did not find|unable' } |
    ForEach-Object { Say "  $($_ -replace '\0','')" }

if (-not $SkipCache) {
    Say '--- resetting the update cache ---'
    # A corrupt payload is re-used indefinitely unless the folder is moved
    # aside; Windows recreates both directories on the next scan.
    foreach ($svc in 'wuauserv', 'bits', 'cryptsvc', 'msiserver') {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($d in @('C:\Windows\SoftwareDistribution', 'C:\Windows\System32\catroot2')) {
        if (Test-Path $d) {
            try {
                Rename-Item -Path $d -NewName "$(Split-Path $d -Leaf).xsync-$stamp" -Force -ErrorAction Stop
                Say "moved aside: $d"
            } catch {
                Say "could not move $d : $($_.Exception.Message)" 'WARN'
            }
        }
    }
    foreach ($svc in 'cryptsvc', 'bits', 'wuauserv') {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
    }
    Say 'update cache reset'
}

Say '=== repair finished - retry the update ==='
exit 0
