#Requires -RunAsAdministrator
<#
.SYNOPSIS
    FixWU - resets a stuck Windows Update download queue.

.DESCRIPTION
    1. Checks for causes a cache reset can't fix (pending reboot, disabled
       service, WSUS / blocking policy, paused updates) and reports them.
    2. Clears the BITS and Delivery Optimization download queues.
    3. Stops the update services, then renames SoftwareDistribution and
       catroot2 to *.old. Windows rebuilds both; the .old copies are your undo.
       A backup left by an earlier run is replaced, so there's only ever one.
    4. (Optional) Resets the WinHTTP proxy and Winsock catalog.
    5. Restarts only the services that were running before.

    Once updates work again, run it with -Cleanup to delete the .old backups.

.PARAMETER ResetNetwork
    Also reset the WinHTTP proxy and Winsock catalog. Needs a reboot, and can
    break VPN clients or a proxy you configured on purpose.

.PARAMETER Repair
    Also run DISM /RestoreHealth and SFC afterwards. Slow (10-30+ minutes).

.PARAMETER Force
    Run even if Windows is waiting on a reboot to finish installing updates.

.PARAMETER Cleanup
    Delete the .old backups left by earlier resets and report the space freed.
    Doesn't run a reset. Add -WhatIf to preview, or -Confirm to approve each one.

.EXAMPLE
    FixWU
    Runs the reset (via the FixWU shortcut in your PowerShell profile).

.EXAMPLE
    FixWU -Repair
    Runs the reset, then repairs system files with DISM and SFC.

.EXAMPLE
    FixWU -Cleanup -WhatIf
    Shows which .old backups -Cleanup would delete, without deleting anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FixWU.ps1
    Runs the script directly from an admin terminal.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Reset')]
param(
    [Parameter(ParameterSetName = 'Reset')]
    [switch]$ResetNetwork,

    [Parameter(ParameterSetName = 'Reset')]
    [switch]$Repair,

    [Parameter(ParameterSetName = 'Reset')]
    [switch]$Force,

    # Its own parameter set, so -Cleanup can't be mixed with the reset switches.
    [Parameter(ParameterSetName = 'Cleanup', Mandatory)]
    [switch]$Cleanup
)

# -WhatIf / -Confirm only work with -Cleanup. The reset calls tools such as
# bitsadmin and netsh that can't "pretend", so a reset -WhatIf would be a lie.
if (-not $Cleanup -and ($PSBoundParameters.ContainsKey('WhatIf') -or $PSBoundParameters.ContainsKey('Confirm'))) {
    Write-Warning "-WhatIf and -Confirm only work together with -Cleanup."
    exit 1
}

# Color theme: Blue / Teal / HotPink.
# Write-Host only knows the 16 console colors, so Teal and HotPink use the
# closest matches (Cyan and Magenta). Change any of these in one place.
$Theme = @{
    Frame = 'Blue'      # banner and borders
    Step  = 'Magenta'   # step headings   (HotPink)
    Good  = 'Cyan'      # success lines   (Teal)
    Warn  = 'Yellow'    # matches Write-Warning, so problems still stand out
    Bad   = 'Red'       # failures
}

$cantFix  = [System.Collections.Generic.List[string]]::new()   # causes a reset won't solve
$failures = [System.Collections.Generic.List[string]]::new()   # steps that didn't work
$logPath  = Join-Path $env:TEMP ("FixWU_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
# Always log for real, even in a -Cleanup -WhatIf / -Confirm preview. Setting
# the preferences inside this block works on every PowerShell version (passing
# -WhatIf:$false doesn't: some versions' transcript cmdlets lack the switch).
& { $WhatIfPreference = $false; $ConfirmPreference = 'None'; Start-Transcript -Path $logPath | Out-Null }

# UsoSvc (Update Orchestrator) is listed first so it gets stopped first:
# left running, it can restart wuauserv behind our back mid-reset.
$services   = 'UsoSvc', 'wuauserv', 'bits', 'cryptsvc'
$wasRunning = @(Get-Service -Name $services -ErrorAction SilentlyContinue |
                Where-Object Status -eq 'Running' |
                ForEach-Object Name)

$cacheFolders = @(
    "$env:SystemRoot\SoftwareDistribution",
    "$env:SystemRoot\System32\catroot2"
)

function Write-Step([string]$Text) { Write-Host "`n$Text" -ForegroundColor $Theme.Step }

# Stops the log, then makes sure you can open it from a normal window. Files
# created from an admin window can end up readable only by admins, depending
# on the folder's permissions.
function Close-Log {
    # In PowerShell 7, Stop-Transcript obeys -WhatIf: during a -Cleanup -WhatIf
    # it would "pretend" to stop and leave the log running in your session.
    $WhatIfPreference = $false; $ConfirmPreference = 'None'
    Stop-Transcript | Out-Null
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    icacls.exe $logPath /grant "*${me}:(R)" 2>$null | Out-Null
}

function Stop-UpdateServices {
    foreach ($name in $services) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -eq 'Stopped') { continue }
        try {
            Stop-Service -InputObject $svc -Force -ErrorAction Stop -WarningAction SilentlyContinue
        } catch {
            Write-Warning "  Couldn't stop ${name}: $($_.Exception.Message)"
        }
    }
}

# Renames a folder to <name>.old. Returns $true when the folder is out of the
# way (moved, or never existed) and $false if something still has it locked.
function Move-Aside([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $backup = "$Path.old"
    if (Test-Path -LiteralPath $backup) {
        # Leftover from an earlier run - replace it so only one backup is kept.
        $old = Get-Item -LiteralPath $backup -Force
        Write-Host ("  Replacing {0} from your last run ({1:MMM d, yyyy}, {2})" -f
                    $old.Name, $old.LastWriteTime, (Format-Size (Get-FolderSize $backup)))
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $backup) {
            $backup = "$Path.old-$(Get-Date -Format yyyyMMddHHmmss)"
        }
    }
    try {
        Rename-Item -LiteralPath $Path -NewName (Split-Path $backup -Leaf) -ErrorAction Stop
        Write-Host "  $(Split-Path $Path -Leaf) -> $(Split-Path $backup -Leaf)" -ForegroundColor $Theme.Good
        return $true
    } catch {
        Write-Warning "  Couldn't move $(Split-Path $Path -Leaf) yet: $($_.Exception.Message)"
        return $false
    }
}

function Get-FolderSize([string]$Path) {
    [double](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
}

function Format-Size([double]$Bytes) {
    if     ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) }
    else                    { '{0:N0} KB' -f ($Bytes / 1KB) }
}

# Finds SoftwareDistribution.old / catroot2.old, plus any date-stamped
# .old-<time> copies made when an old backup couldn't be replaced.
function Get-OldBackups {
    foreach ($folder in $cacheFolders) {
        Get-ChildItem -LiteralPath (Split-Path $folder -Parent) -Directory -Force `
                      -Filter "$(Split-Path $folder -Leaf).old*" -ErrorAction SilentlyContinue
    }
}

# Deletes the .old backups. ShouldProcess gives it -WhatIf and -Confirm, and
# it picks those up from the script when FixWU is run with them.
function Invoke-Cleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $backups = @(Get-OldBackups)
    if ($backups.Count -eq 0) {
        Write-Host "  No .old backups found - nothing to clean up." -ForegroundColor $Theme.Good
        return
    }
    $freed = 0
    foreach ($b in $backups) {
        $size = Get-FolderSize $b.FullName
        if (-not $PSCmdlet.ShouldProcess($b.FullName, "Delete backup ($(Format-Size $size))")) { continue }
        Remove-Item -LiteralPath $b.FullName -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $b.FullName) {
            $failures.Add("Couldn't fully delete $($b.FullName) - some files are in use. Try again after a reboot.")
        } else {
            Write-Host "  Deleted $($b.Name) ($(Format-Size $size))" -ForegroundColor $Theme.Good
            $freed += $size
        }
    }
    if ($freed -gt 0) { Write-Host "  Freed $(Format-Size $freed)." -ForegroundColor $Theme.Good }
}

Write-Host "==========================================" -ForegroundColor $Theme.Frame
Write-Host "       FixWU - Windows Update Reset       " -ForegroundColor $Theme.Frame
Write-Host "==========================================" -ForegroundColor $Theme.Frame

# ---------------------------------------------------------------------------
# Cleanup mode: delete the .old backups from earlier resets, then stop.
# ---------------------------------------------------------------------------
if ($Cleanup) {
    Write-Step "Deleting .old backups from earlier resets..."
    Invoke-Cleanup
    Write-Host "`n==========================================" -ForegroundColor $Theme.Frame
    if ($failures.Count) {
        foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor $Theme.Bad }
    } elseif ($WhatIfPreference) {
        Write-Host " Preview only (-WhatIf): nothing was deleted." -ForegroundColor $Theme.Good
    } else {
        Write-Host " Cleanup complete." -ForegroundColor $Theme.Good
    }
    Write-Host "==========================================" -ForegroundColor $Theme.Frame
    Close-Log
    if ($failures.Count) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Pre-flight: look for causes that clearing caches won't fix
# ---------------------------------------------------------------------------
Write-Step "[1/5] Checking for problems a reset can't fix..."

$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
if ($rebootKeys | Where-Object { Test-Path $_ }) {
    if (-not $Force) {
        Write-Warning "Windows is waiting on a reboot to finish installing updates."
        Write-Warning "Reboot first and try Windows Update again - that alone often unsticks it."
        Write-Warning "Wiping the update cache now could confuse the half-finished install."
        Write-Warning "(Run with -Force to reset anyway.)"
        Close-Log
        exit 1
    }
    $cantFix.Add("A reboot was already pending when this ran - reboot before checking for updates.")
}

$wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
if (-not $wuService) {
    $cantFix.Add("The Windows Update service (wuauserv) is missing entirely.")
} elseif ($wuService.StartType -eq 'Disabled') {
    $cantFix.Add("The Windows Update service is DISABLED (update-blocker tools do this). Re-enable it with:  Set-Service wuauserv -StartupType Manual")
}

$policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$policy    = Get-ItemProperty -Path $policyKey -ErrorAction SilentlyContinue
$auPolicy  = Get-ItemProperty -Path "$policyKey\AU" -ErrorAction SilentlyContinue
if ($auPolicy.UseWUServer -eq 1 -and $policy.WUServer) {
    $cantFix.Add("Group Policy points updates at a WSUS server ($($policy.WUServer)). If that server is gone, downloads will keep failing.")
}
if ($policy.DoNotConnectToWindowsUpdateInternetLocations -eq 1) {
    $cantFix.Add("Group Policy blocks connecting to Windows Update over the internet.")
}
if ($policy.DisableWindowsUpdateAccess -eq 1) {
    $cantFix.Add("Group Policy has turned off access to Windows Update.")
}

$ux = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue
$pausedUntil = [datetime]::MinValue
if ($ux.PauseUpdatesExpiryTime -and
    [datetime]::TryParse($ux.PauseUpdatesExpiryTime, [ref]$pausedUntil) -and
    $pausedUntil -gt (Get-Date)) {
    $cantFix.Add("Updates are paused until $pausedUntil. Click 'Resume updates' in Settings > Windows Update.")
}

if ($cantFix.Count) {
    foreach ($item in $cantFix) { Write-Warning $item }
} else {
    Write-Host "  Nothing found." -ForegroundColor $Theme.Good
}

# ---------------------------------------------------------------------------
# 2. Clear the download queues. BITS and Delivery Optimization need their
#    services running for this, so it happens before anything is stopped.
# ---------------------------------------------------------------------------
Write-Step "[2/5] Clearing download queues..."

& "$env:SystemRoot\System32\bitsadmin.exe" /reset /allusers | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  BITS queue cleared." -ForegroundColor $Theme.Good
} else {
    $failures.Add("bitsadmin /reset exited with code $LASTEXITCODE.")
}

if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
    try {
        # This cmdlet prints its own "Deleting..." lines with Write-Host, which
        # goes to the information stream (6), not the output that Out-Null eats.
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop 6>$null | Out-Null
        Write-Host "  Delivery Optimization cache cleared." -ForegroundColor $Theme.Good
    } catch {
        $failures.Add("Couldn't clear the Delivery Optimization cache: $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# 3. Stop services and move the caches aside. Windows sometimes restarts a
#    service (or grabs a file) between the stop and the rename, so retry.
# ---------------------------------------------------------------------------
Write-Step "[3/5] Stopping update services and moving caches aside..."

$remaining = $cacheFolders
for ($attempt = 1; $attempt -le 3 -and $remaining.Count -gt 0; $attempt++) {
    if ($attempt -gt 1) {
        Write-Host "  Something grabbed a file - stopping services again (attempt $attempt of 3)..."
        Start-Sleep -Seconds 5
    }
    Stop-UpdateServices
    $remaining = @($remaining | Where-Object { -not (Move-Aside $_) })
}
foreach ($folder in $remaining) {
    $failures.Add("Couldn't move $folder aside (a file in it stayed locked).")
}

# ---------------------------------------------------------------------------
# 4. Optional: network stack reset
# ---------------------------------------------------------------------------
if ($ResetNetwork) {
    Write-Step "[4/5] Resetting WinHTTP proxy and Winsock catalog..."
    netsh.exe winhttp reset proxy | Out-Null
    if ($LASTEXITCODE -ne 0) { $failures.Add("netsh winhttp reset proxy exited with code $LASTEXITCODE.") }
    netsh.exe winsock reset | Out-Null
    if ($LASTEXITCODE -ne 0) { $failures.Add("netsh winsock reset exited with code $LASTEXITCODE.") }
} else {
    Write-Step "[4/5] Skipping network reset (add -ResetNetwork to include it)."
}

# ---------------------------------------------------------------------------
# 5. Put services back the way they were. Ones that weren't running are
#    trigger-started and will wake up on their own when needed.
# ---------------------------------------------------------------------------
Write-Step "[5/5] Restarting services..."
foreach ($name in 'cryptsvc', 'bits', 'wuauserv', 'UsoSvc') {
    if ($wasRunning -notcontains $name) { continue }
    try {
        # -WarningAction hides the harmless "Waiting for service to start..." note
        Start-Service -Name $name -ErrorAction Stop -WarningAction SilentlyContinue
        Write-Host "  Started $name" -ForegroundColor $Theme.Good
    } catch {
        $failures.Add("Couldn't restart ${name}: $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# Optional: repair the component store. Runs after the restart because DISM
# downloads clean copies of damaged files through Windows Update.
# ---------------------------------------------------------------------------
if ($Repair) {
    Write-Step "Repairing system files (DISM, then SFC). This takes a while - let it finish."
    DISM.exe /Online /Cleanup-Image /RestoreHealth
    if ($LASTEXITCODE -ne 0) { $failures.Add("DISM /RestoreHealth exited with code $LASTEXITCODE.") }
    sfc.exe /scannow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n==========================================" -ForegroundColor $Theme.Frame
if ($failures.Count -eq 0) {
    Write-Host " Reset complete." -ForegroundColor $Theme.Good
} else {
    Write-Host " Reset finished with problems:" -ForegroundColor $Theme.Bad
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor $Theme.Bad }
}
if ($cantFix.Count) {
    Write-Host "`n Still needs your attention (a reset can't fix these):" -ForegroundColor $Theme.Warn
    foreach ($c in $cantFix) { Write-Host "  - $c" -ForegroundColor $Theme.Warn }
}
Write-Host "`n Next:" -ForegroundColor $Theme.Frame
if ($ResetNetwork) {
    Write-Host "  - Restart your PC (the Winsock reset needs it)."
}
Write-Host "  - Open Settings > Windows Update and click 'Check for updates'."
Write-Host "    The first check after a reset rebuilds everything, so give it a few"
Write-Host "    minutes. If Settings sits on 'Checking for updates...', close it and"
Write-Host "    reopen it: the check has usually finished in the background already."
$backups = @(Get-OldBackups)
if ($backups.Count) {
    $backupSize = 0
    foreach ($b in $backups) { $backupSize += Get-FolderSize $b.FullName }
    Write-Host "  - Once updates work, run FixWU with -Cleanup to delete the .old backups"
    Write-Host "    and get $(Format-Size $backupSize) back."
}
Write-Host "`n Log saved to: $logPath"
Write-Host "==========================================" -ForegroundColor $Theme.Frame
Close-Log
if ($failures.Count) { exit 1 }
