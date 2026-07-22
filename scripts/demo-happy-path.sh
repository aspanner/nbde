#!/usr/bin/env bash
# Demo: unlock LUKS data volume while Tang is reachable.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd virsh
vm_exists "${CLIENT_VM_NAME}" || die "Run setup scripts first"
[[ -f "${IMAGE_DIR}/tang.env" ]] || die "Run 03-setup-tang.sh first"
# shellcheck disable=SC1091
source "${IMAGE_DIR}/tang.env"
load_active_net

if [[ "$(virsh domstate "${CLIENT_VM_NAME}")" != "running" ]]; then
  virsh start "${CLIENT_VM_NAME}"
fi

IP="$(wait_for_ip "${CLIENT_VM_NAME}")"
wait_for_ssh "${IP}"

# Clear any leftover stolen-demo firewall rules
ssh_guest "${IP}" "sudo iptables -D OUTPUT -d '${TANG_IP}' -j DROP 2>/dev/null || true; sudo nft delete table inet nbde_demo 2>/dev/null || true" || true

log "Tang URL: ${TANG_URL}"
log "Proving Tang is reachable from client..."
ssh_guest "${IP}" "curl -fsS --connect-timeout 5 '${TANG_URL}/adv' >/dev/null && echo 'Tang reachable'"

log "Closing volume if open, then unlocking via Clevis (no passphrase)..."
ssh_guest "${IP}" bash -s <<EOF
set -euo pipefail
DISK="\$(sudo cat /etc/nbde-demo-disk)"
MAPPER="${LUKS_MAPPER_NAME}"
sudo umount /mnt/\${MAPPER} 2>/dev/null || true
sudo cryptsetup close \${MAPPER} 2>/dev/null || true
echo "Attempting Clevis unlock of \${DISK}..."
sudo clevis luks unlock -d "\${DISK}" -n "\${MAPPER}"
sudo mkdir -p /mnt/\${MAPPER}
sudo mount /dev/mapper/\${MAPPER} /mnt/\${MAPPER}
echo "--- SUCCESS: volume unlocked via Tang ---"
cat /mnt/\${MAPPER}/README.txt
df -h /mnt/\${MAPPER}
EOF

echo
log "Happy path OK: disk unlocked because Tang is reachable."
