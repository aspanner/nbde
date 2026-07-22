#!/usr/bin/env bash
# Define and start trusted + isolated networks, or record a fallback shared network.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd virsh
mkdir_image_dir

ACTIVE_NET_FILE="${IMAGE_DIR}/active-net.env"

try_ensure_net() {
  local name="$1" xml="$2"
  if ! virsh net-info "${name}" &>/dev/null; then
    log "Defining network ${name}"
    virsh net-define "${xml}" || return 1
  fi
  virsh net-autostart "${name}" >/dev/null 2>&1 || true
  local active
  active="$(virsh net-info "${name}" 2>/dev/null | awk '/Active:/ {print $2}')"
  if [[ "${active}" != "yes" ]]; then
    log "Starting network ${name}"
    virsh net-start "${name}" || return 1
  else
    log "Network ${name} already active"
  fi
  return 0
}

DUAL_OK=false
if try_ensure_net "${NET_TRUSTED}" "${ROOT_DIR}/networks/nbde-trusted.xml" \
   && try_ensure_net "${NET_ISOLATED}" "${ROOT_DIR}/networks/nbde-isolated.xml"; then
  DUAL_OK=true
  cat > "${ACTIVE_NET_FILE}" <<EOF
DEMO_NET_MODE=dual
CLIENT_NET=${NET_TRUSTED}
TANG_NET=${NET_TRUSTED}
ISOLATED_NET=${NET_ISOLATED}
EOF
  log "Dual-network mode ready"
else
  warn "Could not start dedicated NBDE networks (bridge create often needs qemu:///system + libvirt group)"
  # Ensure fallback exists / is active
  if virsh net-info "${NET_FALLBACK}" &>/dev/null; then
    active="$(virsh net-info "${NET_FALLBACK}" | awk '/Active:/ {print $2}')"
    if [[ "${active}" != "yes" ]]; then
      log "Starting fallback network ${NET_FALLBACK}"
      if ! virsh net-start "${NET_FALLBACK}"; then
        die "Fallback network ${NET_FALLBACK} will not start.
If error mentions virbr0 already in use, system libvirt owns it — use:
  export LIBVIRT_DEFAULT_URI=qemu:///system
and ensure your user is in the libvirt group."
      fi
    fi
  else
    die "Fallback network ${NET_FALLBACK} is not defined / will not start.

This host likely needs system libvirt access:
  sudo ./scripts/host-enable-libvirt.sh $(id -un)
  # then log out/in
  export LIBVIRT_DEFAULT_URI=qemu:///system
  ./scripts/00-create-networks.sh"
  fi
  cat > "${ACTIVE_NET_FILE}" <<EOF
DEMO_NET_MODE=shared
CLIENT_NET=${NET_FALLBACK}
TANG_NET=${NET_FALLBACK}
ISOLATED_NET=
EOF
  log "Shared-network mode: both VMs on ${NET_FALLBACK}; stolen demo uses firewall isolation"
fi

echo
virsh net-list --all || true
echo
cat "${ACTIVE_NET_FILE}"
echo
log "Wrote ${ACTIVE_NET_FILE}"
