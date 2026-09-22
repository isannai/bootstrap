<#
  get-isann.ps1 — bootstrap an iSANN node on Windows.

  Downloads the LATEST ivm (github.com/isannai/isann releases), then lets ivm do
  the rest: init the root, pull the isannd suite, and register the S4U service.
  ivm is standalone (no isannd dependency), so it is the ONLY thing fetched
  directly here — `ivm install` pulls the suite and verifies it with its own sha256.

  OS prereqs (WSL2 + Ubuntu + Docker + nvidia-container-toolkit) install only for
  --role=provider, by running `ivm setup` once ivm is in place. A consumer node
  calls other nodes and runs nothing locally, so it skips all of it and finishes
  in a minute or two.

    # in a PowerShell window:
    irm https://<host>/get-isann.ps1 | iex                                  # default folder
    $env:ISANN_ROOT='C:\isann'; irm https://<host>/get-isann.ps1 | iex      # pick the folder (piped)
    # from cmd / Run box (one line, anywhere):
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://<host>/get-isann.ps1 | iex"
    # saved to a file:
    .\get-isann.ps1 --root=C:\isann --role=provider

  Options (same spelling as get-isann.sh; PowerShell's own -Root / -Role also work):
    --root=<path>     pre-fills the install-folder prompt (the script ALWAYS asks
                      on run; Enter accepts the default). --root / $ISANN_ROOT set
                      that default; else %LOCALAPPDATA%\isann. Non-interactive
                      hosts skip the prompt and use the default.
    --version=<tag>   pin a release tag (default: latest)
    --role=<r>        consumer | provider. Skips the role question. A consumer
                      node only CALLS other nodes, so it needs no station, no
                      probe, no WSL/Docker/GPU. Default when not asked: consumer
    --token=<tok>     GitHub token (only if you hit the anonymous rate limit)
#>
# PositionalBinding=$false is what actually makes the --xxx=yyy catcher below
# work. Without it $Root/$Version/$Role/$Token are positional (0..3), so
# PowerShell binds "--root=C:\isann" to $Root and "--role=provider" to $Version,
# and $Rest never receives anything - the catcher becomes dead code.
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Root,
  [string]$Version,
  [string]$Role    = $env:ISANN_ROLE,
  [string]$Token   = $env:GITHUB_TOKEN,
  # PowerShell binds its own parameters with a single dash (-Role). The
  # double-dash spelling is here so one set of instructions works on both
  # scripts; without this catcher PowerShell would bind "--role" to $Root as a
  # positional argument and install into a folder called "--role".
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)
foreach ($a in $Rest) {
  switch -regex ($a) {
    '^--role=(.+)$'    { $Role    = $matches[1] }
    '^--root=(.+)$'    { $Root    = $matches[1] }
    '^--version=(.+)$' { $Version = $matches[1] }
    '^--token=(.+)$'   { $Token   = $matches[1] }
    default { throw "unknown option: $a" }
  }
}
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # faster Invoke-WebRequest

# This script is fetched fresh over the network every run, so the operator has no
# other way to tell WHICH copy is on screen - a fix pushed minutes ago and a
# cached copy from this morning look identical while behaving differently. Bump
# this line in the same commit that changes behaviour. It is the script's own
# version, unrelated to the ivm/isannd release it installs.
$ScriptVersion = '2026-09-20.4'
Write-Host "get-isann $ScriptVersion  (installer script)"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Install root: ALWAYS prompt on run (Enter accepts the default). --root / $ISANN_ROOT
# only pre-fill the default. A piped `irm | iex` keeps the console stdin, so
# Read-Host works; a non-interactive host (CI/service) uses the default silently.
# Whether we can ask a question at all. [Environment]::UserInteractive returns
# $true even under `powershell -NonInteractive`, where Read-Host then throws
# PSInvalidOperationException - and with $ErrorActionPreference='Stop' that kills
# the install at the very first question instead of falling back to defaults.
# So the cheap gate is only a hint; Read-Answer's try/catch is the real check.
# get-isann.sh tests /dev/tty for exactly the same reason.
function Test-Interactive {
  if (-not [Environment]::UserInteractive) { return $false }
  return (-not [Console]::IsInputRedirected)
}
function Read-Answer([string]$Prompt, [string]$Default) {
  try { $a = Read-Host $Prompt } catch { return $Default }
  if ($a) { return $a }
  return $Default
}

# --- where is this machine's iSANN already? --------------------------------
# Asked BEFORE the folder question, because the answer belongs in the question.
# Two things name an install without admin, without ivm and without a single
# downloaded byte: the isannd task and PATH. One iSANN per machine, so if either
# answers, that folder is the one to offer - typing anything else is a mistake
# the script would otherwise accept and only refuse several steps later.
function Get-InstallRoot($exe) {
  # <root>\ivm.exe, or <root>\bin\{isann,isannd}.exe
  $dir = Split-Path -Parent $exe
  if ((Split-Path -Leaf $dir) -ieq 'bin') { Split-Path -Parent $dir } else { $dir }
}

$found = [ordered]@{}   # root -> what points at it
$svcExe = $null
try { $svcExe = (Get-ScheduledTask isannd -ErrorAction SilentlyContinue).Actions[0].Execute } catch { }
if ($svcExe) { $found[(Get-InstallRoot $svcExe)] = "service  : $svcExe" }

# PATH decides which `isann` the operator's NEXT command runs. An install that
# wins the folder but loses PATH is WS-03 #6: `isann version` kept printing the
# old build and nothing said why.
foreach ($name in @('isann', 'ivm')) {
  $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { continue }
  $r = Get-InstallRoot $cmd.Source
  if (-not $found.Contains($r)) { $found[$r] = "on PATH  : $($cmd.Source)" }
}
$existing = if ($found.Count -gt 0) { @($found.Keys)[0] } else { $null }

# An explicit --root / $ISANN_ROOT still wins the DEFAULT - it is an answer the
# operator already gave. It does not skip the conflict check below.
$default = if ($Root) { $Root }
           elseif ($env:ISANN_ROOT) { $env:ISANN_ROOT }
           elseif ($existing) { $existing }
           else { Join-Path $env:LOCALAPPDATA 'isann' }
if (Test-Interactive) {
  # Say up front that this is not the only prompt. The download and the service
  # registration sit between the two, so someone who walks away comes back to a
  # question still waiting rather than a finished install.
  Write-Host "This asks you two things: the install folder now, and a wallet passphrase at the end."
  Write-Host "Windows will also raise a UAC prompt when the service is registered."
  if ($existing) {
    Write-Host ""
    Write-Host "This machine already has an iSANN install:"
    foreach ($k in $found.Keys) { Write-Host "    $($found[$k])" }
    Write-Host "Press Enter to use it. Another folder will be refused - one node per machine."
  }
  Write-Host ""
  $Root = Read-Answer "install folder [$default]" $default
} else {
  $Root = $default
}

# Role decides how much of the stack this node needs, and it is asked here so
# every question is answered before the long download starts.
#
# A consumer calls other nodes over `--nodes`; isannd dials the peer directly,
# so nothing runs locally: no station (that serves YOUR engine to others), no
# probe, no WSL, no Docker, no GPU driver. A provider needs all of it.
#
# The default is consumer because it is the cheaper mistake: a consumer that
# later wants to share runs `ivm setup` + `isann mesh pull`, whereas a provider
# install on a machine that never serves leaves several GB of unused stack.
if ($null -eq $Role) { $Role = '' }
$Role = $Role.Trim().ToLower()
# A re-install must not silently demote a provider. $Role is not carried by the
# install itself, so it is recorded at the end of this script and read back here
# - otherwise an operator who just presses Enter lands on the consumer default
# and every provider-only step below is skipped: the station/probe pull (isannd
# updates, the mesh apps stay behind, and nothing looks wrong until the two
# disagree) and the recipe list that says what to run next. Installs made before
# that file existed have no record, so fall back to the one thing only a
# provider has: a station. Same idea as the install-folder default above.
# [IO.Path]::Combine, not Join-Path: Join-Path RESOLVES the drive and throws
# DriveNotFoundException for a root like D:\isann on a machine with no D: -
# and $ErrorActionPreference = "Stop" turns that into a dead script before the
# folder-conflict check below can say anything useful. This is a plain string
# join. The whole probe is best effort: anything unreadable falls through to
# the question rather than failing the install.
$script:roleFile = [IO.Path]::Combine($Root, 'artifacts', 'install-role')
if (-not $Role) {
  try {
    $stationDir = [IO.Path]::Combine($Root, 'artifacts', 'addon', 'meshes', 'station')
    if (Test-Path -LiteralPath $script:roleFile) {
      $prev = Get-Content $script:roleFile -TotalCount 1 -ErrorAction SilentlyContinue
      if ($prev) { $prev = $prev.Trim().ToLower() }
      if ($prev -in @('consumer', 'provider')) {
        $Role = $prev
        Write-Host "existing $Role install - keeping that role"
      }
    } elseif (Test-Path -LiteralPath $stationDir) {
      $Role = 'provider'
      Write-Host "existing install has a station - assuming role=provider"
    }
  } catch {
    # unreachable/nonexistent drive, permissions, a corrupt file - ask instead
  }
}
if ($Role -notin @('consumer', 'provider')) {
  if (Test-Interactive) {
    Write-Host ""
    Write-Host "what will this node do?"
    Write-Host "  1) consumer - use other nodes only      (default)"
    Write-Host "  2) provider - also serve inference to others"
    $ans = Read-Answer "choice [1]" '1'
    $Role = if ($ans -eq '2') { 'provider' } else { 'consumer' }
  } else {
    $Role = 'consumer'
  }
}
Write-Host "role: $Role"

if (-not [Environment]::Is64BitOperatingSystem) { throw "64-bit Windows is required" }
$asset = "ivm-windows-amd64.zip"

# ivm returns non-zero on failure; native exes don't throw in PowerShell, so
# guard the critical steps explicitly (check/status stay soft on purpose).
function Invoke-Ivm {
  & $script:ivm @args
  if ($LASTEXITCODE -ne 0) { throw "ivm $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

# (The Test-ServiceRegistered probe that stood here is gone. It existed so this
# script could tell "registered" from "not installed" across ivm versions and
# poll for a registration that happened in a window ivm did not wait for. Both
# of its callers are gone: `ivm use` now registers + starts in one waited-for
# elevation, and `ivm doctor` answers the "which install owns the service"
# question before anything is written.)

# --- conflict check, BEFORE anything is downloaded -------------------------
# $found was gathered before the folder question, so accepting the offered
# default lands here with nothing to report. This catches the operator who
# typed a different folder anyway - including a typo of the right one, which is
# how this was first hit ("d:\iann").
#
# The fuller view - every root on disk, their active versions, PATH ORDER - is
# `ivm doctor`'s job, and it runs from the TEMP copy after the download but
# still before anything is written to $Root.
$conflicts = [ordered]@{}
foreach ($k in $found.Keys) {
  if ($k.TrimEnd('\') -ine $Root.TrimEnd('\')) { $conflicts[$k] = $found[$k] }
}

if ($conflicts.Count -gt 0) {
  $other = @($conflicts.Keys)[0]
  Write-Host ""
  Write-Host "This machine already has an iSANN install in another folder:"
  foreach ($k in $conflicts.Keys) { Write-Host "    $($conflicts[$k])" }
  Write-Host "    you gave: $Root"
  Write-Host ""
  Write-Host "  Install into $other instead, or clear that one out first:"
  Write-Host "    `"$other\ivm.exe`" uninstall"
  Write-Host "  (`"$other\ivm.exe`" doctor lists every install on this machine)"
  Write-Host ""
  Write-Host "nothing was downloaded."
  # `exit` inside `irm | iex` ends the CONSOLE, not just this script: the
  # operator's window vanishes taking the message above with it - which is
  # exactly how this stop was first reported as "nothing happens, it just
  # closes". `return` stops the script and leaves the shell alone; a real
  # file run still gets the exit code scripts expect.
  if ($PSCommandPath) { exit 1 }
  return
}

$owner = 'isannai'; $repo = 'isann'
$api = if ($Version) { "https://api.github.com/repos/$owner/$repo/releases/tags/$Version" }
       else          { "https://api.github.com/repos/$owner/$repo/releases/latest" }
# Two header sets on purpose. browser_download_url 302s to
# objects.githubusercontent.com, and PowerShell 5.1 forwards Authorization
# across that redirect - the CDN then rejects the request ("only one auth
# mechanism allowed"). So the token goes to api.github.com only; the download
# is public and needs no credential. (curl drops it by itself, which is why
# get-isann.sh needs no equivalent split.)
$headers   = @{ 'User-Agent' = 'get-isann' }
$dlHeaders = @{ 'User-Agent' = 'get-isann' }
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

Write-Host "==> querying $api"
$rel = Invoke-RestMethod -Uri $api -Headers $headers
$tag = $rel.tag_name
$a   = $rel.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1
if (-not $a) { throw "release $tag ships no $asset" }
Write-Host "==> ivm $tag  ($asset)"

$tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("isann-boot-" + [Guid]::NewGuid().ToString('N')))
try {
  $zip = Join-Path $tmp $asset
  Invoke-WebRequest -Uri $a.browser_download_url -Headers $dlHeaders -OutFile $zip

  if ($a.digest) {
    $want = ($a.digest -replace '^sha256:', '').ToLower()
    $have = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { throw "sha256 mismatch: want $want have $have" }
    Write-Host "==> sha256 ok"
  } else {
    # `ivm install` refuses a suite asset with no digest; say so here too rather
    # than installing an unverified binary in silence.
    Write-Host "==> WARNING: release ships no sha256 digest for $asset - integrity NOT verified"
  }
  Expand-Archive -Path $zip -DestinationPath $tmp -Force

  # --- pre-flight: one machine, one install ---
  # Run from the TEMP copy, BEFORE the install folder is created and before
  # anything is written to it - a check that first installs what it is checking
  # is not a check. It reports every iSANN install on this machine, where the
  # isannd service points and what PATH resolves, and exits non-zero when they
  # disagree. Installing into the folder already in use is NOT a conflict, so a
  # plain upgrade passes straight through. It deletes nothing: an old root can
  # hold a wallet, so the operator decides.
  & (Join-Path $tmp 'ivm.exe') doctor --root $Root
  # EXACTLY 1 is "conflicts found". An ivm older than the one that introduced
  # `doctor` exits 2 (unknown command) - a pinned --version must still install,
  # so anything other than 1 carries on.
  if ($LASTEXITCODE -eq 1) {
    Write-Host ""
    Write-Host "install stopped - nothing was installed. Resolve the conflicts above,"
    Write-Host "or re-run and give the folder this machine already uses."
    if ($PSCommandPath) { exit 1 }   # `exit` would close a piped-to-iex console
    return
  }

  # --- place ivm + scripts ---
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $script:ivm = Join-Path $Root 'ivm.exe'
  # The old `ivm service stop` that stood here is gone. It ran the SAME ivm.exe
  # this line is about to overwrite - in an elevated window ivm does not wait
  # for - so the copy below hit "file in use" depending on how fast UAC was
  # answered. The service holds isannd.exe, never ivm.exe, and `ivm use` stops
  # the service itself before swapping bin/.
  Copy-Item (Join-Path $tmp 'ivm.exe') $script:ivm -Force
  if (Test-Path (Join-Path $tmp 'scripts')) {
    Copy-Item (Join-Path $tmp 'scripts') $Root -Recurse -Force
  }

  # --- drive ivm ---
  Push-Location $Root
  try {
    Invoke-Ivm init --root $Root                     # anchor the install root explicitly
    Invoke-Ivm install --version $tag                # download + verify (cache only)
    # ONE step, ONE UAC prompt: `ivm use` switches and then leaves the node
    # RUNNING - registering + starting the service when there is none, stopping
    # and restarting it when there is. ivm now WAITS for its elevated window and
    # returns its exit code, so a declined UAC fails here instead of leaving the
    # installer to guess.
    #
    # What stood here before: `ivm service install` followed by a 120-second poll
    # of `service status`, because the elevated window was fire-and-forget and its
    # result never came back. Both are gone with the wait.
    Invoke-Ivm use --version $tag                    # switch (+ register) -> running

    # Record the role so the next run does not have to ask again. After
    # `ivm use` because artifacts\ only exists once ivm has initialised. Never
    # fatal: a node that runs but forgot its role costs a re-ask, not a broken
    # install.
    try {
      New-Item -ItemType Directory -Force -Path (Split-Path $script:roleFile) | Out-Null
      Set-Content -Path $script:roleFile -Value $Role -Encoding utf8
    } catch {
      Write-Host "note: could not record the role in $script:roleFile"
    }
  } finally { Pop-Location }
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "iSANN node ready at $Root"

# PATH: `ivm init` registered HKCU\Environment (NEW shells get `ivm` automatically).
# A piped `irm | iex` runs in THIS session, so also prepend in-process → `ivm`
# works right away here without opening a new terminal.
$binPath = Join-Path $Root 'bin'
if (($env:Path -split ';') -notcontains $Root)    { $env:Path = "$Root;$env:Path" }
if (($env:Path -split ';') -notcontains $binPath) { $env:Path = "$binPath;$env:Path" }

# OS prereqs. A provider was asked to serve inference, which is impossible
# without Docker, so the install runs `ivm setup` itself rather than printing a
# command the operator has to notice. A consumer runs no engines and needs none
# of it.
#
# The reboot is not this script's problem: when WSL has to be enabled for the
# first time, install-isann-node.ps1 registers the ISANN-Setup-Stage2 scheduled
# task and Docker installs itself after the restart.
if ($Role -ne 'provider') {
  Write-Host "prereqs: not needed - a consumer node runs no engines locally"
} else {
  & $script:ivm check *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "prereqs: OK (WSL / Docker / toolkit present)"
  } else {
    Write-Host ""
    Write-Host "==> installing OS prereqs (WSL2 + Docker + NVIDIA toolkit)"
    Write-Host "    this asks for admin and may reboot; Docker finishes after the restart."
    & $script:ivm setup
    # On Windows `ivm setup` only TRIGGERS the elevated window and returns 0 at
    # once, so $LASTEXITCODE cannot report whether WSL/Docker finished - and the
    # first WSL enable needs a reboot anyway. Stop here instead of racing ahead
    # into mesh pull and the wallet prompt on top of an installer that is still
    # running in another window. Re-running resumes: everything already done is
    # skipped and `ivm check` then passes straight through.
    Write-Host ""
    Write-Host "==> finish the elevated window first (including any reboot),"
    Write-Host "    then run this installer again to continue with mesh + wallet."
    if ($PSCommandPath) { exit 0 }   # `exit` would close a piped-to-iex console
    return
  }
}
# --- mesh connectors (station, probe) ---
# Pulled here rather than left to the operator: a node without a station cannot
# serve anyone, and finding the right release asset by hand is the step people
# skip. `latest/download` follows GitHub's redirect to the newest release, so
# this script does not have to be edited when a version ships.
#
# Downloaded but NOT started: station is only useful once an engine exists
# (`isann docker create llama`), and starting an empty one just opens a door to
# an empty room. A failure here is reported and does not fail the install - the
# node itself is already up.
$isann = Join-Path $binPath 'isann.exe'
if ($Role -ne 'provider') {
  Write-Host "consumer node - skipping station/probe (add them later with: isann mesh pull ...)"
} elseif (Test-Path $isann) {
  foreach ($m in @('station', 'probe')) {
    $url = "https://github.com/isannai/mesh/releases/latest/download/$m-windows-amd64.zip"
    Write-Host "==> mesh pull $m"
    & $isann mesh pull $url --name $m -force
    if ($LASTEXITCODE -ne 0) {
      Write-Host "    $m pull failed - install it later with:  isann mesh pull $url --name $m"
    }
  }
} else {
  Write-Host "isann.exe not found under $binPath - skipping station/probe"
}

# --- wallet + owner ---
# The node runs in OPEN mode until it has an owner: every admin endpoint is
# ungated. So this is not an optional flourish, it is the step that closes the
# door - which is why the script offers it rather than only printing it.
#
# The passphrase is typed here, never generated and never stored: it is the ONLY
# way to unlock the key and there is no recovery path, so a script that invented
# one would be handing out an account nobody can hold. A piped `irm | iex` keeps
# the console stdin, so the prompt works; a non-interactive host (CI, service)
# skips this and prints the two commands instead.
$accounts = Join-Path $Root 'artifacts\accounts.json'
$hasAccount = (Test-Path $accounts) -and ((Get-Content -Raw $accounts) -match '0x[0-9a-fA-F]{40}')

if ($hasAccount) {
  Write-Host "wallet: already present - skipping"
} elseif (Test-Interactive) {
  Write-Host ""
  Write-Host "A wallet makes you the owner of this node. Without one the node stays open."
  $alias = Read-Answer "wallet alias [me] (type 'skip' to do it later)" 'me'
  if ($alias -ne 'skip') {
    & $script:ivm account create --alias $alias
    if ($LASTEXITCODE -eq 0) {
      & $script:ivm auth transfer --owner $alias -y
      if ($LASTEXITCODE -ne 0) {
        Write-Host "owner not set - run:  ivm auth transfer --owner $alias"
      }
    } else {
      Write-Host "wallet not created - run:  ivm account create --alias $alias"
    }
  }
} else {
  Write-Host "wallet: non-interactive host - run these yourself:"
  Write-Host "  ivm account create --alias me"
  Write-Host "  ivm auth transfer --owner me"
}

Write-Host ""
# A recipe does the whole setup in one command: unlock, model download, engine
# start, station, rendezvous. They ship with the release, so nothing to fetch.
if ($Role -eq 'provider') {
  Write-Host "next - pick a recipe and run it:"
  Write-Host ""
  Write-Host "  isann recipe exec install-llama-small     Qwen2.5-1.5B    VRAM 4G+"
  Write-Host "  isann recipe exec install-llama-medium    Qwen2.5-14B     VRAM 12G+"
  Write-Host "  isann recipe exec install-sd-small        SD 1.5 images   VRAM 4G+"
  Write-Host ""
  Write-Host "  it asks for your account alias and a rendezvous url, then does the rest:"
  Write-Host "  model download, engine start, station, rendezvous registration."
  Write-Host ""
  Write-Host "  isann recipe list      what else is on this node"
} else {
  Write-Host "next - run the recipe:"
  Write-Host ""
  Write-Host "  isann recipe exec install-passenger"
  Write-Host ""
  Write-Host "  it asks for your account alias and a rendezvous url, then registers"
  Write-Host "  this node and lists who is out there."
  Write-Host ""
  Write-Host "  then:  isann infer run --engine llama --prompt ""hello"" --nodes <node> -wait"
  Write-Host ""
  Write-Host "  to share this node later:  ivm setup  then  isann mesh pull ..."
}
