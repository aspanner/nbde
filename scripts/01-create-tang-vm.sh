#!/usr/bin/env bash
# Create the Tang (NBDE server) VM on the trusted network.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd virsh
need_cmd qemu-img
need_cmd virt-install
need_cmd genisoimage
require_ssh_key
require_image
mkdir_image_dir

VM_DISK="${IMAGE_DIR}/${TANG_VM_NAME}.qcow2"
SEED_ISO="${IMAGE_DIR}/${TANG_VM_NAME}-seed.iso"
USER_DATA="${ROOT_DIR}/cloud-init/tang-user-data"
META_DATA="${ROOT_DIR}/cloud-init/tang-meta-data"

if vm_exists "${TANG_VM_NAME}"; then
  log "VM ${TANG_VM_NAME} already exists. Start with: virsh start ${TANG_VM_NAME}"
  exit 0
fi

if [[ ! -f "${VM_DISK}" ]]; then
  log "Creating ${TANG_VM_NAME} disk (${TANG_DISK_GB}G) from base image"
  qemu-img create -f qcow2 -b "${RHEL_BASE_IMAGE}" -F qcow2 "${VM_DISK}" "${TANG_DISK_GB}G"
fi

cat > "${META_DATA}" <<EOF
instance-id: ${TANG_VM_NAME}
local-hostname: ${TANG_VM_NAME}
EOF

cat > "${USER_DATA}" <<EOF
#cloud-config
hostname: ${TANG_VM_NAME}
fqdn: ${TANG_VM_NAME}.nbde.local
manage_etc_hosts: true
users:
  - default
  - name: ${SSH_USER}
    gecos: NBDE Tang Admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    ssh_authorized_keys:
      - $(ssh_pubkey_line)
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: ${SSH_USER}
      password: ${SSH_PASS}
      type: text
$(rhsm_cloud_config)
package_update: true
packages:
  - tang
  - jose
runcmd:
  - systemctl enable --now tangd.socket
EOF

log "Building cloud-init seed ISO"
build_seed_iso "${TANG_VM_NAME}" "${USER_DATA}" "${META_DATA}" "${SEED_ISO}"

# Detect os-variant
OS_VARIANT="rhel9-unknown"
if osinfo-query os 2>/dev/null | grep -q 'rhel9'; then
  OS_VARIANT="rhel9.0"
fi

ATTACH_NET="$(tang_attach_net)"
log "Creating VM ${TANG_VM_NAME} on network ${ATTACH_NET}"
virt-install \
  --connect "${LIBVIRT_DEFAULT_URI}" \
  --name "${TANG_VM_NAME}" \
  --memory "${TANG_RAM_MB}" \
  --vcpus "${TANG_VCPUS}" \
  --cpu host-passthrough \
  --disk path="${VM_DISK}",format=qcow2,bus=virtio \
  --disk path="${SEED_ISO}",device=cdrom \
  --os-variant "${OS_VARIANT}" \
  --network "network=${ATTACH_NET},model=virtio" \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole

IP="$(wait_for_ip "${TANG_VM_NAME}")"
echo
log "Tang VM ready. Next: ./scripts/03-setup-tang.sh"
log "SSH: ssh ${SSH_USER}@${IP}  (password: ${SSH_PASS})"
