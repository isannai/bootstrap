#!/bin/sh
# get-isann.sh — bootstrap an iSANN node on Linux.
#
# Downloads the LATEST ivm (github.com/isannai/isann releases), then lets ivm do
# the rest: init the root, pull the isannd suite, and register the service. ivm
# is standalone (no isannd dependency), so it is the ONLY thing fetched directly
# here — `ivm install` pulls the suite and verifies it with its own sha256.
#
# OS prereqs (Docker + nvidia-container-toolkit) install only for
# --role=provider, by running `ivm setup` once ivm is in place. A consumer node
# calls other nodes and runs nothing locally, so it skips all of it.
#
#   curl -fsSL https://<host>/get-isann.sh | sh                                   # default folder
#   curl -fsSL https://<host>/get-isann.sh | sh -s -- --root=/opt/isann           # pick the folder (flag)
#   curl -fsSL https://<host>/get-isann.sh | ISANN_ROOT=/opt/isann sh             # pick the folder (env)
#
# Options:
#   --root=<path>      pre-fills the install-folder prompt (the script ALWAYS asks
#                      on run; Enter accepts the default). --root / $ISANN_ROOT set
#                      that default; else ~/isann. No tty (CI) → default.
#   --version=<tag>    pin a release tag (default: latest)
#   --role=<r>         consumer | provider. Skips the role question. A consumer
#                      node only CALLS other nodes, so it needs no station, no
#                      probe, no Docker, no GPU. Default when not asked: consumer
#   --token=<tok>      GitHub token (only if you hit the anonymous rate limit)
set -eu

ROOT=""
VERSION=""
ROLE="${ISANN_ROLE:-}"
TOKEN="${GITHUB_TOKEN:-}"
for a in "$@"; do
  case "$a" in
    --root=*)     ROOT="${a#*=}" ;;
    --version=*)  VERSION="${a#*=}" ;;
    --role=*)     ROLE="${a#*=}" ;;
    --token=*)    TOKEN="${a#*=}" ;;
    *) echo "get-isann.sh: unknown option: $a" >&2; exit 2 ;;
  esac
done

# Install root: ALWAYS prompt on run (Enter accepts the default). --root / $ISANN_ROOT
# only pre-fill the default. Under `curl | sh` stdin IS the script, so read from
# /dev/tty directly; with no controlling terminal (CI) use the default silently.
default="${ROOT:-${ISANN_ROOT:-$HOME/isann}}"
if [ -e /dev/tty ] && [ -r /dev/tty ]; then
  # Say up front that this is not the only prompt. The download and the service
  # registration sit between the two, so someone who walks away comes back to a
  # question still waiting rather than a finished install.
  echo "This asks you two things: the install folder now, and a wallet passphrase at the end." > /dev/tty
  echo "sudo may also ask for your password when the service is registered." > /dev/tty
  echo "" > /dev/tty
  printf "install folder [%s]: " "$default" > /dev/tty
  read ans < /dev/tty || ans=""
  ROOT="${ans:-$default}"
else
  ROOT="$default"
fi

# Role decides how much of the stack this node needs, and it is asked here so
# every question is answered before the long download starts.
#
# A consumer calls other nodes over `--nodes`; isannd dials the peer directly,
# so nothing runs locally: no station (that serves YOUR engine to others), no
# probe, no Docker, no GPU driver. A provider needs all of it.
#
# The default is consumer because it is the cheaper mistake: a consumer that
# later wants to share runs `ivm setup` + `isann mesh pull`, whereas a provider
# install on a machine that never serves leaves several GB of unused stack.
case "$ROLE" in
  consumer|provider) ;;
  *)
    if [ -e /dev/tty ] && [ -r /dev/tty ]; then
      echo "" > /dev/tty
      echo "what will this node do?" > /dev/tty
      echo "  1) consumer - use other nodes only      (default)" > /dev/tty
      echo "  2) provider - also serve inference to others" > /dev/tty
      printf "choice [1]: " > /dev/tty
      read choice < /dev/tty || choice=""
      if [ "$choice" = "2" ]; then ROLE="provider"; else ROLE="consumer"; fi
    else
      ROLE="consumer"
    fi
    ;;
esac
echo "role: $ROLE"

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
# A provider was asked to serve inference, which is impossible without Docker,
# so the install runs `ivm setup` itself rather than printing a command the
# operator has to notice. A consumer runs no engines and needs none of it.
if [ "$ROLE" != "provider" ]; then
  echo "prereqs: not needed - a consumer node runs no engines locally"
elif ./ivm check >/dev/null 2>&1; then
  echo "prereqs: OK (Docker / toolkit present)"
else
  echo ""
  echo "==> installing OS prereqs (Docker + NVIDIA toolkit)"
  echo "    this needs sudo."
  ./ivm setup || echo "prereqs: setup did not finish - run  ivm setup  again, then  ivm check"
fi
echo "next:  ivm account create --alias me   &&   ivm auth transfer --owner me"
echo "  (right now, before activating PATH:  \"$ROOT/ivm\" account create --alias me)"

# --- mesh connectors (station, probe) ---
# Pulled here rather than left to the operator: a node without a station cannot
# serve anyone, and finding the right release asset by hand is the step people
# skip. latest/download follows GitHub's redirect to the newest release, so this
# script does not have to be edited when a version ships.
#
# Downloaded but NOT started: station is only useful once an engine exists
# (isann docker create llama). A failure here is reported and does not fail the
# install - the node itself is already up.
ISANN="$ROOT/bin/isann"
if [ "$ROLE" != "provider" ]; then
  echo "consumer node - skipping station/probe (add them later with: isann mesh pull ...)"
elif [ -x "$ISANN" ]; then
  for m in station probe; do
    url="https://github.com/isannai/mesh/releases/latest/download/$m-linux-amd64.tar.gz"
    echo "==> mesh pull $m"
    if ! "$ISANN" mesh pull "$url" --name "$m" -force; then
      echo "    $m pull failed - install it later with:  isann mesh pull $url --name $m"
    fi
  done
else
  echo "isann not found at $ISANN - skipping station/probe"
fi

# --- wallet + owner ---
# The node runs in OPEN mode until it has an owner: every admin endpoint is
# ungated. So this is not an optional flourish, it is the step that closes the
# door - which is why the script offers it rather than only printing it.
#
# The passphrase is typed here, never generated and never stored: it is the ONLY
# way to unlock the key and there is no recovery path, so a script that invented
# one would be handing out an account nobody can hold. Piping into sh leaves
# stdin on the pipe, not the terminal, so the prompt reads /dev/tty; when there
# is no tty (CI, service) the two commands are printed instead.
ACCOUNTS="$ROOT/artifacts/accounts.json"
if [ -f "$ACCOUNTS" ] && grep -qE '0x[0-9a-fA-F]{40}' "$ACCOUNTS" 2>/dev/null; then
  echo "wallet: already present - skipping"
elif [ -r /dev/tty ]; then
  echo ""
  echo "A wallet makes you the owner of this node. Without one the node stays open."
  printf "wallet alias [me] (type 'skip' to do it later): " > /dev/tty
  read -r alias < /dev/tty || alias=""
  [ -z "$alias" ] && alias="me"
  if [ "$alias" != "skip" ]; then
    if "$ROOT/ivm" account create --alias "$alias" < /dev/tty; then
      "$ROOT/ivm" auth transfer --owner "$alias" -y ||
        echo "owner not set - run:  ivm auth transfer --owner $alias"
    else
      echo "wallet not created - run:  ivm account create --alias $alias"
    fi
  fi
else
  echo "wallet: no tty - run these yourself:"
  echo "  ivm account create --alias me"
  echo "  ivm auth transfer --owner me"
fi

echo ""
# A recipe does the whole setup in one command: unlock, model download, engine
# start, station, rendezvous. They ship with the release, so nothing to fetch.
if [ "$ROLE" = "provider" ]; then
  echo "next - pick a recipe and run it:"
  echo ""
  echo "  isann recipe exec install-llama-small     Qwen2.5-1.5B    VRAM 4G+"
  echo "  isann recipe exec install-llama-medium    Qwen2.5-14B     VRAM 12G+"
  echo "  isann recipe exec install-sd-small        SD 1.5 images   VRAM 4G+"
  echo ""
  echo "  it asks for your account alias and a rendezvous url, then does the rest:"
  echo "  model download, engine start, station, rendezvous registration."
  echo ""
  echo "  isann recipe list      what else is on this node"
else
  echo "next - run the recipe:"
  echo ""
  echo "  isann recipe exec install-passenger"
  echo ""
  echo "  it asks for your account alias and a rendezvous url, then registers"
  echo "  this node and lists who is out there."
  echo ""
  echo "  then:  isann infer run --engine llama --prompt \"hello\" --nodes <node> -wait"
  echo ""
  echo "  to share this node later:  ivm setup  then  isann mesh pull ..."
fi
