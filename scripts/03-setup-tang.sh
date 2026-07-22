#!/usr/bin/env bash
# Ensure Tang is running and advertise its URL / thumbprint for Clevis binding.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd virsh
need_cmd ssh
need_cmd curl

vm_exists "${TANG_VM_NAME}" || die "Tang VM ${TANG_VM_NAME} does not exist. Run 01-create-tang-vm.sh first."

if [[ "$(virsh domstate "${TANG_VM_NAME}")" != "running" ]]; then
  log "Starting ${TANG_VM_NAME}"
  virsh start "${TANG_VM_NAME}"
fi

IP="$(wait_for_ip "${TANG_VM_NAME}")"
wait_for_ssh "${IP}"

log "Ensuring tangd.socket is enabled"
ssh_guest "${IP}" 'sudo dnf install -y tang jose 2>/dev/null || true; sudo systemctl enable --now tangd.socket'

log "Waiting for Tang HTTP advertisement on ${IP}:80"
for _ in $(seq 1 30); do
  if curl -fsS "http://${IP}/adv" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

ADV="$(curl -fsS "http://${IP}/adv")" || die "Tang advertisement not available at http://${IP}/adv"
THP="$(printf '%s' "${ADV}" | jose fmt -j- -g payload -y -o- | jose jwk use -i- -r -u verify -o- | jose jwk thp -i-)"

mkdir -p "${IMAGE_DIR}"
cat > "${IMAGE_DIR}/tang.env" <<EOF
TANG_URL=http://${IP}
TANG_IP=${IP}
TANG_THP=${THP}
EOF

log "Tang ready"
log "  URL:        http://${IP}"
log "  Thumbprint: ${THP}"
log "  Saved:      ${IMAGE_DIR}/tang.env"
echo
printf '%s\n' "${ADV}" | jose fmt -j- -c 2>/dev/null || true
