# bootstrap

Install scripts for an iSANN node.

They fetch `ivm` (the version manager) and hand over to it: `ivm` pulls the
`isannd` suite, verifies it against its own sha256, and registers the service.

```powershell
# Windows (PowerShell)
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/isannai/bootstrap/main/get-isann.ps1 | iex
```

```sh
# Linux
curl -fsSL https://raw.githubusercontent.com/isannai/bootstrap/main/get-isann.sh | sh
```

## Two roles

The script asks what the node is for. The answer decides how much gets installed.

| | consumer | provider |
|---|---|---|
| what it does | calls other people's nodes | also serves inference to others |
| needs a GPU | no | **yes — NVIDIA** |
| installs | `isannd` + CLI | + WSL2/Docker, nvidia-container-toolkit, station, probe |
| takes | a minute or two | considerably longer, and a reboot on Windows |

`consumer` is the default, because it is the cheaper mistake: a consumer that
later wants to share runs `ivm setup` and pulls the mesh apps, while a provider
install on a machine that never serves leaves several GB of unused stack.

## A provider needs an NVIDIA GPU

The engines run as GPU containers. There is no CPU-only engine path, so a
machine without an NVIDIA GPU **cannot serve inference no matter what is
installed** — it can finish the whole provider install and still answer nobody.

The script checks for a GPU before it asks, and steers a machine without one to
`consumer`. If you pass `--role=provider` explicitly it does as told and says
what will happen, in case the card is not in the machine yet.

A card with the driver missing still counts as a GPU: that is fixable, and
`ivm setup` says what to install.

## Options

Both scripts take the same options.

| option | meaning |
|---|---|
| `--root=<path>` | install folder. The script always asks; this pre-fills the answer. Default: `%LOCALAPPDATA%\isann` (Windows), `~/isann` (Linux) |
| `--version=<tag>` | pin a release tag. Default: latest |
| `--role=<r>` | `consumer` or `provider`. Skips the role question |
| `--token=<tok>` | GitHub token, only if you hit the anonymous rate limit |

Piping into `iex` or `sh` leaves no place for arguments, so the environment
carries them instead:

```powershell
$env:ISANN_ROOT='C:\isann'; $env:ISANN_ROLE='provider'
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/isannai/bootstrap/main/get-isann.ps1 | iex
```

```sh
curl -fsSL https://raw.githubusercontent.com/isannai/bootstrap/main/get-isann.sh | ISANN_ROOT=/opt/isann sh
```

## What else it asks

- **the install folder** — every run asks, Enter accepts the default. If a node
  is already installed the script finds it and offers that folder.
- **elevation** — Windows raises UAC once, when the service is registered. That
  is a separate window; let it finish before continuing.

On a machine with no terminal (CI, a service) nothing is asked: the defaults are
used and the install proceeds unattended.
