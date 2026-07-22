# NBDE Demo Lab (KVM + RHEL)

Local KVM lab for **Network-Bound Disk Encryption** (Clevis + Tang): two small RHEL VMs, dedicated libvirt networks when possible, and a “stolen device” unlock demo.

## Topology

| Piece | Role |
|-------|------|
| `nbde-tang` | Tang server (1 vCPU / 1G / 10G) |
| `nbde-client` | Clevis client + LUKS data disk (2 vCPU / 2G / 15G + 2G) |
| `nbde-trusted` | NAT network `192.168.210.0/24` — normal operation |
| `nbde-isolated` | **No forward** `192.168.211.0/24` — stolen client |

If this host cannot create libvirt bridges (common with `qemu:///session`), the lab falls back to a **shared network** + **firewall isolation** for the stolen demo. Same story, fewer moving parts.

```
  Trusted path                         Stolen path
  ────────────                         ───────────
  client ──► Tang ──► Clevis unlock    client ✗ Tang ──► Clevis fails
                                       passphrase still works (break-glass)
```

The demo encrypts a **second disk** (`vdb`), not the root filesystem, so the guest still boots and you can SSH in to show success/failure live.

## Host prep

```bash
# One-time (needs sudo) — adds you to libvirt and starts default/NAT networking
sudo ./scripts/host-enable-libvirt.sh "$USER"
# log out/in so the libvirt group applies

cp config.env.example config.env
# Set RHEL_BASE_IMAGE to your RHEL 9+ KVM/cloud qcow2
# Optional: RHSM_ORG + RHSM_ACTIVATION_KEY for dnf inside fresh guests
```

Download the image from [Image Builder](https://console.redhat.com/insights/image-builder) or [access.redhat.com](https://access.redhat.com).

## Quick start

Step-by-step operator guide (prep, build, talk track, troubleshooting): **[RUNNING.md](RUNNING.md)**.  
Blog-style overview (edge security, NBDE, this lab): **[BLOG-edge-security-nbde.md](BLOG-edge-security-nbde.md)**.

```bash
chmod +x scripts/*.sh
./scripts/00-check-prereqs.sh
./scripts/00-create-networks.sh
./scripts/01-create-tang-vm.sh
./scripts/02-create-client-vm.sh
./scripts/03-setup-tang.sh
./scripts/04-setup-client-nbde.sh

./scripts/demo-happy-path.sh   # Clevis unlock OK
./scripts/demo-stolen.sh       # Tang unreachable → Clevis fails
./scripts/demo-restore.sh      # back to happy path
./scripts/status.sh
```

Guest login: `redhat` / `redhat`.

## Isolation modes (`ISOLATION_MODE` in config.env)

| Mode | Behavior |
|------|----------|
| `auto` (default) | Use NIC move to `nbde-isolated` if dual nets exist; else firewall-block Tang |
| `network` | Always move client to isolated network |
| `firewall` | Always block Tang IP on the client (works on one shared network) |

## Cleanup

```bash
./scripts/destroy.sh         # undefine VMs
./scripts/destroy.sh --all   # also disks + NBDE networks
```

## Notes

- Tang speaks HTTP by design (McCallum-Relyea); keep it on a private lab network only.
- Root-disk NBDE uses the same Clevis/Tang bind with extra initramfs work (`clevis-dracut`, `rd.neednet=1`).
- Optional next step: Clevis SSS with Tang + TPM2 (`swtpm` is available on this host).
