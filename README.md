
# Project Goal

Simplify the process of creating an ISO auto install image for ubuntu server or desktop versions to install the OS on local or virtual machines without the need of any user interaction during the process. Auto-provision users and SSH certificates.

# My use case

In my use case we have multiple headless servers to provision. We use this autoinstall ISO, flash them directly on the servers SSD and boot them. After a while we set a hostname in the router for the machines. The host name will be adapted after a reboot.  

# Approach

- A minimal (debian-slim) devcontainer provides the necessary tools to create an autoinstall iso image.
- The user configures the desired setting including users, ssh certificates, network settings and applications installs in user-data (you can rename it of course!)
- The `generate_autoinstall_iso.sh` script is used to download the specified ubuntu flavor and versions. The original Ubuntu iso images are patched with a user-data and modifications to the GRUB bootloader to enable autoboot to RAM. The tool `xorriso` is used  to create the autoinstall iso images.

# Usage

## Step 0 Requirements

- Docker + VScode installed on your machine
- Open the project in VScode and open the devcontainer. The devcontainer will install all necessary tools to create the autoinstall iso images.

## Step 1
In `user-data`  initial users (cape and trecs) are created with encrypted passwords. See the comments in the file how to generate the encrypted passwords. You can also add ssh keys for the users if you want to be able to ssh into the machine after installation:
```yaml
users:
  - name: trecs
    gecos: trecs developer
    groups: users, admin, docker, sudo
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    # password hash created using: openssl passwd -6 YOUR_PASSWORD
    passwd: "$6$wZbZSrDA1OWzPZ7t$qQcjn2sIw1yY8PmluT5dfocYBszOWLrqwXsLXLvrQCJ7umaCGVP5S.lWdGGzQY.lEKbGweGiAZHBjazZGy4S9."
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-ed25519 AAAALALALALALALALAAAALLALALA5AAAAIDSH6TV6Cg0FkJFw3ModUCRQcd9J+QZ5bN3Z8xM2/mti ssh-recs-testbed
```

## Step 2

Invoke ./generate_autoinstall_iso.sh `<version>` `<flavor>` `[tty]` `[baudrate]` in the VScode terminal.

  `version`  : codename (e.g. `questing`) or numeric (e.g. `25.10`)

  `flavor`   : `server` | `desktop` (desktop needs 24.04 or newer: older desktop ISOs use the Ubiquity installer, which does not support autoinstall)

  `tty`      : serial console TTY (e.g. `ttyS2`). Omit to skip serial console redirection and use the default kernel console.

  `baudrate` : serial console speed (e.g. `115200n8`, default: `115200n8`)

The script picks the newest point release of the given version (e.g. `24.04.5` for server, `24.04.5.1` for desktop) from the release's `SHA256SUMS`. That file is verified against the Ubuntu CD image signing key shipped in `keys/`, and the downloaded ISO is verified against it. Downloads go to a `.part` file that is resumed after an abort and only becomes the cached ISO once its checksum matches. With a cached ISO and cached `SHA256SUMS` the script also works without network access.

After downloading the original iso, the patching progress will take around 2-4 minutes. 

The ISO is extracted below `$TMPDIR` (default `/tmp`), which needs about the ISO's size in free space. If `/tmp` is a small RAM disk, use e.g. `TMPDIR=/var/tmp ./generate_autoinstall_iso.sh ...`.


Example: 
`./generate_autoinstall_iso.sh 26.04 server ttyS2` will create a timestamped ISO file in the root folder, e.g., `ubuntu_26.04_server_ttys2_autoinstall_2026-06-16__19-48.iso` 

`./generate_autoinstall_iso.sh 26.04 server` (no tty) will create e.g. `ubuntu_26.04_server_autoinstall_2026-06-16__19-48.iso` with no serial console redirection.

## Step 3

Flash on USB or directly on M.2 SSD. I recommend `balena etcher` 

### Flashing with `dd`

`dd` overwrites the target without asking, so identifying the right device is the most important step.

1. Find the SSD: list the disks before and after plugging it in (e.g. via a USB adapter or M.2 enclosure). The new device is the target. Prefer its stable name from `/dev/disk/by-id/`, since `sdX` names can change between calls. Always use the **whole device** (`sdb`), never a partition (`sdb1`).
   ```bash
   lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN   # before and after plugging in
   ls -l /dev/disk/by-id/ | grep -v part
   ```
2. Unmount any automounted partitions of the SSD:
   ```bash
   sudo umount /dev/sdX?* 2>/dev/null
   ```
3. Write the image:
   ```bash
   ISO=ubuntu_24.04_server_autoinstall_2026-10-20__16-05.iso
   TARGET=/dev/disk/by-id/<your-ssd>
   sudo dd if="$ISO" of="$TARGET" bs=4M status=progress oflag=direct conv=fsync
   ```
4. Verify the written data (no output means identical):
   ```bash
   sudo cmp -n "$(stat -c %s "$ISO")" "$ISO" "$TARGET"
   ```
5. Detach the SSD safely:
   ```bash
   udisksctl power-off -b "$TARGET"
   ```

Notes:
- Everything on the SSD is lost.
- Some tools afterwards warn that the backup GPT header is not at the end of the disk. The image is smaller than the SSD, so this is expected and harmless.
- Make sure the SSD is the only disk in the target machine: the installer copies itself to RAM (`toram`) and then wipes the install disk without confirmation.


> 🚨 **WARNING — This installer will erase the first found disk**
>
> The autoinstall image is configured to erase the primary disk and install Ubuntu automatically. On first boot the installer is loaded into RAM from the boot device and will wipe the target drive. Carefully verify the correct target device before flashing or booting.
>
> Recommended checks before flashing or booting:
> - Unplug other removable drives if possible to avoid accidental wipes.
> - Test the generated ISO in a VM (for example with QEMU) before using it on real hardware.

Storage config used by the installer:

```yaml
storage:
  layout:
    name: direct  # install to the first (only) available disk
```

## Step 4 

I assume that the BIOS of the machine is configured to boot automatically from USB. 

Wait for 10-15 minutes. 

The machine will auto-install, reboot, and you will see a machine "ubuntu-autoinstall-$mac" in your network. The $mac (MAC Address) of the first ethernet device helps us to set a DHCP hostname in the router, which will automatically propagate to the Ubuntu as new hostname after a reboot. 

Using openWRT you can set the hostname via:
  1. `Overview:` `Active DHCP Leases` --> find the new node and click on `Set Static`
  2. `Network:` `DHCP and DNS` --> `Static Leases` --> find the new node and click on `Edit` --> set the hostname to "NAME_OF_YOUR_CHOICE" and save.
  3. Reboot the machine and you should see the new hostname in your network and as machine name on login.


Below are some code snippets responsible for this behaviour: 
```yaml
late-commands:
  # Set MAC-based hostname before first boot so the router sees it on the first DHCP request
  - |
    # Picks the NIC the router will actually see: prefers one that already has
    # an IPv4 lease, then one with carrier (cable in), then the first physical
    # NIC. Virtual interfaces (bridges, bonds, veth, docker0) are skipped.
    iface=$(pick_iface)
    mac=$(tr -d ':' < "/sys/class/net/$iface/address")
    hostname="ubuntu-autoinstall-$mac"
    echo "$hostname" > /target/etc/hostname
    sed -i '/^127\.0\.1\.1/d' /target/etc/hosts
    printf '127.0.1.1\t%s\n' "$hostname" >> /target/etc/hosts
```

# Behaviour without network

The image is intentionally minimal and does nothing beyond the base install:

- **`update: no`**, so subiquity never tries to fetch a newer installer snap.
- **`optional: true` on the NICs**, so the installer does not wait on an
  interface that has no cable.
- **No packages, no `runcmd`, no `package_update`/`package_upgrade`.** Nothing
  runs on first boot beyond user/SSH setup and the MAC-based hostname in
  `late-commands`. Nothing waits on or depends on network access after install.

If you need to install packages or run first-boot setup, keep in mind cloud-init's
`runcmd` and `packages` only run **once**. If the network is down for that boot,
those steps are skipped and are *not* retried on later boots — anything that must
survive a flaky first boot belongs in a retrying systemd unit, not in `runcmd`.

# Tests

`tests/run_tests.sh` checks release resolution against the real Ubuntu servers (only `SHA256SUMS` is downloaded, no ISOs), signature and checksum handling, offline behaviour, and a full build of a tiny test ISO signed with a throwaway key. It needs network access, `xorriso`, `gpg` and `gpgv`.

```bash
tests/run_tests.sh
```

# Add new ubuntu versions:

Easy! Add the codename and version to the array in `generate_autoinstall_iso.sh`. Point releases need no entry, they are resolved automatically. Don't forget to make a PR :)

```bash
declare -A ubuntu_releases=(
  # codename: release version
  [questing]="25.10"
  [resolute]="26.04"
  [stonking]="26.10"
)
```