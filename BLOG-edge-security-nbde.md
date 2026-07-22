# Edge security at rest: Network-Bound Disk Encryption in practice

*A walkthrough of why edge devices lose more than uptime when they leave the site—and how Clevis, Tang, and a small KVM lab make that story concrete.*

---

## The edge problem isn’t only “keep the boxes online”

Edge deployments stretch the trust boundary. Devices sit in retail stores, factories, clinics, vehicles, and cell sites. They often hold:

- Application data and local caches  
- Device identity and certificates  
- Operational history that an attacker would love offline  

Physical control is weaker than in a locked data center. A laptop can be stolen; so can a kiosk, gateway, or compact industrial PC. Full-disk or volume encryption is necessary—but **encryption alone doesn’t answer the operational question**:

> When this device is powered on *here*, can it unlock itself without a human typing a passphrase at 3 a.m.?  
> When it is powered on *somewhere else*, can an attacker with the hardware read the disks?

Those are two different requirements. Traditional passphrase unlock fails the first. Naive key escrow (a server that stores and returns the disk key) creates a juicy target and a complex trust story. Network-Bound Disk Encryption (NBDE) is aimed squarely at that gap.

---

## What NBDE actually does

On Red Hat Enterprise Linux, NBDE is built from two Latchset components (named after fastener hardware—clevis, pin, and tang form a shackle):

| Piece | Role |
|-------|------|
| **Clevis** | Client-side framework for automated decryption (“pins” plug in different unlock policies) |
| **Tang** | Stateless server that binds unlock capability to **network presence** |

With the Tang pin, provisioning works roughly like this:

1. The volume is formatted as **LUKS**.  
2. Clevis binds an extra LUKS keyslot to a Tang server (URL + key thumbprint).  
3. At unlock time, Clevis and Tang run a **McCallum-Relyea** exchange (related to Diffie–Hellman with blinding).  
4. The disk unlock key is **reconstructed on the client**. Tang never holds that key; an eavesdropper on the wire doesn’t learn it either.

So Tang can speak plain **HTTP by design**. That often surprises people. Transport TLS isn’t what protects the key material—the protocol does. What Tang *does* encode as policy is: **if you can complete the exchange with this server, you’re “on the trusted network.”** Put Tang only where that statement is true (private plant/OT/lab segment, not the public internet).

You still keep a passphrase (or other pins) as **break-glass**. NBDE removes the need to type it for routine boots when the device is where it belongs.

### Why this fits edge

- **Unattended unlock** on site (stores open, lines run, clinics boot).  
- **Degraded value of theft**: the box boots elsewhere, but Clevis can’t reach Tang → automated unlock fails.  
- **No key escrow database** of every device’s disk key on the server.  
- **Composable policy** later: Clevis SSS (Shamir) can require Tang *and* TPM2, or k-of-n Tang servers for HA.

Root-filesystem NBDE is the production story (`clevis-dracut`, `rd.neednet=1` in initramfs). The same bind also works for **data volumes**, which is perfect for demos: the OS still boots so you can SSH in and show lock/unlock live.

---

## A lab that tells the story

We built a small local lab—**nbde-demo**—so you can show the policy instead of only describing it.

### Topology

Two VMs on libvirt/KVM:

- **`nbde-tang`** — Tang server  
- **`nbde-client`** — Clevis client with a second virtio disk (`vdb`) formatted as LUKS and bound to Tang  

Two networks when the host allows it (**dual mode**):

- **`nbde-trusted`** (`192.168.210.0/24`) — normal operation; Tang and client together  
- **`nbde-isolated`** (`192.168.211.0/24`) — no forward path to Tang; “stolen device”  

```
  Trusted path                         Stolen path
  ────────────                         ───────────
  client ──► Tang ──► Clevis unlock    client ✗ Tang ──► Clevis fails
                                       passphrase still works (break-glass)
```

If dedicated bridges aren’t available, the lab falls back to a **shared network** and simulates theft by **firewall-dropping** traffic to Tang’s IP on the client. Same narrative, fewer moving parts. Prefer the **network move** when you can—it’s closer to “this device left the site.”

### How the demo proves encryption and access

The lab doesn’t wave at ciphertext dumps. It proves **LUKS state** and **unlock policy**:

1. **Setup** (`04-setup-client-nbde.sh`): `luksFormat` on `vdb`, `clevis luks bind` to Tang, unlock, put an XFS filesystem and a `README.txt` on `/dev/mapper/nbde-data`, then close as needed.  
2. **Happy path** (`demo-happy-path.sh`): close the mapper → prove Tang is reachable → `clevis luks unlock` **without a passphrase** → mount and read the README.  
3. **Stolen** (`demo-stolen.sh`): move the client to `nbde-isolated` (or block Tang) → prove Tang is unreachable → Clevis unlock **must fail** → passphrase `cryptsetup open` still works.  
4. **Restore** (`demo-restore.sh`): put the client back on trusted → Clevis works again.

From the client you can inspect the same facts by hand:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
sudo cryptsetup isLuks /dev/vdb
sudo clevis luks list -d /dev/vdb
sudo cryptsetup status nbde-data    # active = unlocked
```

On the host, which “site” the guest is on is visible as:

```bash
virsh domiflist nbde-client   # nbde-trusted vs nbde-isolated
```

### Implementation sketch

| Concern | Approach |
|---------|----------|
| Guest bootstrap | Cloud-init NoCloud seed ISO (user/SSH, packages) |
| Base image | RHEL (or Fedora) **cloud/KVM qcow2**—preinstalled + cloud-init, not an install ISO |
| Tang packages | `tang`, `jose`; advertise over HTTP; thumbprint saved for bind |
| Client packages | `clevis`, `clevis-luks`, `cryptsetup`, … |
| State between scripts | `/tmp/nbde-vm-images/{active-net,tang,client}.env` |
| Isolation | `ISOLATION_MODE=network` (NIC move) or `firewall` |
| Host access | User in `libvirt` group + `qemu:///system` (avoids Polkit storms) |

Talk track, from-scratch build, and troubleshooting live in the repo’s `RUNNING.md`.

---

## What to take back to a real edge design

1. **Encrypt volumes that matter**—root and/or data—with LUKS; bind Clevis to Tang on a network that truly means “home.”  
2. **Place Tang carefully.** Reachability *is* the policy. Don’t put Tang where a stolen device can still call home.  
3. **Keep break-glass** (passphrase, escrow process, or alternate pin). NBDE is automation, not the only recovery path.  
4. **Plan for HA and stronger policy** (multiple Tang servers, SSS with TPM2) when a single Tang or “network only” isn’t enough.  
5. **Demo before you decree.** A two-VM lab turns “network-bound” from a slide into a failed `clevis luks unlock` you can watch.

Edge security is rarely one control. NBDE doesn’t replace patching, identity, secure boot, or physical process—but it *does* shrink the blast radius of a device walking out the door, without chaining every reboot to a human with a passphrase.

---

## Try it

Repository: local **nbde-demo** lab (Clevis + Tang on KVM).

```bash
# After host prep + RHEL/Fedora cloud image in config.env
./scripts/00-check-prereqs.sh
# … build through 04-setup-client-nbde.sh …

./scripts/demo-happy-path.sh
./scripts/demo-stolen.sh
./scripts/demo-restore.sh
```

Further reading: Red Hat docs on **Network-Bound Disk Encryption** / policy-based decryption; Latchset projects **Clevis** and **Tang**; McCallum-Relyea exchange for why HTTP is enough for the key agreement itself.
