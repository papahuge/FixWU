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
    4. (Optional) Resets the WinHTTP proxy and Winsock catalog.
    5. Restarts only the services that were running before.

.PARAMETER ResetNetwork
    Also reset the WinHTTP proxy and Winsock catalog. Needs a reboot, and can
    break VPN clients or a proxy you configured on purpose.

.PARAMETER Repair
    Also run DISM /RestoreHealth and SFC afterwards. Slow (10-30+ minutes).

.PARAMETER IgnorePendingReboot
    Run even if Windows is waiting on a reboot to finish installing updates.

.EXAMPLE
    FixWU
    Runs the reset (via the FixWU shortcut in your PowerShell profile).

.EXAMPLE
    FixWU -Repair
    Runs the reset, then repairs system files with DISM and SFC.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FixWU.ps1
    Runs the script directly from an admin terminal.
#>
[CmdletBinding()]
param(
    [switch]$ResetNetwork,
    [switch]$Repair,
    [switch]$IgnorePendingReboot
)

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
Start-Transcript -Path $logPath | Out-Null

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
        # Leftover from an earlier run - clear it so only one backup is kept.
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

Write-Host "==========================================" -ForegroundColor $Theme.Frame
Write-Host "       FixWU - Windows Update Reset       " -ForegroundColor $Theme.Frame
Write-Host "==========================================" -ForegroundColor $Theme.Frame

# ---------------------------------------------------------------------------
# 1. Pre-flight: look for causes that clearing caches won't fix
# ---------------------------------------------------------------------------
Write-Step "[1/5] Checking for problems a reset can't fix..."

$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
if ($rebootKeys | Where-Object { Test-Path $_ }) {
    if (-not $IgnorePendingReboot) {
        Write-Warning "Windows is waiting on a reboot to finish installing updates."
        Write-Warning "Reboot first and try Windows Update again - that alone often unsticks it."
        Write-Warning "Wiping the update cache now could confuse the half-finished install."
        Write-Warning "(Run with -IgnorePendingReboot to reset anyway.)"
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
Write-Host "  - Once updates work, delete SoftwareDistribution.old (in $env:SystemRoot)"
Write-Host "    and catroot2.old (in $env:SystemRoot\System32) to get the space back."
Write-Host "`n Log saved to: $logPath"
Write-Host "==========================================" -ForegroundColor $Theme.Frame
Close-Log
if ($failures.Count) { exit 1 }
