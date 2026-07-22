#!/usr/bin/env bash
# Shared helpers for NBDE demo scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/config.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/config.env"
else
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/config.env.example"
fi

export LIBVIRT_DEFAULT_URI

# Logs go to stderr so $(wait_for_ip ...) only captures the IP on stdout.
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_image() {
  [[ -f "${RHEL_BASE_IMAGE}" ]] || die \
    "RHEL cloud image not found: ${RHEL_BASE_IMAGE}

Download a RHEL 9+ KVM/cloud qcow2 and set RHEL_BASE_IMAGE in config.env
  https://console.redhat.com/insights/image-builder
  https://access.redhat.com → Downloads → RHEL → Cloud Images

Or copy it into place:
  mkdir -p ${IMAGE_DIR}
  cp /path/to/rhel-*-kvm.qcow2 ${RHEL_BASE_IMAGE}"
}

require_ssh_key() {
  [[ -f "${SSH_PUBKEY}" ]] || die "SSH public key not found: ${SSH_PUBKEY}"
}

mkdir_image_dir() {
  mkdir -p "${IMAGE_DIR}"
}

vm_exists() {
  virsh dominfo "$1" &>/dev/null
}

vm_ip() {
  local name="$1" ip=""
  # Prefer DHCP lease / libvirt interface addr — agent lists lo (127.0.0.1) first.
  ip="$(virsh domifaddr "${name}" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1 || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(virsh domifaddr "${name}" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1 || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(virsh domifaddr "${name}" --source agent 2>/dev/null \
      | awk '/ipv4/ {print $4}' | cut -d/ -f1 | grep -vE '^127\.' | head -1 || true)"
  fi
  if [[ -z "${ip}" && -f "${IMAGE_DIR}/${name}.ip" ]]; then
    ip="$(cat "${IMAGE_DIR}/${name}.ip")"
  fi
  printf '%s' "${ip}"
}

wait_for_ip() {
  local name="$1" tries="${2:-60}" ip=""
  # Drop stale cache so a NIC move (trusted ↔ isolated) cannot return the old address.
  rm -f "${IMAGE_DIR}/${name}.ip"
  log "Waiting for DHCP lease on ${name}..."
  for _ in $(seq 1 "${tries}"); do
    # Live sources only — never the on-disk cache while polling.
    ip="$(virsh domifaddr "${name}" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1 || true)"
    if [[ -z "${ip}" ]]; then
      ip="$(virsh domifaddr "${name}" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1 || true)"
    fi
    if [[ -z "${ip}" ]]; then
      ip="$(virsh domifaddr "${name}" --source agent 2>/dev/null \
        | awk '/ipv4/ {print $4}' | cut -d/ -f1 | grep -vE '^127\.' | head -1 || true)"
    fi
    if [[ -n "${ip}" ]]; then
      echo "${ip}" > "${IMAGE_DIR}/${name}.ip"
      log "${name} IP: ${ip}"
      printf '%s' "${ip}"
      return 0
    fi
    sleep 5
  done
  die "No IP for ${name} after ${tries} attempts. Check: virsh domifaddr ${name}"
}

wait_for_ssh() {
  local ip="$1" tries="${2:-36}"
  log "Waiting for SSH on ${ip}..."
  for _ in $(seq 1 "${tries}"); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=5 -o BatchMode=yes \
         "${SSH_USER}@${ip}" true 2>/dev/null; then
      return 0
    fi
    # password auth fallback probe via sshpass if available
    if command -v sshpass >/dev/null 2>&1; then
      if sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
           "${SSH_USER}@${ip}" true 2>/dev/null; then
        return 0
      fi
    fi
    sleep 5
  done
  die "SSH not ready on ${ip}"
}

ssh_guest() {
  local ip="$1"; shift
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 "${SSH_USER}@${ip}" "$@"
}

scp_guest() {
  local ip="$1"; shift
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@" "${SSH_USER}@${ip}:"
}

build_seed_iso() {
  local name="$1" user_data="$2" meta_data="$3" seed_iso="$4"
  local work
  work="$(mktemp -d)"
  cp "${user_data}" "${work}/user-data"
  cp "${meta_data}" "${work}/meta-data"
  genisoimage -output "${seed_iso}" -volid cidata -joliet -rock \
    "${work}/user-data" "${work}/meta-data" >/dev/null
  rm -rf "${work}"
}

rhsm_cloud_config() {
  # Emits cloud-config rh_subscription stanza when activation key is set.
  if [[ -n "${RHSM_ORG:-}" && -n "${RHSM_ACTIVATION_KEY:-}" ]]; then
    cat <<EOF
rh_subscription:
  activation-key: ${RHSM_ACTIVATION_KEY}
  org: ${RHSM_ORG}
  auto-attach: true
EOF
  fi
}

ssh_pubkey_line() {
  cat "${SSH_PUBKEY}"
}

load_active_net() {
  local f="${IMAGE_DIR}/active-net.env"
  [[ -f "${f}" ]] || die "Missing ${f} — run ./scripts/00-create-networks.sh first"
  # shellcheck disable=SC1090
  source "${f}"
}

client_attach_net() {
  # Print the libvirt network name the client should use right now
  load_active_net
  printf '%s' "${CLIENT_NET}"
}

tang_attach_net() {
  load_active_net
  printf '%s' "${TANG_NET}"
}
