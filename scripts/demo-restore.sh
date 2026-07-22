#!/usr/bin/env bash
# Undo stolen-demo isolation and show Clevis unlock works again.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd virsh
vm_exists "${CLIENT_VM_NAME}" || die "Client VM missing"
[[ -f "${IMAGE_DIR}/tang.env" ]] || die "Run 03-setup-tang.sh first"
# shellcheck disable=SC1091
source "${IMAGE_DIR}/tang.env"
load_active_net

MODE="${ISOLATION_MODE}"
if [[ -f "${IMAGE_DIR}/isolation.mode" ]]; then
  MODE="$(cat "${IMAGE_DIR}/isolation.mode")"
elif [[ "${MODE}" == "auto" ]]; then
  if [[ "${DEMO_NET_MODE}" == "dual" ]]; then MODE="network"; else MODE="firewall"; fi
fi

log "Restoring from isolation mode: ${MODE}"

if [[ "${MODE}" == "network" ]]; then
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
  virsh attach-interface "${CLIENT_VM_NAME}" network "${CLIENT_NET}" --model virtio --config
  virsh start "${CLIENT_VM_NAME}"
fi

if [[ "$(virsh domstate "${CLIENT_VM_NAME}")" != "running" ]]; then
  virsh start "${CLIENT_VM_NAME}"
fi

IP="$(wait_for_ip "${CLIENT_VM_NAME}")"
wait_for_ssh "${IP}"

if [[ "${MODE}" == "firewall" ]]; then
  log "Removing Tang block on client"
  ssh_guest "${IP}" "sudo iptables -D OUTPUT -d '${TANG_IP}' -j DROP 2>/dev/null || true; sudo nft delete table inet nbde_demo 2>/dev/null || true"
fi

log "Clevis unlock after restore"
ssh_guest "${IP}" bash -s <<EOF
set -euo pipefail
DISK="\$(sudo cat /etc/nbde-demo-disk)"
MAPPER="${LUKS_MAPPER_NAME}"
sudo umount /mnt/\${MAPPER} 2>/dev/null || true
sudo cryptsetup close \${MAPPER} 2>/dev/null || true
curl -fsS --connect-timeout 5 '${TANG_URL}/adv' >/dev/null
sudo clevis luks unlock -d "\${DISK}" -n "\${MAPPER}"
sudo mkdir -p /mnt/\${MAPPER}
sudo mount /dev/mapper/\${MAPPER} /mnt/\${MAPPER}
echo "--- RESTORED: unlocked via Tang again ---"
cat /mnt/\${MAPPER}/README.txt
EOF

rm -f "${IMAGE_DIR}/isolation.mode"
echo
log "Client can reach Tang again. Clevis unlock works."
