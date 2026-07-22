#!/usr/bin/env bash
# Tear down VMs (and optionally networks / disks).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

DESTROY_NETS=false
DESTROY_DISKS=false
for arg in "$@"; do
  case "${arg}" in
    --nets)  DESTROY_NETS=true ;;
    --disks) DESTROY_DISKS=true ;;
    --all)   DESTROY_NETS=true; DESTROY_DISKS=true ;;
    -h|--help)
      echo "Usage: $0 [--nets] [--disks] [--all]"
      exit 0
      ;;
  esac
done

destroy_vm() {
  local name="$1"
  if vm_exists "${name}"; then
    log "Destroying VM ${name}"
    virsh destroy "${name}" 2>/dev/null || true
    virsh undefine "${name}" --nvram 2>/dev/null || virsh undefine "${name}" 2>/dev/null || true
  fi
}

destroy_vm "${CLIENT_VM_NAME}"
destroy_vm "${TANG_VM_NAME}"

if [[ "${DESTROY_DISKS}" == true ]]; then
  log "Removing disks under ${IMAGE_DIR}"
  rm -f "${IMAGE_DIR}/${TANG_VM_NAME}.qcow2" \
        "${IMAGE_DIR}/${TANG_VM_NAME}-seed.iso" \
        "${IMAGE_DIR}/${TANG_VM_NAME}.ip" \
        "${IMAGE_DIR}/${CLIENT_VM_NAME}.qcow2" \
        "${IMAGE_DIR}/${CLIENT_VM_NAME}-data.qcow2" \
        "${IMAGE_DIR}/${CLIENT_VM_NAME}-seed.iso" \
        "${IMAGE_DIR}/${CLIENT_VM_NAME}.ip" \
        "${IMAGE_DIR}/tang.env" \
        "${IMAGE_DIR}/client.env" \
        "${IMAGE_DIR}/active-net.env" \
        "${IMAGE_DIR}/isolation.mode"
fi

if [[ "${DESTROY_NETS}" == true ]]; then
  for net in "${NET_TRUSTED}" "${NET_ISOLATED}"; do
    if virsh net-info "${net}" &>/dev/null; then
      log "Removing network ${net}"
      virsh net-destroy "${net}" 2>/dev/null || true
      virsh net-undefine "${net}" 2>/dev/null || true
    fi
  done
fi

log "Done. status: ./scripts/status.sh"
