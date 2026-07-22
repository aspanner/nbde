#!/usr/bin/env bash
# Run with sudo once on the host to enable system libvirt for this user.
# Usage: sudo ./scripts/host-enable-libvirt.sh [username]
set -euo pipefail

USER_NAME="${1:-${SUDO_USER:-}}"
[[ -n "${USER_NAME}" ]] || { echo "Usage: sudo $0 <username>"; exit 1; }

echo "==> Enabling modular libvirt sockets/services"
systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtlogd.socket 2>/dev/null || true
systemctl start virtqemud virtnetworkd virtstoraged virtlogd 2>/dev/null || true
# Legacy fallback
systemctl enable --now libvirtd 2>/dev/null || true

echo "==> Adding ${USER_NAME} to libvirt group"
usermod -aG libvirt "${USER_NAME}"

echo "==> Ensuring default network is active (virbr0)"
virsh -c qemu:///system net-autostart default 2>/dev/null || true
virsh -c qemu:///system net-start default 2>/dev/null || true

echo
echo "Done. ${USER_NAME} must log out/in (or reboot) for the libvirt group to apply."
echo "Then:"
echo "  export LIBVIRT_DEFAULT_URI=qemu:///system"
echo "  cd /home/${USER_NAME}/git/nbde-demo"
echo "  ./scripts/00-check-prereqs.sh"
echo "  ./scripts/00-create-networks.sh"
