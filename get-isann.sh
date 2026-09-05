#!/usr/bin/env bash
# iSANN node bootstrap installer (Ubuntu / WSL Ubuntu).
#
# Prepares an iSANN provider node for Docker-based AI engines
# (sd.cpp.external pattern). Install != run: this script only sets up
# capability. The operator starts services explicitly.
#
#   1. Checks the NVIDIA driver (does NOT install it, and does NOT block on it)
#   2. Installs Docker Engine (if missing, or too old -see MIN_DOCKER)
#   3. Installs nvidia-container-toolkit (if missing)
#   4. Verifies GPU access from a container (SKIPPED when no driver is present)
#   5. Pulls AI engine images (only if missing -no version check, no upgrade)
#   6. Writes systemd unit files (DISABLED -operator runs systemctl enable later)
#
# Idempotency contract (re-run = no-op):
#   - System packages already present -skip
#   - Engine image already present locally -skip (no version compare, no
#     registry hit). Older local image is left alone.
#   - systemd unit file already present -skip (left untouched)
#
# Upgrades are an explicit operator action, never a side-effect of install:
#   sudo docker pull isannai/sd:latest
#   sudo systemctl restart isann-sd-0
#
# One-line install (operator side):
#   curl -fsSL https://raw.githubusercontent.com/<repo>/main/deploy/scripts/install-isann-node.sh | sudo bash
#
# Local run (from repo root):
#   sudo ./deploy/scripts/install-isann-node.sh
#
# Env overrides:
#   ISANN_USER         OS user that runs containers (default: $SUDO_USER or current)
#   ISANN_HOME         iSANN state dir (default: /opt/isann)
#   ISANN_MODELS_DIR   model storage (default: $ISANN_HOME/models)
#   SD_IMAGE          SD engine image (default: isannai/sd:latest)
#   SD_PORT_BASE      first SD container port (default: 7860, GPU N ->7860+N)
#   SD_MODEL          model file under ISANN_MODELS_DIR (default: empty ->skip SD setup)
#   ENGINES           comma-separated engines to install (default: sd)
#                     CURRENTLY SUPPORTED: sd, none
#                     PLANNED (blocked for now, one-at-a-time verification):
#                       llama, vllm, whisper, tts, yolo
#                     example: ENGINES=sd
#   MIN_DOCKER        minimum acceptable Docker version (default: 20.10)
#   DRY_RUN           1 = print actions, don't execute (default: 0)
#   YES               1 = skip confirmation prompt (default: 0)

set -euo pipefail

# -----------------------------------------------------------------------------
# Globals
# -----------------------------------------------------------------------------

ISANN_USER="${ISANN_USER:-${SUDO_USER:-$USER}}"
ISANN_HOME="${ISANN_HOME:-/opt/isann}"
ISANN_MODELS_DIR="${ISANN_MODELS_DIR:-${ISANN_HOME}/models}"
ISANN_OUTPUTS_DIR="${ISANN_OUTPUTS_DIR:-${ISANN_HOME}/outputs}"
ISANN_LOG_DIR="${ISANN_LOG_DIR:-/var/log/isann}"
LOG_FILE="${ISANN_LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

SD_IMAGE="${SD_IMAGE:-isannai/sd:latest}"
SD_PORT_BASE="${SD_PORT_BASE:-7860}"
SD_MODEL="${SD_MODEL:-}"

# Other engines are PLANNED but currently DISABLED. They will be enabled
# one-at-a-time as the Dockerfile / image / manifest / E2E test for each
# is verified. Keeping the variable declarations here so re-enabling is
# a one-line change later.
#
# LLAMA_IMAGE="${LLAMA_IMAGE:-isannai/llama:latest}"
# LLAMA_PORT_BASE="${LLAMA_PORT_BASE:-7900}"
#
# VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:latest}"
# VLLM_PORT_BASE="${VLLM_PORT_BASE:-8000}"
#
# WHISPER_IMAGE="${WHISPER_IMAGE:-isannai/whisper:latest}"
# WHISPER_PORT_BASE="${WHISPER_PORT_BASE:-9000}"
#
# TTS_IMAGE="${TTS_IMAGE:-isannai/tts:latest}"
# TTS_PORT_BASE="${TTS_PORT_BASE:-9100}"
#
# YOLO_IMAGE="${YOLO_IMAGE:-isannai/yolo:latest}"
# YOLO_PORT_BASE="${YOLO_PORT_BASE:-9200}"

ENGINES="${ENGINES:-sd}"
DRY_RUN="${DRY_RUN:-0}"
YES="${YES:-0}"
# Minimum Docker for `--gpus` + a toolkit that still gets security updates.
# 19.03 is where `--gpus` landed; 20.10 is the first release the current
# nvidia-container-toolkit packages actually target, so that is the floor.
MIN_DOCKER="${MIN_DOCKER:-20.10}"

# Colors (skip if not a TTY)
if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log()  { echo -e "$@" | tee -a "${LOG_FILE}"; }
info() { log "${C_BLUE}[i]${C_RESET} $*"; }
ok()   { log "${C_GREEN}[+]${C_RESET} $*"; }
warn() { log "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { log "${C_RED}[x]${C_RESET} $*"; }
step() { log "\n${C_BOLD}[$1/$STEPS_TOTAL]${C_RESET} $2"; }

run() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "  ${C_YELLOW}[DRY]${C_RESET} $*"
    return 0
  fi
  log "  ${C_BLUE}\$${C_RESET} $*"
  "$@" 2>&1 | tee -a "${LOG_FILE}"
  return ${PIPESTATUS[0]}
}

# Run a command with retries + exponential backoff. Use only for
# transient-prone ops (network, registry). Local commands (systemctl,
# nvidia-ctk, mkdir, ...) should call `run` directly -retrying a
# misconfiguration just delays the error.
retry_run() {
  local max_attempts=5
  local delay=3
  local attempt=1
  while true; do
    if run "$@"; then
      return 0
    fi
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      err "Command failed after ${max_attempts} attempts: $*"
      return 1
    fi
    warn "  Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
    sleep "${delay}"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# Wait for outbound network to be ready. At fresh boot / right after WSL
# first-boot, DNS or routing may still be coming up. We pick an HTTPS
# endpoint we'll actually use (Docker repo) so the check exercises DNS +
# TCP + TLS + HTTP all at once.
wait_for_network() {
  local max_retries="${1:-30}"
  local sleep_sec=2
  info "Waiting for network..."
  for ((i=1; i<=max_retries; i++)); do
    if curl -fsS --max-time 5 -o /dev/null https://download.docker.com/ 2>/dev/null; then
      ok "Network ready"
      return 0
    fi
    sleep "${sleep_sec}"
  done
  err "Network not ready after $((max_retries * sleep_sec))s"
  err "  Check: DNS resolution, outbound HTTPS reach, proxy / firewall"
  err "  Test manually: curl -v https://download.docker.com/"
  exit 1
}

# version_ge A B -true when version A >= B. Dotted numeric compare, so
# "20.10.24" >= "20.10" and "9.0" < "20.10" (a plain string compare gets that
# one wrong). Non-numeric suffixes are ignored: Docker ships "24.0.7" but also
# "20.10.24+dfsg1" on some distros.
version_ge() {
  local a b
  a=$(printf '%s' "$1" | tr -cd '0-9.' )
  b=$(printf '%s' "$2" | tr -cd '0-9.' )
  [ "$(printf '%s
%s
' "$b" "$a" | sort -V | head -1)" = "$b" ]
}

# Wait for dockerd to be ready to accept commands. systemctl start/restart
# returns when the unit is launched, but the daemon takes a moment to bind
# its socket. Polling `docker info` is the canonical readiness check.
wait_for_docker() {
  local max_retries="${1:-30}"
  local sleep_sec=2
  info "Waiting for Docker daemon to be ready..."
  for ((i=1; i<=max_retries; i++)); do
    if docker info >/dev/null 2>&1; then
      ok "Docker daemon ready"
      return 0
    fi
    sleep "${sleep_sec}"
  done
  err "Docker daemon did not become ready after $((max_retries * sleep_sec))s"
  err "  Check daemon state:"
  if [ "${HAS_SYSTEMD}" -eq 1 ]; then
    err "    sudo systemctl status docker"
    err "    sudo journalctl -u docker -n 50"
  else
    err "    sudo service docker status"
  fi
  exit 1
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script requires root. Re-run with sudo:"
    err "  sudo $0 $*"
    exit 1
  fi
}

require_ubuntu() {
  if [ ! -f /etc/os-release ]; then
    err "/etc/os-release not found - unsupported OS"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}" in
    ubuntu|debian) ok "OS: ${PRETTY_NAME}" ;;
    *)
      err "Unsupported OS: ${ID} (${PRETTY_NAME})"
      err "Only Ubuntu 22.04+ or Debian 11+ are supported"
      exit 1
      ;;
  esac
}

setup_dirs() {
  mkdir -p "${ISANN_HOME}" "${ISANN_MODELS_DIR}" "${ISANN_OUTPUTS_DIR}" "${ISANN_LOG_DIR}"
  chown -R "${ISANN_USER}:${ISANN_USER}" "${ISANN_HOME}"
}

# -----------------------------------------------------------------------------
# State detection
# -----------------------------------------------------------------------------

detect_state() {
  log ""
  log "${C_BOLD}=== iSANN Node Installer ===${C_RESET}"
  log ""

  # NVIDIA driver - must be >= 525 for CUDA 12.0 (the image's CUDA runtime).
  # An older driver makes the CUDA 12.0 binary inside the container fail
  # with 'driver too old'.
  # We picked CUDA 12.0 because driver 525+ supports Pascal/Turing widely.
  MIN_DRIVER=525
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    HAS_NVIDIA_DRIVER=1
    DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | awk -F. '{print $1}')
    DRIVER_VERSION="${DRIVER_VERSION//[[:space:]]/}"
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)
    # `nvidia-smi -L | wc -l` is more reliable than `--query-gpu=count`.
    # `count` is missing on older / datacenter drivers and returns N rows
    # of the same value for multi-GPU, requiring fragile head/dedupe. `-L`
    # always prints one line per visible GPU.
    GPU_COUNT=$(nvidia-smi -L | wc -l)
    GPU_COUNT="${GPU_COUNT//[[:space:]]/}"
    if [ "${DRIVER_VERSION}" -ge "${MIN_DRIVER}" ] 2>/dev/null; then
      ok "NVIDIA driver: ${DRIVER_VERSION}.x (${GPU_COUNT} GPU, ${GPU_INFO}) -CUDA 12.0 compatible"
      DRIVER_OK=1
    else
      warn "NVIDIA driver: ${DRIVER_VERSION}.x -too old for CUDA 12.0 (need >= ${MIN_DRIVER})"
      DRIVER_OK=0
    fi
  else
    HAS_NVIDIA_DRIVER=0
    DRIVER_OK=0
    warn "NVIDIA driver: NOT detected"
  fi

  # systemd presence (init system). Canonical check: /run/systemd/system
  # exists iff systemd is running as PID 1. Works on bare metal and WSL2
  # with `systemd=true` enabled. WSL without systemd will still install
  # Docker / images, but auto-start via systemd unit is unavailable.
  if [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
    ok "systemd: active"
  else
    HAS_SYSTEMD=0
    warn "systemd: not active (likely WSL without 'systemd=true' in /etc/wsl.conf)"
    warn "  Docker / engine images install fine, but auto-start units are skipped."
    warn "  To enable systemd in WSL: put '[boot]\\nsystemd=true' in /etc/wsl.conf,"
    warn "  run 'wsl --shutdown' from PowerShell, then re-run this installer."
  fi

  # Docker. Present is not enough - an old daemon has no `--gpus` and the
  # current toolkit packages do not target it, so a too-old install is treated
  # as "needs work" rather than silently accepted.
  if command -v docker >/dev/null 2>&1; then
    HAS_DOCKER=1
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
    if version_ge "${DOCKER_VERSION}" "${MIN_DOCKER}"; then
      DOCKER_OK=1
      ok "Docker: detected (${DOCKER_VERSION})"
    else
      DOCKER_OK=0
      warn "Docker: ${DOCKER_VERSION} is older than ${MIN_DOCKER} (will upgrade)"
    fi
  else
    HAS_DOCKER=0
    DOCKER_OK=0
    info "Docker: not installed (will install)"
  fi

  # nvidia-container-toolkit
  if dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q '^ii'; then
    HAS_NCT=1
    ok "nvidia-container-toolkit: detected"
  else
    HAS_NCT=0
    info "nvidia-container-toolkit: not installed (will install)"
  fi

  # Container GPU access (only meaningful if all of above are present)
  if [ "${HAS_DOCKER}" -eq 1 ] && [ "${HAS_NCT}" -eq 1 ] && [ "${HAS_NVIDIA_DRIVER}" -eq 1 ]; then
    if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
      GPU_FROM_CONTAINER=1
      ok "Container GPU access: working"
    else
      GPU_FROM_CONTAINER=0
      warn "Container GPU access: NOT working (will fix)"
    fi
  else
    GPU_FROM_CONTAINER=0
  fi

  # iSANN engine images (only sd is currently enabled)
  local installed_engines=""
  for engine in sd; do
    local img
    case "${engine}" in
      sd) img="${SD_IMAGE}" ;;
    esac
    if docker image inspect "${img}" >/dev/null 2>&1; then
      installed_engines="${installed_engines}${engine}:OK "
    fi
  done
  if [ -n "${installed_engines}" ]; then
    ok "Engine images present: ${installed_engines}"
  fi
}

confirm() {
  log ""
  log "${C_BOLD}Plan:${C_RESET}"
  [ "${HAS_NVIDIA_DRIVER}" -eq 0 ] && log "  - ${C_RED}NVIDIA driver missing${C_RESET} (must install manually first)"
  [ "${HAS_DOCKER}" -eq 0 ]        && log "  - Install Docker Engine"
  [ "${HAS_NCT}" -eq 0 ]           && log "  - Install nvidia-container-toolkit"
  [ "${GPU_FROM_CONTAINER}" -eq 0 ] && [ "${HAS_NVIDIA_DRIVER}" -eq 1 ] \
                                   && log "  - Configure Docker for GPU + verify"
  log "  - Pull missing engine images: ${ENGINES} (skip any image already present)"
  if [ "${HAS_SYSTEMD}" -ne 1 ]; then
    log "  - Skip systemd unit creation (systemd not active)"
  elif [ -n "${SD_MODEL}" ]; then
    log "  - Write systemd unit per GPU (left DISABLED - operator starts manually)"
  else
    log "  - Skip systemd unit creation (SD_MODEL not set)"
  fi
  log ""
  log "Install dir:  ${ISANN_HOME}"
  log "Models dir:   ${ISANN_MODELS_DIR}"
  log "Outputs dir:  ${ISANN_OUTPUTS_DIR}"
  log "Log file:     ${LOG_FILE}"
  log ""

  # 🔴 The driver is NOT a gate. Installing one from here is not something a
  # script should attempt (it is distro-, kernel- and Secure-Boot-specific, and
  # on WSL it lives on the Windows side entirely), so blocking on it only meant
  # the operator could not get Docker and the toolkit in place beforehand.
  # Everything installs; only the GPU verification is skipped, and `ivm check`
  # keeps reporting the node as not-ready until a driver appears.
  if [ "${HAS_NVIDIA_DRIVER}" -eq 0 ]; then
    warn "NVIDIA driver not detected -installing Docker and the toolkit anyway."
    warn "  GPU inference will not work until you install one and reboot:"
    warn "    sudo ubuntu-drivers install && sudo reboot"
    warn "  (on WSL the driver is installed on the WINDOWS side, not in here)"
  elif [ "${DRIVER_OK}" -eq 0 ]; then
    warn "NVIDIA driver ${DRIVER_VERSION}.x is older than ${MIN_DRIVER} -CUDA 12.0 images will fail."
    warn "  Upgrade and reboot when convenient:"
    warn "    sudo apt install nvidia-driver-${MIN_DRIVER}"
  fi

  if [ "${YES}" -eq 1 ] || [ "${DRY_RUN}" -eq 1 ]; then
    return
  fi
  read -r -p "Proceed? [Y/n] " ans
  case "${ans}" in
    ''|y|Y|yes|Yes) ;;
    *) info "Aborted by user"; exit 0 ;;
  esac
}

# -----------------------------------------------------------------------------
# Install steps
# -----------------------------------------------------------------------------

install_docker() {
  if [ "${HAS_DOCKER}" -eq 1 ] && [ "${DOCKER_OK}" -eq 1 ]; then
    ok "Docker already installed -skip"
    return
  fi
  if [ "${HAS_DOCKER}" -eq 1 ]; then
    info "Docker ${DOCKER_VERSION} is below ${MIN_DOCKER} -upgrading via the official apt repository"
  fi
  info "Installing Docker Engine via Docker's official apt repository..."

  # Why apt repo, not get.docker.com:
  #   - Every package verified against Docker's GPG key (apt does this)
  #   - Future `apt upgrade` keeps the same trust chain
  #   - No `curl | sh` pattern -no opaque remote-shell-as-root surface

  # Prereqs for apt-over-HTTPS + GPG key handling
  retry_run apt-get update
  retry_run apt-get install -y ca-certificates curl gnupg

  # ID = ubuntu | debian; VERSION_CODENAME = jammy / bookworm / ...
  # shellcheck disable=SC1091
  . /etc/os-release
  local repo_distro="${ID}"

  # Docker's official GPG key (used to verify .deb signatures via apt)
  run install -m 0755 -d /etc/apt/keyrings
  retry_run sh -c "curl -fsSL https://download.docker.com/linux/${repo_distro}/gpg -o /etc/apt/keyrings/docker.asc"
  run chmod a+r /etc/apt/keyrings/docker.asc

  # Signed apt source line pointing at Docker's official repo
  local arch
  arch=$(dpkg --print-architecture)
  run sh -c "echo 'deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_distro} ${VERSION_CODENAME} stable' > /etc/apt/sources.list.d/docker.list"

  # Install Docker Engine + containerd + compose plugin
  retry_run apt-get update
  retry_run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  run usermod -aG docker "${ISANN_USER}"
  if [ "${HAS_SYSTEMD}" -eq 1 ]; then
    run systemctl enable docker
    run systemctl start docker
    wait_for_docker
  else
    warn "systemd not active -skip enable/start. Start Docker manually:"
    warn "  sudo service docker start    # or: sudo dockerd &"
  fi
  ok "Docker installed"
}

install_nvidia_container_toolkit() {
  if [ "${HAS_NCT}" -eq 1 ]; then
    ok "nvidia-container-toolkit already installed -skip"
    return
  fi
  info "Installing nvidia-container-toolkit..."
  retry_run curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    -o /usr/share/keyrings/nvidia-container-toolkit.gpg.armor
  run sh -c 'gpg --dearmor < /usr/share/keyrings/nvidia-container-toolkit.gpg.armor > /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
  run rm -f /usr/share/keyrings/nvidia-container-toolkit.gpg.armor

  retry_run sh -c "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list"

  retry_run apt-get update
  retry_run apt-get install -y nvidia-container-toolkit
  run nvidia-ctk runtime configure --runtime=docker
  if [ "${HAS_SYSTEMD}" -eq 1 ]; then
    run systemctl restart docker
    wait_for_docker
  else
    warn "systemd not active -restart Docker manually for runtime config to take effect:"
    warn "  sudo service docker restart"
  fi
  ok "nvidia-container-toolkit installed + Docker configured"
}

verify_gpu_container() {
  info "Verifying GPU access from container..."
  if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    ok "GPU accessible from container"
    GPU_FROM_CONTAINER=1
    return
  fi

  # Toolkit installed but Docker not yet wired. Re-run the configure step
  # and restart the daemon. Both ops are idempotent so this is safe even
  # when nothing was wrong.
  warn "GPU container access failed - re-applying nvidia-ctk runtime config..."
  run nvidia-ctk runtime configure --runtime=docker
  if [ "${HAS_SYSTEMD}" -eq 1 ]; then
    run systemctl restart docker
    wait_for_docker
  else
    warn "systemd not active -restart Docker manually then retry:"
    warn "  sudo service docker restart"
    err "Cannot proceed without Docker restart -aborting"
    exit 1
  fi

  if run docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    ok "GPU accessible from container (after reconfigure)"
    GPU_FROM_CONTAINER=1
  else
    err "GPU access from container still FAILED after reconfigure"
    err "  Run manually to debug:"
    err "    docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi"
    exit 1
  fi
}

pull_engine_images() {
  # Idempotency rule: if the image already exists locally, skip the pull
  # entirely. We do NOT compare versions and do NOT hit the registry. An
  # older local image is left untouched -upgrades are an explicit operator
  # action (`docker pull <img>`), never a side-effect of re-running install.
  pull_if_missing() {
    local img="$1"
    if docker image inspect "${img}" >/dev/null 2>&1; then
      ok "  ${img} already present -skip (run 'docker pull ${img}' to upgrade)"
      return
    fi
    info "  Pulling ${img}..."
    retry_run docker pull "${img}"
  }

  IFS=',' read -ra engines_arr <<< "${ENGINES}"
  for engine in "${engines_arr[@]}"; do
    engine=$(echo "${engine}" | xargs)
    case "${engine}" in
      sd)
        pull_if_missing "${SD_IMAGE}"
        ;;
      none|"")
        info "Engine pulls skipped (ENGINES=none)"
        ;;
      llama|vllm|whisper|tts|yolo)
        warn "Engine '${engine}' is planned but not yet available -skip"
        warn "  Image / manifest / E2E test pending. Currently only 'sd' is supported."
        ;;
      *)
        warn "Unknown engine: ${engine} -skip"
        ;;
    esac
  done
  ok "Engine images ready"
}

install_systemd_units() {
  # Install != run. Write unit FILES only. Never enable, never start.
  # An existing unit is left untouched -re-running install is a no-op for
  # any GPU that already has a unit. To regenerate, the operator must
  # remove the unit file first (`rm /etc/systemd/system/isann-sd-<N>.service`)
  # and re-run, or edit the file manually.
  if [ "${HAS_SYSTEMD}" -ne 1 ]; then
    warn "systemd not active -skip unit creation. Engines must be started"
    warn "  manually via 'docker run ...' until systemd is enabled."
    return
  fi
  if [ -z "${SD_MODEL}" ]; then
    warn "SD_MODEL not set -skip systemd unit creation"
    warn "  Place a model under ${ISANN_MODELS_DIR}/ then re-run with SD_MODEL=<file>"
    return
  fi
  local model_path="${ISANN_MODELS_DIR}/${SD_MODEL}"
  if [ ! -f "${model_path}" ]; then
    err "Model file not found: ${model_path}"
    err "  Place your .safetensors file under ${ISANN_MODELS_DIR}/ and re-run"
    exit 1
  fi

  # Extension check (hard fail). sd.cpp loads .safetensors, .ckpt, .gguf.
  # Anything else will cause the container to crash on load -catching here
  # gives a clear message instead of an obscure docker logs error.
  case "${SD_MODEL,,}" in
    *.safetensors|*.ckpt|*.gguf) ;;
    *)
      err "Unsupported model extension: ${SD_MODEL}"
      err "  sd.cpp loads .safetensors, .ckpt, or .gguf. Got: $(basename "${SD_MODEL}")"
      exit 1
      ;;
  esac

  # Size sanity check (warn only). SD checkpoints are GB-scale; a tiny
  # file usually means the operator pointed at a LoRA / embedding by
  # mistake or a partial download. We do NOT hard-fail because future
  # quantized formats may legitimately be smaller.
  local model_size
  model_size=$(stat -c%s "${model_path}" 2>/dev/null || echo 0)
  if [ "${model_size}" -lt 104857600 ]; then
    warn "Model file is small ($(numfmt --to=iec --suffix=B "${model_size}" 2>/dev/null || echo "${model_size} bytes"))."
    warn "  SD base checkpoints are typically 2-10 GB. Confirm this is the right file."
    warn "  (LoRA / embedding files belong elsewhere, not as the main --model arg.)"
  fi

  info "Writing systemd unit per GPU (${GPU_COUNT} GPU detected)..."
  local any_written=0
  for ((i=0; i<GPU_COUNT; i++)); do
    local unit_name="isann-sd-${i}"
    local port=$((SD_PORT_BASE + i))
    local unit_file="/etc/systemd/system/${unit_name}.service"

    if [ -f "${unit_file}" ]; then
      ok "  ${unit_name} unit already exists -skip"
      continue
    fi

    cat > "${unit_file}" <<EOF
[Unit]
Description=iSANN sd.cpp engine (GPU ${i})
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=10
# Sandboxing applies to the docker CLI wrapper, not the container.
# The container itself is hardened via docker run flags below.
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ExecStartPre=-/usr/bin/docker stop ${unit_name}
ExecStartPre=-/usr/bin/docker rm ${unit_name}
ExecStart=/usr/bin/docker run --rm --name ${unit_name} \\
  --security-opt no-new-privileges \\
  --gpus "device=${i}" \\
  -p 127.0.0.1:${port}:7860 \\
  -v "${ISANN_MODELS_DIR}:/models:ro" \\
  -v "${ISANN_OUTPUTS_DIR}:/outputs" \\
  ${SD_IMAGE} \\
    --model "/models/${SD_MODEL}" \\
    --listen-ip 0.0.0.0 \\
    --listen-port 7860
ExecStop=/usr/bin/docker stop ${unit_name}

[Install]
WantedBy=multi-user.target
EOF
    ok "  ${unit_name} written ->port ${port} (GPU ${i}) [disabled]"
    any_written=1
  done

  if [ "${any_written}" -eq 1 ]; then
    run systemctl daemon-reload
  fi
}

print_summary() {
  log ""
  log "${C_GREEN}${C_BOLD}=== Install complete ===${C_RESET}"
  log ""
  log "GPU count:     ${GPU_COUNT}"
  log "Install dir:   ${ISANN_HOME}"
  log "Models dir:    ${ISANN_MODELS_DIR}"
  log "Outputs dir:   ${ISANN_OUTPUTS_DIR}"
  log "Log file:      ${LOG_FILE}"
  log ""
  if [ "${HAS_SYSTEMD}" -eq 1 ]; then
    log "${C_BOLD}Install completed -nothing is running yet.${C_RESET}"
    log "Engine images are pulled, systemd units are written but DISABLED."
    log ""
    log "${C_BOLD}To start serving:${C_RESET}"
    log "  1. Stage a model file under: ${ISANN_MODELS_DIR}/"
    log "  2. Edit /etc/systemd/system/isann-sd-0.service if needed"
    log "  3. sudo systemctl enable --now isann-sd-0"
    log "     (repeat for isann-sd-1, isann-sd-2, ... if multi-GPU)"
    log "  4. Verify: curl http://127.0.0.1:${SD_PORT_BASE}/"
    log ""
    log "${C_BOLD}To upgrade an engine image (explicit operator action):${C_RESET}"
    log "  sudo docker pull ${SD_IMAGE}"
    log "  sudo systemctl restart isann-sd-0"
  else
    log "${C_BOLD}Install completed -nothing is running yet.${C_RESET}"
    log "Engine images are pulled. systemd units were NOT created (systemd inactive)."
    log ""
    log "${C_BOLD}To start serving (manual, since systemd is off):${C_RESET}"
    log "  1. Stage a model file under: ${ISANN_MODELS_DIR}/"
    log "  2. Ensure Docker is running: sudo service docker start"
    log "  3. docker run -d --name isann-sd-0 --gpus 'device=0' \\"
    log "       -p 127.0.0.1:${SD_PORT_BASE}:7860 \\"
    log "       -v ${ISANN_MODELS_DIR}:/models:ro \\"
    log "       -v ${ISANN_OUTPUTS_DIR}:/outputs \\"
    log "       ${SD_IMAGE} --model /models/<your-model.safetensors>"
    log "  4. Verify: curl http://127.0.0.1:${SD_PORT_BASE}/"
    log ""
    log "${C_BOLD}For auto-start (recommended), enable systemd:${C_RESET}"
    log "  echo -e '[boot]\\nsystemd=true' | sudo tee /etc/wsl.conf"
    log "  # From PowerShell on Windows: wsl --shutdown"
    log "  # Then re-run this installer to get systemd units."
    log ""
    log "${C_BOLD}To upgrade an engine image:${C_RESET}"
    log "  sudo docker pull ${SD_IMAGE}"
    log "  # Restart container manually (docker stop + docker run)"
  fi
  log ""
  log "${C_BOLD}Other:${C_RESET}"
  log "  - Provider binary install + provider.json registration: TODO (separate step)"
  log "  - More engines (llama/vllm/whisper/tts/yolo): pending verification, one at a time"
  log ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

STEPS_TOTAL=6

main() {
  require_root "$@"

  # Logging setup (write to file as well as stdout)
  mkdir -p "$(dirname "${LOG_FILE}")"
  # Rotate: drop install logs older than 30 days. Idempotent, runs at
  # every install. Keeps recent runs for postmortem without unbounded growth.
  find "$(dirname "${LOG_FILE}")" -maxdepth 1 -name 'install-*.log' -mtime +30 -delete 2>/dev/null || true
  touch "${LOG_FILE}"

  require_ubuntu
  setup_dirs
  detect_state
  confirm

  # All subsequent steps hit the network (apt, Docker registry, NVIDIA
  # repo). Wait for connectivity to avoid mysterious DNS / TLS failures
  # right after boot or WSL first-boot.
  wait_for_network

  step 1 "Docker"
  install_docker

  step 2 "nvidia-container-toolkit"
  install_nvidia_container_toolkit

  step 3 "GPU container access"
  if [ "${HAS_NVIDIA_DRIVER}" -eq 0 ] || [ "${DRIVER_OK}" -eq 0 ]; then
    warn "no usable NVIDIA driver -skipping GPU verification"
    warn "  install a driver, reboot, then re-run this script to verify"
  elif [ "${GPU_FROM_CONTAINER}" -ne 1 ]; then
    verify_gpu_container
  else
    ok "GPU container access verified earlier -skip"
  fi

  step 4 "Engine images (pull missing only - never auto-upgrade)"
  pull_engine_images

  step 5 "systemd units (written but DISABLED - operator starts manually)"
  install_systemd_units

  step 6 "Summary"
  print_summary
}

main "$@"
