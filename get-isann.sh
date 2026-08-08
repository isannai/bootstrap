#!/bin/sh
# get-isann.sh — bootstrap an iSANN node on Linux.
#
# Downloads the LATEST ivm (github.com/isannai/isann releases), then lets ivm do
# the rest: init the root, pull the isannd suite, and register the service. ivm
# is standalone (no isannd dependency), so it is the ONLY thing fetched directly
# here — `ivm install` pulls the suite and verifies it with its own sha256.
#
# OS prereqs (Docker + nvidia-container-toolkit) are NOT installed here — run
# `ivm setup` separately once ivm is in place (this script points you to it when
# `ivm check` reports something missing). Keeping them apart makes the install
# fast and free of the heavy WSL/Docker/reboot step.
#
#   curl -fsSL https://<host>/get-isann.sh | sh                                   # default folder
#   curl -fsSL https://<host>/get-isann.sh | sh -s -- --root=/opt/isann           # pick the folder (flag)
#   curl -fsSL https://<host>/get-isann.sh | ISANN_ROOT=/opt/isann sh             # pick the folder (env)
#
# Options:
#   --root=<path>      pre-fills the install-folder prompt (the script ALWAYS asks
#                      on run; Enter accepts the default). --root / $ISANN_ROOT set
#                      that default; else ~/.isann-node. No tty (CI) → default.
#   --version=<tag>    pin a release tag (default: latest)
#   --token=<tok>      GitHub token (only if you hit the anonymous rate limit)
set -eu

ROOT=""
VERSION=""
TOKEN="${GITHUB_TOKEN:-}"
for a in "$@"; do
  case "$a" in
    --root=*)     ROOT="${a#*=}" ;;
    --version=*)  VERSION="${a#*=}" ;;
    --token=*)    TOKEN="${a#*=}" ;;
    *) echo "get-isann.sh: unknown option: $a" >&2; exit 2 ;;
  esac
done

# Install root: ALWAYS prompt on run (Enter accepts the default). --root / $ISANN_ROOT
# only pre-fill the default. Under `curl | sh` stdin IS the script, so read from
# /dev/tty directly; with no controlling terminal (CI) use the default silently.
default="${ROOT:-${ISANN_ROOT:-$HOME/.isann-node}}"
if [ -e /dev/tty ] && [ -r /dev/tty ]; then
  printf "install folder [%s]: " "$default" > /dev/tty
  read ans < /dev/tty || ans=""
  ROOT="${ans:-$default}"
else
  ROOT="$default"
fi

# --- platform -------------------------------------------------------------
case "$(uname -s)" in
  Linux) os=linux ;;
  *) echo "get-isann.sh is for Linux; on Windows run get-isann.ps1" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
asset="ivm-${os}-${arch}.tar.gz"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "tar is required"  >&2; exit 1; }

# curl wrapper that adds the token header only when set (no unsafe word-split).
gh() {
  if [ -n "$TOKEN" ]; then curl -fsSL -H "Authorization: Bearer $TOKEN" "$@"
  else curl -fsSL "$@"; fi
}

owner=isannai; repo=isann
if [ -n "$VERSION" ]; then
  api="https://api.github.com/repos/${owner}/${repo}/releases/tags/${VERSION}"
else
  api="https://api.github.com/repos/${owner}/${repo}/releases/latest"
fi

echo "==> querying $api"
json="$(gh "$api")"
tag="$(printf '%s' "$json" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
url="$(printf '%s' "$json" | grep -o "https://[^\"]*/${asset}" | head -1)"
[ -n "$tag" ] || { echo "could not read a release from GitHub (rate limited? try --token)" >&2; exit 1; }
[ -n "$url" ] || { echo "release $tag ships no $asset" >&2; exit 1; }
echo "==> ivm $tag  ($asset)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tgz="$tmp/$asset"
gh "$url" -o "$tgz"

# Integrity: precise sha256 when jq is present, else trust HTTPS — the SUITE
# (the large payload) is re-verified by `ivm install` against its own digest.
if command -v jq >/dev/null 2>&1; then
  want="$(printf '%s' "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .digest" | sed 's/^sha256://')"
  if [ -n "$want" ] && [ "$want" != "null" ]; then
    if command -v sha256sum >/dev/null 2>&1; then have="$(sha256sum "$tgz" | cut -d' ' -f1)"
    else have="$(shasum -a 256 "$tgz" | cut -d' ' -f1)"; fi
    [ "$want" = "$have" ] || { echo "sha256 mismatch: want $want have $have" >&2; exit 1; }
    echo "==> sha256 ok"
  fi
fi

( cd "$tmp" && tar xf "$tgz" )   # extract (system tar; exec bit set explicitly below)

# --- place ivm + scripts, then drive it -----------------------------------
mkdir -p "$ROOT"
# Stop a running service before overwriting the binary (avoid a busy-file / live proc).
if [ -x "$ROOT/ivm" ] && "$ROOT/ivm" service status >/dev/null 2>&1; then
  "$ROOT/ivm" service stop || true
fi
cp "$tmp/ivm" "$ROOT/ivm"
chmod +x "$ROOT/ivm"   # the tar.gz is built on Windows (no Unix exec bit) — set it here.
                       # (the suite that `ivm install` unpacks gets +x via ExtractTarGz)
[ -d "$tmp/scripts" ] && cp -R "$tmp/scripts" "$ROOT/"

cd "$ROOT"
./ivm init --root "$ROOT"                 # anchor the install root explicitly
./ivm install --version "$tag"           # download + verify + activate the suite
if ! ./ivm service status >/dev/null 2>&1; then
  ./ivm service install                  # register (self-sudo)
fi
./ivm use --version "$tag"               # stop -> switch -> start

echo
echo "iSANN node ready at $ROOT"

# PATH: `ivm init` registered it in your shell rc, so NEW shells get `ivm`
# automatically. This piped shell is a child process and can't inherit that, so
# for THIS shell source the activate script ivm wrote (no way around it — a child
# can't set its parent's PATH).
echo "PATH: new shells have 'ivm' automatically; for THIS shell run:  source \"$ROOT/activate\""

# OS prereqs are a SEPARATE step. Report and point to `ivm setup` if not ready.
if ./ivm check >/dev/null 2>&1; then
  echo "prereqs: OK (Docker / toolkit present)"
else
  echo "prereqs: NOT ready — run  ivm setup  (installs Docker + nvidia-container-toolkit; needs sudo)"
  echo "         then re-check with  ivm check"
fi
echo "next:  ivm account create --alias me   &&   ivm auth transfer --owner me"
echo "  (right now, before activating PATH:  \"$ROOT/ivm\" account create --alias me)"
