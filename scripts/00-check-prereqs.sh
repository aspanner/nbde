#!/usr/bin/env bash
# Validate host prerequisites before building the lab.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ok=0
bad=0
check() {
  local label="$1"; shift
  if "$@"; then
    printf '  [OK]   %s\n' "${label}"
    ok=$((ok + 1))
  else
    printf '  [FAIL] %s\n' "${label}"
    bad=$((bad + 1))
  fi
}

echo "NBDE demo prerequisites"
echo "URI=${LIBVIRT_DEFAULT_URI}"
echo

need_cmd() { command -v "$1" >/dev/null 2>&1; }

check "virsh" need_cmd virsh
check "qemu-img" need_cmd qemu-img
check "virt-install" need_cmd virt-install
check "genisoimage" need_cmd genisoimage
check "jose (host, for Tang thumbprint)" need_cmd jose
check "curl" need_cmd curl
check "ssh" need_cmd ssh
check "SSH public key ${SSH_PUBKEY}" test -f "${SSH_PUBKEY}"
check "/dev/kvm present" test -e /dev/kvm

echo
log "Libvirt connectivity (${LIBVIRT_DEFAULT_URI})"
if timeout 8 virsh list --all &>/dev/null; then
  printf '  [OK]   virsh list works\n'
  ok=$((ok + 1))
else
  printf '  [FAIL] virsh list timed out or failed\n'
  printf '         Fix: sudo usermod -aG libvirt %s  # then re-login\n' "$(id -un)"
  printf '         Or:  export LIBVIRT_DEFAULT_URI=qemu:///session\n'
  printf '         And: ISOLATION_MODE=firewall with an existing network\n'
  bad=$((bad + 1))
fi

echo
log "RHEL base image"
if [[ -f "${RHEL_BASE_IMAGE}" ]]; then
  printf '  [OK]   %s\n' "${RHEL_BASE_IMAGE}"
  ok=$((ok + 1))
else
  printf '  [FAIL] missing %s\n' "${RHEL_BASE_IMAGE}"
  printf '         Download RHEL 9+ KVM/cloud qcow2 and set RHEL_BASE_IMAGE in config.env\n'
  bad=$((bad + 1))
fi

echo
log "RHSM (optional but needed for dnf on fresh RHEL cloud images)"
if [[ -n "${RHSM_ORG:-}" && -n "${RHSM_ACTIVATION_KEY:-}" ]]; then
  printf '  [OK]   RHSM_ORG + RHSM_ACTIVATION_KEY set\n'
else
  printf '  [WARN] RHSM not set — guests need repos somehow (activation key or pre-registered image)\n'
fi

echo
log "Network create capability"
if timeout 8 virsh net-list --all &>/dev/null; then
  if virsh net-info "${NET_TRUSTED}" &>/dev/null || true; then
    :
  fi
  printf '  [OK]   virsh net-list works\n'
  ok=$((ok + 1))
  # Probe bridge create only if trusted net missing
  if ! virsh net-info "${NET_TRUSTED}" &>/dev/null; then
    printf '         Dedicated nets will be attempted by 00-create-networks.sh\n'
    printf '         If bridge create fails, lab falls back to NET_FALLBACK=%s + firewall isolation\n' "${NET_FALLBACK}"
  fi
else
  printf '  [FAIL] cannot list networks\n'
  bad=$((bad + 1))
fi

echo
echo "Summary: ${ok} ok, ${bad} failed"
[[ "${bad}" -eq 0 ]] || exit 1
