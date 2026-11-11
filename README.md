# FixWU

Resets a stuck Windows Update queue, for when updates hang at 0% or won't download.

FixWU checks that each step actually worked, tells you about problems a reset
*can't* fix, and renames the update caches instead of deleting them, so nothing
is lost.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- Administrator rights

## Install

1. Download `FixWU.ps1` (open it on GitHub and click **Download raw file**).
2. Save it somewhere permanent, for example `C:\Users\<you>\Tools\FixWU.ps1`.
3. **Unblock it.** Don't skip this step:

   ```powershell
   Unblock-File "$HOME\Tools\FixWU.ps1"
   ```

   Or right-click the file > **Properties** > tick **Unblock** > **OK**.

> **Why unblock?** Windows tags files downloaded through a browser as coming
> "from the internet," and PowerShell refuses to run them, with an error like
> *"FixWU.ps1 is not digitally signed. You cannot run this script on the current
> system."* `Unblock-File` removes the tag. You only need to do it once per download.
>
> Downloaded the whole repo as a **.zip**? Unblock the .zip *before* extracting it,
> because extracted files inherit the tag. Cloned with `git clone`? Git doesn't
> tag files, so there's nothing to unblock.

## Usage

Open an **admin** terminal (right-click Start > **Terminal (Admin)**), then run:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Tools\FixWU.ps1"
```

Add any option to the end of that line, e.g. `... FixWU.ps1 -Repair`.
`-ExecutionPolicy Bypass` applies to that one run only; it doesn't change your
system settings.

### Options

| Switch                 | What it does                                                             |
|------------------------|--------------------------------------------------------------------------|
| `-Repair`              | Runs DISM /RestoreHealth and SFC afterwards (10-30+ min). Use when updates download but won't install. |
| `-ResetNetwork`        | Resets the WinHTTP proxy and Winsock catalog. Needs a reboot; can break VPN clients. |
| `-IgnorePendingReboot` | Runs even if Windows is waiting on a reboot. Not recommended.            |
| `-Cleanup`             | Deletes the `.old` backups from earlier resets and shows the space freed. Doesn't run a reset. Add `-WhatIf` to preview first. |

### Optional: a `FixWU` shortcut

Add this function to your PowerShell profile (run `notepad $PROFILE`; if it says
the file doesn't exist, run `New-Item -ItemType File -Path $PROFILE -Force` first):

```powershell
function FixWU
{
    param([switch]$Repair, [switch]$ResetNetwork, [switch]$IgnorePendingReboot,
          [switch]$Cleanup, [switch]$WhatIf)

    $fixwu = "$HOME\Tools\FixWU.ps1"   # change this if you saved it elsewhere
    if (-not (Test-Path $fixwu)) {
        Write-Host "Can't find $fixwu - move FixWU.ps1 into your Tools folder." -ForegroundColor Yellow
        return
    }

    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        & $fixwu @PSBoundParameters
    } else {
        $switches = @($PSBoundParameters.Keys | ForEach-Object { "-$_" })
        $argList  = @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$fixwu`"") + $switches
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        } catch {
            Write-Host "Cancelled - FixWU needs admin rights to run." -ForegroundColor Yellow
        }
    }
}
```

Open a new PowerShell window and you can run it from anywhere. If that window
isn't running as admin, FixWU opens an admin window for you (UAC prompt):

```powershell
FixWU                  # standard reset
FixWU -Repair          # reset, then repair system files with DISM + SFC
FixWU -ResetNetwork    # also reset the WinHTTP proxy and Winsock (needs a reboot)
FixWU -Cleanup         # once updates work: delete the .old backups
FixWU -Cleanup -WhatIf # preview what -Cleanup would delete
```

> Your profile is itself a script. If new PowerShell windows show an error that
> running scripts is disabled, run this once:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

## What it does

1. **Checks for problems a reset can't fix:** a pending reboot, a disabled update
   service, Group Policy/WSUS settings that block updates, or paused updates.
   If a reboot is pending, it stops and tells you to reboot first.
2. **Clears the download queues:** BITS jobs and the Delivery Optimization cache.
3. **Moves the update caches aside:** stops the update services and renames
   `SoftwareDistribution` and `catroot2` to `.old`. Windows rebuilds them fresh.
   If Windows grabs a file mid-reset, it retries (up to 3 times). A backup left
   by an earlier run is replaced (and it tells you), so there's only ever one.
4. **Restarts the services** that were running before.
5. **Prints a summary** of what worked, what failed, and anything that still needs you.

## After running

- Open **Settings > Windows Update** and click **Check for updates**. The first
  check after a reset rebuilds everything from scratch, so give it a few minutes.
  If Settings looks stuck, see [Troubleshooting](#troubleshooting).
- **Update history** will look empty. Your updates are still installed; the old
  history lives in `SoftwareDistribution.old`.
- Once updates work, run FixWU with **`-Cleanup`** to delete the `.old` backups
  and get the space back. The summary tells you how much that is.
- Each run saves a log to `%TEMP%\FixWU_<date>_<time>.log`.

## Troubleshooting

### Settings sits on "Checking for updates..."

The check has usually finished in the background already; the Settings page just
didn't get the result. Close Settings completely and reopen it. It can take two
tries.

### Settings still lists the old stuck downloads

The Settings page shows what Windows Update's scheduler (the Update Orchestrator)
thinks is queued, and resetting the cache doesn't always clear that. Pausing
updates does:

1. In **Settings > Windows Update**, pause updates. The shortest option is fine,
   e.g. pick tomorrow's date (or choose **Pause for 1 week**).
2. Wait about 10 seconds, then click **Resume updates**.
3. The stuck downloads should be gone. Click **Check for updates** to start fresh.

## License

[MIT](LICENSE). Free to use, change and share.

FixWU stops system services and renames system folders. It's careful about it,
but it comes with no warranty: use it at your own risk.
