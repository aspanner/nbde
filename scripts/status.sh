#!/usr/bin/env bash
# Show current lab status.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "URI: ${LIBVIRT_DEFAULT_URI}"
echo "IMAGE_DIR: ${IMAGE_DIR}"
echo "RHEL_BASE_IMAGE: ${RHEL_BASE_IMAGE} ($([ -f "${RHEL_BASE_IMAGE}" ] && echo present || echo MISSING))"
echo
echo "=== Networks ==="
virsh net-list --all || true
echo
echo "=== Domains ==="
virsh list --all || true
echo
for name in "${TANG_VM_NAME}" "${CLIENT_VM_NAME}"; do
  if vm_exists "${name}"; then
    state="$(virsh domstate "${name}")"
    ip="$(vm_ip "${name}")"
    net="$(virsh domiflist "${name}" 2>/dev/null | awk 'NR==3 {print $3}')"
    echo "${name}: state=${state} ip=${ip:-?} net=${net:-?}"
  else
    echo "${name}: not defined"
  fi
done
echo
if [[ -f "${IMAGE_DIR}/active-net.env" ]]; then
  echo "=== Active network mode ==="
  cat "${IMAGE_DIR}/active-net.env"
  echo
fi
if [[ -f "${IMAGE_DIR}/tang.env" ]]; then
  echo "=== Tang ==="
  cat "${IMAGE_DIR}/tang.env"
fi
