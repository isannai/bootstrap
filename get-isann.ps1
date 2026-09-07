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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Install root: ALWAYS prompt on run (Enter accepts the default). --root / $ISANN_ROOT
# only pre-fill the default. A piped `irm | iex` keeps the console stdin, so
# Read-Host works; a non-interactive host (CI/service) uses the default silently.
$default = if ($Root) { $Root } elseif ($env:ISANN_ROOT) { $env:ISANN_ROOT } else { Join-Path $env:LOCALAPPDATA 'isann' }
if ([Environment]::UserInteractive) {
  # Say up front that this is not the only prompt. The download and the service
  # registration sit between the two, so someone who walks away comes back to a
  # question still waiting rather than a finished install.
  Write-Host "This asks you two things: the install folder now, and a wallet passphrase at the end."
  Write-Host "Windows will also raise a UAC prompt when the service is registered."
  Write-Host ""
  $ans = Read-Host "install folder [$default]"
  if ($ans) { $Root = $ans } else { $Root = $default }
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
if ($Role -notin @('consumer', 'provider')) {
  if ([Environment]::UserInteractive) {
    Write-Host ""
    Write-Host "what will this node do?"
    Write-Host "  1) consumer - use other nodes only      (default)"
    Write-Host "  2) provider - also serve inference to others"
    $ans = Read-Host "choice [1]"
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

$owner = 'isannai'; $repo = 'isann'
$api = if ($Version) { "https://api.github.com/repos/$owner/$repo/releases/tags/$Version" }
       else          { "https://api.github.com/repos/$owner/$repo/releases/latest" }
$headers = @{ 'User-Agent' = 'get-isann' }
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
  Invoke-WebRequest -Uri $a.browser_download_url -Headers $headers -OutFile $zip

  if ($a.digest) {
    $want = ($a.digest -replace '^sha256:', '').ToLower()
    $have = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { throw "sha256 mismatch: want $want have $have" }
    Write-Host "==> sha256 ok"
  }
  Expand-Archive -Path $zip -DestinationPath $tmp -Force

  # --- place ivm + scripts ---
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $script:ivm = Join-Path $Root 'ivm.exe'
  if (Test-Path $script:ivm) {
    & $script:ivm service status *> $null
    if ($LASTEXITCODE -eq 0) { & $script:ivm service stop }   # free the busy file
  }
  Copy-Item (Join-Path $tmp 'ivm.exe') $script:ivm -Force
  if (Test-Path (Join-Path $tmp 'scripts')) {
    Copy-Item (Join-Path $tmp 'scripts') $Root -Recurse -Force
  }

  # --- drive ivm ---
  Push-Location $Root
  try {
    Invoke-Ivm init --root $Root                     # anchor the install root explicitly
    Invoke-Ivm install --version $tag                # download + verify + activate
    & $script:ivm service status *> $null
    if ($LASTEXITCODE -ne 0) { Invoke-Ivm service install }   # register (UAC)
    Invoke-Ivm use --version $tag                    # stop -> switch -> start
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
    if ($LASTEXITCODE -ne 0) {
      Write-Host "prereqs: setup did not finish - run  ivm setup  again, then  ivm check"
    }
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
$accounts = Join-Path $Root 'artifactsccounts.json'
$hasAccount = (Test-Path $accounts) -and ((Get-Content -Raw $accounts) -match '0x[0-9a-fA-F]{40}')

if ($hasAccount) {
  Write-Host "wallet: already present - skipping"
} elseif ([Environment]::UserInteractive) {
  Write-Host ""
  Write-Host "A wallet makes you the owner of this node. Without one the node stays open."
  $alias = Read-Host "wallet alias [me] (blank to skip)"
  if ($alias -eq '') { $alias = 'me' }
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
