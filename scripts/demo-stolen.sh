#!/usr/bin/env bash
# Demo: simulate a stolen client that cannot reach Tang.
# Isolation modes: network | firewall | auto (see config.env).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd virsh
vm_exists "${CLIENT_VM_NAME}" || die "Run setup scripts first"
[[ -f "${IMAGE_DIR}/tang.env" ]] || die "Run 03-setup-tang.sh first"
# shellcheck disable=SC1091
source "${IMAGE_DIR}/tang.env"
load_active_net

MODE="${ISOLATION_MODE}"
if [[ "${MODE}" == "auto" ]]; then
  if [[ "${DEMO_NET_MODE}" == "dual" && -n "${ISOLATED_NET:-}" ]]; then
    MODE="network"
  else
    MODE="firewall"
  fi
fi
log "=== STOLEN DEVICE DEMO (isolation=${MODE}) ==="

close_volume() {
  local ip="$1"
  ssh_guest "${ip}" bash -s <<EOF || true
set -euo pipefail
MAPPER="${LUKS_MAPPER_NAME}"
sudo umount /mnt/\${MAPPER} 2>/dev/null || true
sudo cryptsetup close \${MAPPER} 2>/dev/null || true
echo "Volume closed"
EOF
}

move_to_isolated_net() {
  log "Moving ${CLIENT_VM_NAME} to ${ISOLATED_NET}"
  if [[ "$(virsh domstate "${CLIENT_VM_NAME}")" == "running" ]]; then
    virsh shutdown "${CLIENT_VM_NAME}" || true
    for _ in $(seq 1 30); do
      [[ "$(virsh domstate "${CLIENT_VM_NAME}")" == "shut off" ]] && break
      sleep 2
    done
    [[ "$(virsh domstate "${CLIENT_VM_NAME}")" == "shut off" ]] || virsh destroy "${CLIENT_VM_NAME}"
  fi
  MAC="$(virsh domiflist "${CLIENT_VM_NAME}" | awk 'NR==3 {print $5}')"
  if [[ -n "${MAC}" && "${MAC}" != "-" ]]; then
    virsh detach-interface "${CLIENT_VM_NAME}" network --mac "${MAC}" --config || true
  fi
  virsh attach-interface "${CLIENT_VM_NAME}" network "${ISOLATED_NET}" --model virtio --config
  virsh start "${CLIENT_VM_NAME}"
}

apply_firewall_block() {
  local ip="$1"
  log "Blocking Tang ${TANG_IP} on client (simulates leaving trusted network)"
  ssh_guest "${ip}" bash -s <<EOF
set -euo pipefail
TANG_IP='${TANG_IP}'
if command -v nft >/dev/null 2>&1; then
  sudo nft delete table inet nbde_demo 2>/dev/null || true
  sudo nft add table inet nbde_demo
  sudo nft add chain inet nbde_demo output '{ type filter hook output priority 0 ; policy accept ; }'
  sudo nft add rule inet nbde_demo output ip daddr "\${TANG_IP}" drop
else
  sudo iptables -C OUTPUT -d "\${TANG_IP}" -j DROP 2>/dev/null || \
    sudo iptables -I OUTPUT -d "\${TANG_IP}" -j DROP
fi
echo "Tang blocked"
EOF
}

# --- prepare ---
IP="$(vm_ip "${CLIENT_VM_NAME}")"
if [[ -n "${IP}" ]]; then
  wait_for_ssh "${IP}" || true
  close_volume "${IP}"
fi

if [[ "${MODE}" == "network" ]]; then
  [[ -n "${ISOLATED_NET:-}" ]] || die "ISOLATED_NET not set; dual networks required for MODE=network"
  move_to_isolated_net
  IP="$(wait_for_ip "${CLIENT_VM_NAME}" 40)"
  wait_for_ssh "${IP}"
else
  if [[ "$(virsh domstate "${CLIENT_VM_NAME}")" != "running" ]]; then
    virsh start "${CLIENT_VM_NAME}"
  fi
  IP="$(wait_for_ip "${CLIENT_VM_NAME}")"
  wait_for_ssh "${IP}"
  apply_firewall_block "${IP}"
fi

echo "${MODE}" > "${IMAGE_DIR}/isolation.mode"

log "Prove Tang is NOT reachable"
ssh_guest "${IP}" bash -s <<EOF
set -euo pipefail
if curl -fsS --connect-timeout 3 '${TANG_URL}/adv' >/dev/null 2>&1; then
  echo "ERROR: Tang unexpectedly reachable — isolation failed"
  exit 1
fi
echo "Tang unreachable (expected)"
EOF

log "Clevis unlock must fail (timeout ~15s)"
set +e
ssh_guest "${IP}" bash -s <<EOF
set -euo pipefail
DISK="\$(sudo cat /etc/nbde-demo-disk)"
MAPPER="${LUKS_MAPPER_NAME}"
timeout 15 sudo clevis luks unlock -d "\${DISK}" -n "\${MAPPER}" && exit 0
echo "--- EXPECTED FAILURE: Clevis could not unlock without Tang ---"
exit 1
EOF
CLEVIS_RC=$?
set -e

if [[ "${CLEVIS_RC}" -eq 0 ]]; then
  die "Clevis unlock succeeded while Tang unreachable — demo failed"
fi

log "Break-glass: passphrase still unlocks the same disk"
ssh_guest "${IP}" bash -s <<EOF
set -euo pipefail
DISK="\$(sudo cat /etc/nbde-demo-disk)"
MAPPER="${LUKS_MAPPER_NAME}"
printf '%s' '${LUKS_PASSPHRASE}' | sudo cryptsetup open "\${DISK}" "\${MAPPER}" -
sudo mkdir -p /mnt/\${MAPPER}
sudo mount /dev/mapper/\${MAPPER} /mnt/\${MAPPER}
echo "--- Passphrase unlock OK (recovery path) ---"
cat /mnt/\${MAPPER}/README.txt
sudo umount /mnt/\${MAPPER}
sudo cryptsetup close \${MAPPER}
EOF

echo
log "Stolen demo OK:"
log "  • Tang unreachable → Clevis unlock fails"
log "  • Passphrase still works as recovery"
log "Restore with: ./scripts/demo-restore.sh"
