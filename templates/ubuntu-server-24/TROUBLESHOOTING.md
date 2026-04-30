# Troubleshooting — Packer + Proxmox + Ubuntu 24.04

Issues encountered during initial build setup and their fixes.

---

## 1. Deprecated `iso_file` / `unmount_iso` parameters

**Symptom:** Packer warns these fields are deprecated.

**Fix:** Replace with a `boot_iso` block:
```hcl
boot_iso {
  iso_file = var.iso_file
  unmount  = true
}
```

---

## 2. Tag validation error — dot not allowed

**Symptom:**
```
Error creating VM: tag may not start with - and may only include the following characters: abcdefghijklmnopqrstuvwxyz...
```

**Cause:** `tags = "ubuntu;24.04"` — Proxmox tags don't allow `.`

**Fix:** Use `ubuntu-24` instead of `24.04`.

---

## 3. 403 Permission check failed on VM creation

**Symptom:**
```
Error creating VM: 403 Permission check failed
```

**Cause:** Proxmox API tokens have privilege separation enabled by default — even `root@pam` tokens don't inherit root permissions unless explicitly configured.

**Fix:** Datacenter → Permissions → API Tokens → select your token → uncheck **Privilege Separation**.

---

## 4. SSH timeout — Packer never connects

**Symptom:** Build runs for the full `ssh_timeout` then fails with `Timeout waiting for SSH`.

**Cause:** `ssh_timeout = "5m"` is too short. A full Ubuntu 24.04 autoinstall takes 10–15 minutes minimum.

**Fix:** Set `ssh_timeout = "30m"`.

---

## 5. QEMU guest agent error loop

**Symptom:** Log fills with:
```
[DEBUG] Error getting SSH address: 500 QEMU guest agent is not running
```

**Cause:** With `qemu_agent = true`, the Packer Proxmox plugin uses the QEMU guest agent to get the VM's IP address. If `qemu-guest-agent` isn't installed in the VM, Packer loops forever and never SSHes in.

**Fix:** Add `qemu-guest-agent` to the `packages` list in `user-data` AND enable it in `late-commands`:
```yaml
packages:
  - qemu-guest-agent
late-commands:
  - curtin in-target --target=/target -- systemctl enable qemu-guest-agent
  - curtin in-target --target=/target -- systemctl start qemu-guest-agent
```

---

## 6. VM boots via iPXE instead of Ubuntu ISO (boot loop)

**Symptom:** Proxmox console shows the VM trying to PXE boot over the network:
```
Nothing to boot: No such file or directory (http://ipxe.org/...)
No more network devices
```
VM loops or never reaches GRUB.

**Cause:** The Packer Proxmox plugin does **not** set the Proxmox VM boot order. Proxmox defaults to no explicit boot order, causing SeaBIOS to try: non-bootable devices → network (iPXE) → CD-ROM. If the seed ISO (`additional_iso_files`) is on a lower IDE slot (e.g. `ide0`) than the Ubuntu ISO (`ide2`), SeaBIOS tries the seed first (not bootable), then falls back to network before reaching the Ubuntu ISO.

**Fix — two parts:**

**Part 1:** Put the seed ISO on a higher slot than the Ubuntu ISO so SeaBIOS tries the Ubuntu ISO first:
```hcl
additional_iso_files {
  device = "ide3"   # higher than ide2 (Ubuntu ISO)
  ...
}
```

**Part 2:** Use the Proxmox API to set the boot order explicitly after VM creation (before the VM boots):
```bash
curl -sk -X PUT \
  -H "Authorization: PVEAPIToken=..." \
  --data-urlencode "boot=order=ide2;scsi0" \
  "https://PROXMOX_IP:8006/api2/json/nodes/NODE/qemu/VMID/config"
```
This is automated in `make build` via a background polling loop.

---

## 7. Boot command not reaching GRUB — autoinstall never starts

**Symptom:** Console shows the Ubuntu ISO booting but autoinstall doesn't trigger. VM may reboot or show interactive installer.

**Causes investigated:**
- `boot_wait` too short — keystrokes sent while iPXE was still running, not during GRUB
- Semicolon in `ds=nocloud-net;s=http://...` breaking GRUB command line (GRUB interprets `;` as command separator)
- Wrong GRUB navigation (`<down>` count landing on wrong line)
- Hardcoded interface name `ens18` in network config causing hang

**Working boot command (GRUB edit mode):**
```hcl
boot_wait = "20s"
boot_command = [
  "e<wait2>",
  "<down><down><down><end>",
  "<bs><bs><bs><bs><bs>",
  " autoinstall ds=nocloud ---<wait>",
  "<f10><wait>"
]
```

**Key points:**
- `20s` wait is enough once boot order is fixed (no iPXE delay)
- Use `ds=nocloud` (not `ds=nocloud-net`) when using a seed ISO — no URL needed
- `<bs><bs><bs><bs><bs>` removes the trailing ` ---` from the kernel line (5 chars)
- No `<esc>` before `e` — it can interfere with GRUB state

---

## 8. Network config in user-data causing install hang

**Symptom:** Autoinstall hangs at the cloud-init network stage.

**Cause:** Hardcoded interface name (`ens18`) in the `network` section of `user-data`. If the actual interface name differs, the network stage hangs indefinitely.

**Fix:** Remove the `network` section from `user-data` entirely. The Ubuntu 24.04 installer auto-detects the interface.

---

## 9. `make distribute` fails — no SSH key for Proxmox root

**Symptom:**
```
root@192.168.136.238: Permission denied (publickey,password)
```

**Fix:** The `distribute` target uses the Proxmox API directly (curl) instead of SSH. No SSH key needed — uses the same API token as the build.

---

## Summary — what the working setup does differently

| Problem | Wrong approach | Working approach |
|---|---|---|
| Boot order | Rely on Proxmox default | Set via API after VM creation |
| Seed ISO slot | `ide0` (before Ubuntu ISO) | `ide3` (after Ubuntu ISO) |
| Boot command | `c` + semicolon in URL | `e` edit + `ds=nocloud` |
| QEMU agent | Installed in provisioner | Installed in autoinstall packages |
| Network config | Hardcoded `ens18` | Removed entirely |
| Distribute | SSH to Proxmox | Proxmox API (curl) |
