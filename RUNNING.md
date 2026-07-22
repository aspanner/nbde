# Running the NBDE demo

This lab shows **Network-Bound Disk Encryption**: a Clevis client unlocks a LUKS data disk only while it can reach a Tang server. Steal the client (move it off the trusted network) and Clevis fails; a passphrase still works as break-glass.

Guest SSH: `redhat` / `redhat`

---

## Path A — Build from scratch

Use this when the lab does not exist yet, or you want a clean rebuild.

### A1. Host packages

On Fedora/RHEL host:

```bash
sudo dnf install -y libvirt virt-install qemu-kvm genisoimage jose curl openssh-clients
# optional: sshpass (password SSH fallback during first boot)
```

Ensure KVM works: `ls -l /dev/kvm`

### A2. One-time libvirt access

You must be in the `libvirt` group and use **system** libvirt (`qemu:///system`). Without that, every `virsh` call hits Polkit password prompts and can wedge `virtqemud`.

```bash
cd ~/git/nbde-demo
sudo ./scripts/host-enable-libvirt.sh "$USER"
```

**Log out and back in** (or reboot), then confirm:

```bash
id | grep libvirt
export LIBVIRT_DEFAULT_URI=qemu:///system
virsh list --all
```

If you cannot re-login yet:

```bash
sg libvirt -c 'bash'
export LIBVIRT_DEFAULT_URI=qemu:///system
```

### A3. Clean any leftover lab (optional but recommended for a true from-scratch)

```bash
cd ~/git/nbde-demo
./scripts/destroy.sh --all
```

That removes the NBDE VMs, their disks under `/tmp/nbde-vm-images`, and the `nbde-*` networks.

### A4. Config and cloud image

```bash
cd ~/git/nbde-demo
cp -n config.env.example config.env
```

Get a **RHEL 9+ KVM/cloud qcow2** (preferred) from:

- [Image Builder](https://console.redhat.com/insights/image-builder)
- [access.redhat.com](https://access.redhat.com) → Downloads → RHEL → Cloud Images

Or use a **Fedora Cloud** qcow2 (Clevis/Tang work the same; no RHSM).

Place it where the scripts expect it (qemu must be able to read it):

```bash
mkdir -p /tmp/nbde-vm-images
cp /path/to/your-cloud.qcow2 /tmp/nbde-vm-images/rhel-base.qcow2
chmod a+r /tmp/nbde-vm-images/rhel-base.qcow2
```

Or set an absolute path in `config.env`:

```bash
export RHEL_BASE_IMAGE=/path/to/your-cloud.qcow2
```

Also in `config.env`:

- `SSH_PUBKEY` — defaults to `~/.ssh/id_rsa.pub` (must exist)
- For **fresh RHEL** images: set `RHSM_ORG` and `RHSM_ACTIVATION_KEY` so guests can `dnf install`
- Isolation (recommended — NIC move for stolen demo):

```bash
export ISOLATION_MODE=network
```

(`auto` already prefers network move when dual nets exist.)

### A5. Build the lab

Run in order from the repo root. Do not skip steps.

```bash
cd ~/git/nbde-demo
chmod +x scripts/*.sh
export LIBVIRT_DEFAULT_URI=qemu:///system

./scripts/00-check-prereqs.sh
# Must report OK for virsh, image, SSH key, /dev/kvm

./scripts/00-create-networks.sh
# Prefer: DEMO_NET_MODE=dual (nbde-trusted + nbde-isolated)
# Fallback: shared default network + firewall isolation later

./scripts/01-create-tang-vm.sh
# Boots nbde-tang, cloud-init installs tang/jose

./scripts/02-create-client-vm.sh
# Boots nbde-client with second disk (vdb) for LUKS

./scripts/03-setup-tang.sh
# Enables tangd, fetches advertisement, writes /tmp/nbde-vm-images/tang.env

./scripts/04-setup-client-nbde.sh
# Formats vdb as LUKS2, binds Clevis→Tang, unlocks and mounts /mnt/nbde-data
```

First boot can take several minutes (cloud-init + package install).

Verify:

```bash
./scripts/status.sh
```

Expect both VMs **running** on `nbde-trusted`, and files:

- `/tmp/nbde-vm-images/tang.env`
- `/tmp/nbde-vm-images/client.env`
- `/tmp/nbde-vm-images/active-net.env`

Then continue to **[Run the demo](#run-the-demo-the-talk-track)** below.

---

## Path B — Lab already built

If `virsh list --all` already shows `nbde-tang` and `nbde-client`:

```bash
cd ~/git/nbde-demo
export LIBVIRT_DEFAULT_URI=qemu:///system
# ensure libvirt group: id | grep libvirt

./scripts/status.sh
# If client is stuck on nbde-isolated from a prior run:
./scripts/demo-restore.sh

./scripts/demo-happy-path.sh
./scripts/demo-stolen.sh
./scripts/demo-restore.sh
```

---

## Run the demo (the talk track)

Run these in order after the lab is built and healthy.

### Happy path — Tang reachable → unlock works

```bash
./scripts/demo-happy-path.sh
```

Expect:

- Tang reachable from the client
- `clevis luks unlock` succeeds **without** a passphrase
- Volume mounted at `/mnt/nbde-data`

### Stolen device — leave trusted network → Clevis fails

```bash
./scripts/demo-stolen.sh
```

With dual networks this **shuts down the client, moves its NIC to `nbde-isolated`, and boots it there** (no path to Tang).

Expect:

- Tang unreachable
- Clevis unlock fails (~15s)
- Passphrase unlock still works (recovery)

### Restore — back on trusted network

```bash
./scripts/demo-restore.sh
```

Expect:

- Client back on `nbde-trusted`
- Clevis unlock via Tang works again

---

## Optional: SSH in and show it live

IPs change after DHCP:

```bash
./scripts/status.sh
cat /tmp/nbde-vm-images/nbde-tang.ip
cat /tmp/nbde-vm-images/nbde-client.ip
```

```bash
ssh redhat@$(cat /tmp/nbde-vm-images/nbde-tang.ip)     # Tang
ssh redhat@$(cat /tmp/nbde-vm-images/nbde-client.ip)   # Client
```

On the client (happy path):

```bash
curl -fsS http://$(grep TANG_IP /tmp/nbde-vm-images/tang.env | cut -d= -f2)/adv | head -c 80
sudo clevis luks list -d "$(sudo cat /etc/nbde-demo-disk)"
findmnt /mnt/nbde-data
```

---

## Cleanup

```bash
./scripts/destroy.sh         # undefine VMs (disks kept)
./scripts/destroy.sh --all   # VMs + disks + nbde-* networks  ← use for full from-scratch rebuild
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `virsh` hangs / Polkit password storms | Confirm `id \| grep libvirt`; re-login; `sudo systemctl restart virtqemud.socket virtqemud` |
| `RHEL cloud image not found` | Copy a qcow2 to `/tmp/nbde-vm-images/rhel-base.qcow2` or set `RHEL_BASE_IMAGE` |
| Guest `dnf` fails on RHEL | Set `RHSM_ORG` + `RHSM_ACTIVATION_KEY` in `config.env`, then `./scripts/destroy.sh --all` and rebuild |
| Create scripts say VM already exists | `./scripts/destroy.sh --all` then rebuild, or `virsh start <name>` if you only need to boot |
| Dual nets failed at create time | Lab falls back to shared net + firewall isolation; fix libvirt group / `qemu:///system` and re-run `00-create-networks.sh` |
| Client left on `nbde-isolated` | `./scripts/demo-restore.sh` |
| Want a true clean slate | `./scripts/destroy.sh --all` then follow Path A from A4 |

Quick health check:

```bash
sudo systemctl restart virtqemud.socket virtqemud   # only if virsh is wedged
./scripts/status.sh
./scripts/demo-restore.sh                           # if mid-stolen leftover
```
