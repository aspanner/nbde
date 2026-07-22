#!/usr/bin/env bash
# Format the client's second disk as LUKS and bind it to Tang with Clevis.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd virsh
need_cmd ssh

[[ -f "${IMAGE_DIR}/tang.env" ]] || die "Missing ${IMAGE_DIR}/tang.env — run 03-setup-tang.sh first"
# shellcheck disable=SC1091
source "${IMAGE_DIR}/tang.env"

vm_exists "${CLIENT_VM_NAME}" || die "Client VM ${CLIENT_VM_NAME} does not exist. Run 02-create-client-vm.sh first."

if [[ "$(virsh domstate "${CLIENT_VM_NAME}")" != "running" ]]; then
  log "Starting ${CLIENT_VM_NAME}"
  virsh start "${CLIENT_VM_NAME}"
fi

IP="$(wait_for_ip "${CLIENT_VM_NAME}")"
wait_for_ssh "${IP}"

# Remote setup script executed on the client
REMOTE_SCRIPT="$(mktemp)"
cat > "${REMOTE_SCRIPT}" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

TANG_URL="$1"
TANG_THP="$2"
LUKS_PASSPHRASE="$3"
MAPPER_NAME="$4"

# Prefer the second virtio disk (vdb). Fall back to largest non-root disk.
DISK=""
for cand in /dev/vdb /dev/sdb /dev/vdc; do
  if [[ -b "${cand}" ]]; then
    DISK="${cand}"
    break
  fi
done
[[ -n "${DISK}" ]] || { echo "No secondary disk found"; lsblk; exit 1; }

echo "==> Using data disk ${DISK}"
sudo dnf install -y clevis clevis-luks clevis-systemd cryptsetup jose

# Skip if already LUKS
if sudo cryptsetup isLuks "${DISK}" 2>/dev/null; then
  echo "==> ${DISK} already LUKS — skipping format"
else
  echo "==> Formatting ${DISK} as LUKS2"
  printf '%s' "${LUKS_PASSPHRASE}" | sudo cryptsetup luksFormat --type luks2 --batch-mode "${DISK}" -
fi

# Bind Clevis if not already bound
if sudo clevis luks list -d "${DISK}" 2>/dev/null | grep -q tang; then
  echo "==> Clevis Tang binding already present"
else
  echo "==> Binding ${DISK} to Tang ${TANG_URL} (thp=${TANG_THP})"
  printf '%s' "${LUKS_PASSPHRASE}" | sudo clevis luks bind -y -k - -d "${DISK}" \
    tang "{\"url\":\"${TANG_URL}\",\"thp\":\"${TANG_THP}\"}"
fi

echo "==> LUKS dump"
sudo cryptsetup luksDump "${DISK}" | sed -n '1,40p'
echo
echo "==> Clevis slots"
sudo clevis luks list -d "${DISK}" || true

# Create a marker filesystem when unlocked (idempotent)
if ! sudo cryptsetup status "${MAPPER_NAME}" &>/dev/null; then
  echo "==> Unlocking with Clevis to create demo filesystem"
  sudo clevis luks unlock -d "${DISK}" -n "${MAPPER_NAME}"
fi
if ! sudo findmnt "/mnt/${MAPPER_NAME}" &>/dev/null; then
  if ! sudo blkid -o value -s TYPE "/dev/mapper/${MAPPER_NAME}" | grep -q .; then
    sudo mkfs.xfs -f "/dev/mapper/${MAPPER_NAME}"
  fi
  sudo mkdir -p "/mnt/${MAPPER_NAME}"
  sudo mount "/dev/mapper/${MAPPER_NAME}" "/mnt/${MAPPER_NAME}"
fi
echo "NBDE demo volume — unlocked via Tang $(date -Is)" | sudo tee "/mnt/${MAPPER_NAME}/README.txt" >/dev/null
sync
echo "${DISK}" | sudo tee /etc/nbde-demo-disk >/dev/null
echo "==> Done. Disk ${DISK} bound to ${TANG_URL}"
REMOTE

log "Configuring Clevis + LUKS on ${CLIENT_VM_NAME} (${IP})"
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${REMOTE_SCRIPT}" "${SSH_USER}@${IP}:/tmp/setup-nbde.sh"
rm -f "${REMOTE_SCRIPT}"

ssh_guest "${IP}" "chmod +x /tmp/setup-nbde.sh && sudo /tmp/setup-nbde.sh '${TANG_URL}' '${TANG_THP}' '${LUKS_PASSPHRASE}' '${LUKS_MAPPER_NAME}'"

cat > "${IMAGE_DIR}/client.env" <<EOF
CLIENT_IP=${IP}
TANG_URL=${TANG_URL}
TANG_THP=${TANG_THP}
LUKS_MAPPER_NAME=${LUKS_MAPPER_NAME}
EOF

echo
log "Client NBDE binding complete."
log "Happy path:  ./scripts/demo-happy-path.sh"
log "Stolen path: ./scripts/demo-stolen.sh"
