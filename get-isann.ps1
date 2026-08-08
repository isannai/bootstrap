<#
  get-isann.ps1 — bootstrap an iSANN node on Windows.

  Downloads the LATEST ivm (github.com/isannai/isann releases), then lets ivm do
  the rest: init the root, pull the isannd suite, and register the S4U service.
  ivm is standalone (no isannd dependency), so it is the ONLY thing fetched
  directly here — `ivm install` pulls the suite and verifies it with its own sha256.

  OS prereqs (WSL2 + Ubuntu + Docker + nvidia-container-toolkit) are NOT installed
  here — run `ivm setup` separately once ivm is in place (this script points you
  to it when `ivm check` reports something missing). Keeping them apart makes the
  install fast and free of the heavy WSL/Docker/reboot step.

    # in a PowerShell window:
    irm https://<host>/get-isann.ps1 | iex                                  # default folder
    $env:ISANN_ROOT='C:\isann'; irm https://<host>/get-isann.ps1 | iex      # pick the folder (piped)
    # from cmd / Run box (one line, anywhere):
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://<host>/get-isann.ps1 | iex"
    # saved to a file:
    .\get-isann.ps1 -Root C:\isann -Version 0.1.2

  Parameters:
    -Root <path>      pre-fills the install-folder prompt (the script ALWAYS asks
                      on run; Enter accepts the default). -Root / $ISANN_ROOT set
                      that default; else %LOCALAPPDATA%\isann. Non-interactive
                      hosts skip the prompt and use the default.
    -Version <tag>    pin a release tag (default: latest)
    -Token <tok>      GitHub token (only if you hit the anonymous rate limit)
#>
param(
  [string]$Root,
  [string]$Version,
  [string]$Token   = $env:GITHUB_TOKEN
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # faster Invoke-WebRequest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Install root: ALWAYS prompt on run (Enter accepts the default). -Root / $ISANN_ROOT
# only pre-fill the default. A piped `irm | iex` keeps the console stdin, so
# Read-Host works; a non-interactive host (CI/service) uses the default silently.
$default = if ($Root) { $Root } elseif ($env:ISANN_ROOT) { $env:ISANN_ROOT } else { Join-Path $env:LOCALAPPDATA 'isann' }
if ([Environment]::UserInteractive) {
  $ans = Read-Host "install folder [$default]"
  if ($ans) { $Root = $ans } else { $Root = $default }
} else {
  $Root = $default
}

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

# OS prereqs are a SEPARATE step. Report and point to `ivm setup` if not ready.
& $script:ivm check *> $null
if ($LASTEXITCODE -eq 0) {
  Write-Host "prereqs: OK (WSL / Docker / toolkit present)"
} else {
  Write-Host "prereqs: NOT ready - run  ivm setup  (installs WSL2 + Docker + nvidia-container-toolkit; prompts for UAC)"
  Write-Host "         then re-check with  ivm check"
}
Write-Host "next:  ivm account create --alias me   ;   ivm auth transfer --owner me"
