# iSANN node bootstrap installer for Windows (WSL2 + Docker).
#
# Sets up everything a Windows operator needs to run an iSANN node:
#   1. Reports on the NVIDIA driver (does NOT install it, and does NOT block)
#   2. Enables WSL2 and installs Ubuntu 22.04
#   3. Registers Stage 2 to run inside WSL after reboot
#      (Stage 2 = the LOCAL bundled install-isann-node.sh, run with
#       ENGINES=none - installs Docker + nvidia-container-toolkit only.
#       Engine images/containers come later via `isann docker create`.)
#
# Run from the bundled package as Administrator. Stage 2 reads the sibling
# ../linux/install-isann-node.sh locally (offline, version-locked) - so run
# the packaged file, NOT via `irm | iex` (which has no local script dir):
#   PowerShell (Administrator):
#   <install_root>\scripts\windows\install-isann-node.ps1
#
# Idempotent - re-running is safe.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [string]$Distro = "Ubuntu-22.04",
    # Stage 2 = the LOCAL bundled install-isann-node.sh (no GitHub download —
    # offline + version-locked with this package). Default: sibling ../linux/.
    [string]$Stage2Script = ""
)

$ErrorActionPreference = "Stop"

# WSL output encoding fix. Without WSL_UTF8=1, `wsl --list/--status` emit
# UTF-16LE, which PowerShell mis-decodes on non-UTF-8 consoles (e.g. Korean
# CP949) - the captured text gets interspersed null bytes / mojibake, so
# `-match "<distro>"` fails and an *installed* distro is wrongly reported as
# "not installed". UTF-8 keeps the ASCII distro names (Ubuntu-20.04) intact so
# the detection matches. Mirrors WSL_UTF8=1 used by ivm's Go prereq detector.
$env:WSL_UTF8 = 1

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

$LogDir = Join-Path $env:APPDATA "isann"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# Rotate: drop install logs older than 30 days. Idempotent, runs every time.
Get-ChildItem -Path $LogDir -Filter "install-*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$LogFile = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Msg
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
    switch ($Level) {
        "info" { Write-Host "[i] $Msg" -ForegroundColor Blue }
        "ok"   { Write-Host "[+] $Msg" -ForegroundColor Green }
        "warn" { Write-Host "[!] $Msg" -ForegroundColor Yellow }
        "err"  { Write-Host "[x] $Msg" -ForegroundColor Red }
        "step" { Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
        default { Write-Host $Msg }
    }
}

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-OrLog {
    param([string]$Description, [scriptblock]$Block)
    Write-Log "info" $Description
    if ($DryRun) {
        Write-Log "info" "  [DRY-RUN] skipped"
        return
    }
    try {
        & $Block
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Exit code $LASTEXITCODE"
        }
    } catch {
        Write-Log "err" "FAILED: $($_.Exception.Message)"
        throw
    }
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------

function Check-Admin {
    if (-not (Test-Admin)) {
        Write-Log "err" "Administrator required. Re-open PowerShell as 'Run as Administrator'."
        exit 1
    }
    Write-Log "ok" "Running as Administrator"
}

function Check-NvidiaDriver {
    # 🔴 REPORTS, NEVER BLOCKS. A driver is not something this script can
    # install - it is a signed vendor package with its own reboot - so refusing
    # to continue only meant the operator could not get WSL, Docker and the
    # toolkit in place beforehand. Those three install fine without it; only
    # GPU inference waits for the driver, and `ivm check` keeps reporting the
    # node as not-ready until one shows up.
    #
    # Two-stage check:
    #   1. WMI tells us whether an NVIDIA GPU+driver is present (cheap, no
    #      external process needed).
    #   2. nvidia-smi gives the actual human-readable driver version (e.g.
    #      "552.22"). The WMI DriverVersion field uses a non-trivial Windows
    #      encoding (30.0.15.5212 style); parsing it correctly is error-prone,
    #      so we let nvidia-smi do it. It is in PATH on any modern driver
    #      install (C:\Windows\System32\nvidia-smi.exe).
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "*NVIDIA*" }
    if (-not $gpu) {
        Write-Log "warn" "No NVIDIA GPU detected - continuing without GPU support."
        Write-Log "warn" "  WSL2, Docker and the toolkit still install."
        Write-Log "warn" "  For GPU inference: https://www.nvidia.com/Download/index.aspx"
        return
    }

    try {
        $drv = & nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>$null |
               Select-Object -First 1
        if (-not $drv) { throw "Unable to read NVIDIA driver version" }
        $drv = $drv.Trim()
        $major = [int](($drv -split '\.')[0])
        if ($major -lt 525) {
            Write-Log "warn" "NVIDIA driver $drv is older than 525.xx - CUDA 12.0 images will fail."
            Write-Log "warn" "  Update when convenient: https://www.nvidia.com/Download/index.aspx"
            return
        }
        Write-Log "ok" "NVIDIA driver $drv detected (CUDA 12.0 compatible)"
    } catch {
        Write-Log "warn" "nvidia-smi not available - continuing without GPU support."
        Write-Log "warn" "  Install or repair the driver for GPU inference:"
        Write-Log "warn" "  https://www.nvidia.com/Download/index.aspx"
    }
}

function Check-Virtualization {
    # CPU virtualization (Hyper-V / WSL2 prerequisite)
    $cpu = Get-CimInstance Win32_Processor
    if (-not $cpu.VirtualizationFirmwareEnabled) {
        Write-Log "warn" "CPU virtualization (VT-x / AMD-V) may be disabled in BIOS."
        Write-Log "warn" "  If WSL2 fails, enable virtualization in BIOS and reboot."
    } else {
        Write-Log "ok" "CPU virtualization enabled"
    }
}

# -----------------------------------------------------------------------------
# State detection
# -----------------------------------------------------------------------------

function Detect-State {
    $script:HasWsl = $false
    $script:HasWsl2 = $false
    $script:HasDistro = $false

    # WSL itself
    try {
        $wslStatus = wsl --status 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:HasWsl = $true
            Write-Log "ok" "WSL: installed"
        } else {
            Write-Log "info" "WSL: not installed (will install)"
        }
    } catch {
        Write-Log "info" "WSL: not installed (will install)"
    }

    # WSL2 default version. Older Windows 10 builds don't have the
    # `--get-default-version` subcommand at all -wrap to avoid noisy
    # failures on those (rare) systems. In that case we conservatively
    # treat WSL2 as "not known to be default" and let the install path
    # call `wsl --set-default-version 2`, which itself may or may not
    # work depending on Windows build.
    if ($script:HasWsl) {
        try {
            $defaultVer = wsl --get-default-version 2>$null
            if ($LASTEXITCODE -eq 0 -and $defaultVer -match "2") {
                $script:HasWsl2 = $true
                Write-Log "ok" "WSL2: default"
            } else {
                Write-Log "info" "WSL2: not default (will set)"
            }
        } catch {
            Write-Log "warn" "Unable to determine default WSL version (older Windows build?)"
        }
    }

    # Specific distro
    if ($script:HasWsl) {
        $list = wsl --list --quiet 2>$null
        if ($list -match $Distro) {
            $script:HasDistro = $true
            Write-Log "ok" "Distro: $Distro present"
        } else {
            Write-Log "info" "Distro: $Distro not installed (will install)"
        }
    }
}

function Confirm-Install {
    Write-Host ""
    Write-Host "Plan:" -ForegroundColor Cyan
    if (-not $script:HasWsl)    { Write-Host "  - Install WSL" }
    if (-not $script:HasWsl2)   { Write-Host "  - Set WSL2 as default" }
    if (-not $script:HasDistro) { Write-Host "  - Install $Distro" }
    if (-not $script:HasWsl) {
        Write-Host "  - (after reboot) Run Stage 2 in WSL: Docker + nvidia-container-toolkit"
    } else {
        Write-Host "  - Run Stage 2 in WSL: Docker + nvidia-container-toolkit"
    }
    Write-Host ""
    Write-Host "Log file: $LogFile"
    Write-Host ""

    # A reboot is only possible on a *first-time* WSL feature enable (HasWsl
    # false). With WSL already active, adding/keeping a distro is just a Store
    # download - no reboot. Even on a fresh enable, modern Win11 often needs
    # none (Install-WSL confirms via `wsl --status`), so this is "may", not
    # "will". Matching the real reboot logic avoids a false "reboot required"
    # on already-set-up nodes.
    if (-not $script:HasWsl) {
        Write-Host "A reboot may be required (first-time WSL enable)." -ForegroundColor Yellow
        Write-Host ""
    }

    if ($Yes -or $DryRun) { return }
    $ans = Read-Host "Proceed? [Y/n]"
    if ($ans -and $ans -notin @("y", "Y", "yes", "Yes")) {
        Write-Log "info" "Aborted by user"
        exit 0
    }
}

# -----------------------------------------------------------------------------
# Install steps
# -----------------------------------------------------------------------------

function Wait-DistroRegistered {
    # `wsl --install -d <Distro> --no-launch` is asynchronous on many Windows
    # versions: the command returns while the Store package is still
    # downloading / extracting, and the distro shows up in `wsl --list` only
    # seconds-to-MINUTES later. The rootfs is a few hundred MB, so on a slow
    # network 120s was far too short (the real failure operators hit). Poll up
    # to a generous deadline, with periodic progress so the wait isn't a silent
    # freeze, and end with operator-facing guidance instead of a bare throw.
    $timeoutSec = 600
    $start = Get-Date
    $lastNote = $start
    Write-Log "info" "Waiting for $Distro to register (downloading rootfs, may take a few minutes on a slow network)..."
    while (((Get-Date) - $start).TotalSeconds -lt $timeoutSec) {
        $list = wsl --list --quiet 2>$null
        if ($list -match [regex]::Escape($Distro)) {
            Write-Log "ok" "$Distro registered"
            $script:HasDistro = $true
            return
        }
        if (((Get-Date) - $lastNote).TotalSeconds -ge 15) {
            Write-Log "info" ("  ... still downloading / registering ({0}s elapsed, up to {1}s)" -f `
                [int]((Get-Date) - $start).TotalSeconds, $timeoutSec)
            $lastNote = Get-Date
        }
        Start-Sleep -Seconds 3
    }
    # Don't surface only a stack trace - tell the operator what to do.
    Write-Log "warn" "$Distro did not register within $timeoutSec seconds."
    Write-Host ""
    Write-Host "  What to try (most likely first):" -ForegroundColor Yellow
    Write-Host "    1. Slow network - just run 'ivm setup' again; the download resumes/caches." -ForegroundColor Yellow
    Write-Host "    2. Reboot pending (first-time WSL enable) - reboot, then run 'ivm setup' again." -ForegroundColor Yellow
    Write-Host "    3. CPU virtualization disabled - enable VT-x / AMD-V in BIOS" -ForegroundColor Yellow
    Write-Host "       (Task Manager > Performance > CPU > Virtualization), reboot, then 'ivm setup'." -ForegroundColor Yellow
    Write-Host ""
    throw "$Distro registration timed out after $timeoutSec s - see guidance above"
}

function Install-WSL {
    if ($script:HasWsl -and $script:HasDistro) {
        Write-Log "ok" "WSL + $Distro already installed - skip"
        return $false
    }

    # | Out-Null is REQUIRED: a PowerShell function returns ALL pipeline output,
    # so the native `wsl` text these blocks emit would otherwise leak into
    # Install-WSL's return value and make the caller's `if ($needsReboot)` truthy
    # even on a `return $false` path (wrongly taking the reboot branch). The
    # Write-Log description already reports progress; the raw wsl text isn't needed.
    Invoke-OrLog "Installing WSL2 + $Distro" {
        wsl --install -d $Distro --no-launch
    } | Out-Null

    # Close the async install race before any subsequent `wsl -d` call.
    Wait-DistroRegistered

    if (-not $script:HasWsl2) {
        Invoke-OrLog "Setting WSL2 as default" {
            wsl --set-default-version 2
        } | Out-Null
    }

    # Decide reboot based on whether WSL is actually operational, not on
    # registry heuristics (RebootPending keys are set/cleared by many
    # subsystems and don't always reflect WSL state).
    #
    # 1. If WSL was already active before this script ran, adding a distro
    #    is a Store download -no kernel feature change, no reboot.
    if ($script:HasWsl) {
        Write-Log "ok" "WSL feature already active - reboot not required"
        return $false
    }

    # 2. Fresh feature enable: probe `wsl --status`. Modern Win11 ships
    #    VirtualMachinePlatform active, so the kernel feature can come up
    #    without a reboot. If --status returns 0, we're good.
    wsl --status 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "ok" "WSL operational without reboot"
        return $false
    }

    Write-Log "info" "Reboot required to activate WSL"
    return $true
}

function Get-Stage2WslPath {
    # Resolve the LOCAL bundled install-isann-node.sh (sibling ../linux/) and
    # translate to a WSL /mnt/<drive>/ path. Stage 2 runs the bundled script
    # via WSL (no GitHub download) so the install works offline and stays
    # version-locked with this package. $Stage2Script overrides the default.
    $local = $Stage2Script
    if (-not $local) { $local = Join-Path $PSScriptRoot "..\linux\install-isann-node.sh" }
    if (-not (Test-Path -LiteralPath $local)) {
        throw "Stage 2 script not found: $local (run the bundled install-isann-node.ps1)"
    }
    $full = (Resolve-Path -LiteralPath $local).Path
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "Not a Windows path: $full" }
    return "/mnt/$($matches[1].ToLower())/$($matches[2] -replace '\\','/')"
}

function Register-Stage2-Task {
    $taskName = "ISANN-Setup-Stage2"
    $stage2PsPath = Join-Path $env:APPDATA "isann\stage2.ps1"
    $stage2WslPath = Get-Stage2WslPath

    # Stage 2 script: download installer.sh and run inside WSL
    @"
# iSANN Setup Stage 2 - runs after reboot, executes inside WSL.
`$ErrorActionPreference = "Stop"
`$LogFile = Join-Path `$env:APPDATA "isann\stage2-`$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Start-Transcript -Path `$LogFile

# Wait for WSL to be ready. After reboot, first-boot provisioning may still
# be running -hitting it with a heavy bash chain races and can fail. Poll
# with a small fixed delay until rootfs responds.
`$retries = 0
while (`$retries -lt 30) {
    `$ok = wsl -d $Distro -u root -- echo ready 2>`$null
    if (`$ok -match "ready") { break }
    Start-Sleep 2
    `$retries++
}
if (`$retries -ge 30) {
    Write-Host "[x] WSL distro did not become ready after 60s" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host "[i] Running Stage 2 in WSL..." -ForegroundColor Blue

# Defensively install curl/ca-certificates (minimal Ubuntu images may lack
# them), then run the bundled installer.sh as root. Kept on ONE line on
# purpose: this stage2.ps1 is written as a Windows (CRLF) file, and a
# multi-line "bash -c" string would carry a \r at every line end, which makes
# bash fail with "set: invalid option" / "syntax error: unexpected end of
# file". A single-line string has no embedded CR. (The .sh FILE bash then runs
# is separately de-CR'd by the tr below.) `set -e` aborts on first failure.
wsl -d $Distro -u root -- bash -c "set -e; export DEBIAN_FRONTEND=noninteractive; if ! command -v curl >/dev/null 2>&1 || [ ! -d /etc/ssl/certs ]; then apt-get update && apt-get install -y curl ca-certificates; fi; tr -d '\r' < '$stage2WslPath' > /tmp/install-isann-node.sh; ENGINES=none bash /tmp/install-isann-node.sh"

if (`$LASTEXITCODE -ne 0) {
    Write-Host "[x] Stage 2 failed (exit `$LASTEXITCODE)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host "[+] Setup complete." -ForegroundColor Green

# Cleanup self-trigger
Unregister-ScheduledTask -TaskName "$taskName" -Confirm:`$false -ErrorAction SilentlyContinue

Stop-Transcript
Read-Host "Press Enter to close"
"@ | Out-File -FilePath $stage2PsPath -Encoding utf8

    Invoke-OrLog "Registering Stage 2 task to run after reboot" {
        # Use the fully-qualified identity (e.g. "MACHINE\Alice",
        # "CONTOSO\Alice", "MicrosoftAccount\alice@outlook.com",
        # "AzureAD\Alice") so Task Scheduler can resolve the SID on domain
        # joined, Azure AD joined, or Microsoft Account linked machines.
        # `$env:USERNAME` alone only carries the short name and fails to
        # resolve in those scenarios.
        $currentUser = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$stage2PsPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable

        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Force | Out-Null
    }
}

function Prompt-Reboot {
    Write-Host ""
    Write-Host "Reboot is required." -ForegroundColor Yellow
    Write-Host "Stage 2 will run automatically after reboot (Docker / engine setup inside WSL)."
    Write-Host ""

    if ($DryRun) {
        Write-Log "info" "[DRY-RUN] Would reboot now"
        return
    }

    if ($Yes) {
        Write-Log "info" "Rebooting now..."
        Restart-Computer -Force
        return
    }

    $ans = Read-Host "Reboot now? [Y/n]"
    if ($ans -in @("", "y", "Y", "yes", "Yes")) {
        Restart-Computer -Force
    } else {
        Write-Host "Reboot manually. Task Scheduler will run ISANN-Setup-Stage2 at next logon." -ForegroundColor Yellow
    }
}

function Wait-DistroReady {
    # `wsl --install -d <Distro> --no-launch` registers the rootfs but does
    # not run first-boot provisioning. The first real `wsl -d <Distro>` call
    # triggers it -if we race against that with a heavy bash chain we can
    # hit transient failures. This function forces provisioning and waits
    # until the rootfs is responsive. Idempotent: if the distro is already
    # warm, returns on the first iteration.
    Write-Log "info" "Waiting for $Distro to be ready..."
    for ($i = 0; $i -lt 30; $i++) {
        $out = wsl -d $Distro -u root -- echo ready 2>$null
        if ($out -match "ready") {
            Write-Log "ok" "$Distro ready"
            return
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "err" "$Distro did not become ready after 60s"
    exit 1
}

function Run-Stage2-Now {
    # When WSL + distro are already in place, skip the reboot and run Stage 2 directly.
    Write-Log "info" "WSL ready - running Stage 2 immediately (no reboot needed)"
    Wait-DistroReady
    $stage2WslPath = Get-Stage2WslPath

    # apt-get update + install curl/ca-certificates is a defensive safety net.
    # Modern Ubuntu WSL images include curl by default, but minimal variants
    # may not. `set -e` ensures any failure stops the chain and surfaces via
    # the non-zero exit code that Invoke-OrLog checks.
    # This .ps1 is a Windows (CRLF) file, so the here-string below carries a
    # \r at every line end. Passed straight to `bash -c`, those CRs make bash
    # fail with "set: invalid option" and "syntax error: unexpected end of
    # file" (the if/fi block looks unterminated). Strip CR from the COMMAND
    # before handing it to bash. (This is separate from the `tr -d '\r'` line
    # inside, which de-CRs the .sh FILE that bash then runs.)
    $stage2Cmd = @"
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null 2>&1 || [ ! -d /etc/ssl/certs ]; then
  apt-get update
  apt-get install -y curl ca-certificates
fi
tr -d '\r' < '$stage2WslPath' > /tmp/install-isann-node.sh
ENGINES=none bash /tmp/install-isann-node.sh
"@ -replace "`r", ""
    Invoke-OrLog "Running Stage 2 in WSL" {
        wsl -d $Distro -u root -- bash -c $stage2Cmd
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function Main {
    Write-Log "step" "iSANN Node Installer (Windows + WSL2)"

    Check-Admin
    Check-NvidiaDriver
    Check-Virtualization

    Write-Log "step" "Detecting current state"
    Detect-State
    Confirm-Install

    Write-Log "step" "Stage 1: WSL setup"
    $needsReboot = Install-WSL

    if ($needsReboot) {
        Write-Log "step" "Registering Stage 2 for after reboot"
        Register-Stage2-Task
        Prompt-Reboot
    } else {
        Write-Log "step" "Stage 2: Docker + engines (in WSL)"
        Run-Stage2-Now
        Write-Log "ok" "Install complete. Log: $LogFile"
    }
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
#
# This script is launched elevated (ivm setup -> UAC -> powershell -File ...),
# so the console window closes the instant Main returns or throws. A bare
# uncaught exception would flash red and vanish before it can be read - which
# is exactly the "the red text disappears too fast" symptom. Two guards keep
# failures visible:
#   1. A transcript records the FULL console (incl. native wsl/bash output and
#      the red exception text) to install-<ts>.transcript.log next to the
#      structured log, so nothing is lost even if the operator misses it.
#   2. A top-level try/catch pauses on both success and failure, so the window
#      stays open until Enter is pressed.

$Transcript = $LogFile -replace '\.log$', '.transcript.log'
try { Start-Transcript -Path $Transcript | Out-Null } catch { }

try {
    Main
} catch {
    Write-Log "err" "Setup failed: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "----- error detail -----" -ForegroundColor Red
    Write-Host "$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "$($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host "------------------------" -ForegroundColor Red
    Write-Host "Full transcript saved to: $Transcript" -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host "Press Enter to close"
    exit 1
}

try { Stop-Transcript | Out-Null } catch { }
Read-Host "Press Enter to close"
