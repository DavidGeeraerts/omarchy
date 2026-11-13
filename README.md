# omarchy

Personal playbook for a Dell hybrid laptop on Omarchy 4.5 (Quattro: Quickshell bar, Lua Hyprland config). Intel Iris Xe plus NVIDIA RTX 3060 Mobile, user `maquis`, timezone `America/Los_Angeles`, US keyboard, Btrfs on LUKS with Limine.

## Install-time config

Omarchy does not read a single preseed file from this repo. The Quattro ISO installs unattended when it finds a second drive labeled `cidata` (or `CIDATA`) and copies a fixed set of files into `/root`. That loader is `configs/airootfs/usr/local/bin/omarchy-cidata-load` in [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso) (branch `quattro`). The required pair is `user_configuration.json` plus `user_credentials.json`. `user_encrypt_installation.txt` containing `true` is the flag the orchestrator reads for an encrypted install.

Those three files are in [`cidata/`](cidata/). They use only keys the Quattro configurator writes (`configs/airootfs/root/configurator` on `quattro`), for a full-disk encrypted install:

| Choice | Value | Why |
| --- | --- | --- |
| User | `maquis` | This machine |
| Hostname | `omarchy` | Setup form default when the hostname prompt is left empty (`OMARCHY_HOSTNAME_DEFAULT` in `install/provisioning/setup-form.sh`) |
| Timezone | `America/Los_Angeles` | This machine |
| Keyboard | `us`, input method `none` | English (US) row in the shared setup form |
| Kernel | `linux-omarchy` | `detect_kernel` on x86_64 that is not a T2 Mac |
| Boot | Limine, ESP at `/boot`, `limine_x64.efi` | Quattro full-disk encrypted path |
| Disk | `/dev/nvme0n1`, Btrfs subvolumes on LUKS, `wipe: true` | Assumed from the later `/dev/nvme0n1p3` note. Confirm with `lsblk` |

`encryption_password` is the plaintext LUKS passphrase. The account and root passwords are the SHA-512 crypt (`openssl passwd -6`) of that same string. Both plaintext copies are the temporary default `2ChangeMe!`: the top-level field in [`cidata/user_credentials.json`](cidata/user_credentials.json), and `disk_config.disk_encryption.encryption_password` in [`cidata/user_configuration.json`](cidata/user_configuration.json). `root_enc_password` and the `maquis` user's `enc_password` are the SHA-512 hash of that same password. The loader copies these JSON files verbatim. Nothing in them is expanded at install time.

**This repository is public, so `2ChangeMe!` is a known default, not a secret.** Anyone who can read the repo can unlock a machine that still uses it. The first boot stops at the disk passphrase. Type `2ChangeMe!`, then log in as `maquis` with the same password, and run `./post-install.sh` immediately, before the laptop leaves home or a trusted network.

`passwd` changes only the login password. It does not change the LUKS passphrase, so the disk stays encrypted with `2ChangeMe!` until `cryptsetup luksChangeKey` runs. That is why the first step of `post-install.sh` does both, then locks `root`. A later run checks the `maquis` hash in `/etc/shadow` and tests each LUKS device, and it skips a prompt once that secret is no longer the temporary default.

Archinstall applies the top-level `encryption_password` from the credentials file (the credentials JSON is merged on top of the configuration). Omarchy's deferred-provisioning helper prefers the nested `disk_encryption.encryption_password`. This config does not defer provisioning. Both copies are `2ChangeMe!` so neither path installs a different public placeholder.

The root partition size is `0` on purpose. The configurator computes it from the target disk, and a guessed size plus `"wipe": true` would erase the wrong layout. On a machine that can see the disk:

```bash
disk=/dev/nvme0n1
disk_size=$(lsblk -bdno SIZE "$disk")
mib=$((1024 * 1024))
gib=$((mib * 1024))
disk_size_in_mib=$((disk_size / mib * mib))
boot_partition_start=$mib
boot_partition_size=$((2 * gib))
main_partition_start=$((boot_partition_size + boot_partition_start))
main_partition_size=$((disk_size_in_mib - main_partition_start - mib))
```

Write `main_partition_size` into the root partition's `size.value` (the object whose `obj_id` is `8c2c2b92-1070-455d-b76a-56263bab24aa`). Leave the 1 MiB start and 2 GiB ESP as they are. Those match the configurator.

The password in the JSON is already the temporary default. Build the drive after that size is written:

```bash
mkdir -p cidata-iso
cp cidata/user_configuration.json cidata/user_credentials.json cidata/user_encrypt_installation.txt cidata-iso/
genisoimage -output cidata.iso -volid cidata -joliet -rock cidata-iso/
```

Attach that ISO next to the Omarchy ISO. With no cidata drive, the wizard runs as usual.

**This full-disk file wipes the whole device.** Quattro's interactive installer can instead use free space and leave other partitions alone, but that path partitions in the configurator and then writes `pre_mounted_config`. The cidata loader skips the configurator, so a free-space install cannot be reproduced by these JSON files. Do not use this cidata set if `/dev/nvme0n1p3` (the NTFS Data partition) has to survive.

An encrypted unattended install still stops at the LUKS passphrase on first boot. That passphrase is the public temporary default above, in plaintext in the JSON. Treat the cidata drive as a copy of the same known password, and rotate it with `post-install.sh` before the machine leaves a trusted network.

Git name and email are not part of the install. After first login: `omarchy setup git --name "Your Name" --email you@example.com`.

## Post-install

On the installed system:

```bash
git clone https://github.com/DavidGeeraerts/omarchy.git
cd omarchy
./post-install.sh --dry-run
./post-install.sh
```

Run it as `maquis`, not as root. The script uses sudo for the credential check, for packages, and, only if you ask, for the data-partition format.

Do this on the first login, while the laptop is still at home. The repo is public and the install password is the known default `2ChangeMe!`.

The first step rotates those temporary credentials before any package work. If the `maquis` hash in `/etc/shadow` still matches `2ChangeMe!`, the script runs `passwd`. If a LUKS device still opens with that passphrase (`cryptsetup open --test-passphrase`), it prints the current passphrase and runs `sudo cryptsetup luksChangeKey` on each such device. `passwd` does not change the disk passphrase, which is why the LUKS command is separate. It then locks `root` with `sudo passwd -l root` when `passwd -S root` says the account is not already locked. A second run skips `passwd` and `luksChangeKey` once those checks show the temporary password is gone, and it leaves `root` locked. `--dry-run` prints that plan and does not change the password, the passphrase, or the lock.

`./post-install.sh` then updates via `omarchy update -y`, installs geeqie, Steam (through Omarchy's lib32 driver step, then `omarchy pkg add steam`), and `nvidia-prime` (`prime-run`). VLC is optional and the install line is commented out. It sets `hwdec=vaapi` for mpv, points Sony ARW/SR2/SRF at Geeqie, installs and enables Matrix Screens with the screensaver on, enables Pulse, installs the latest RAWmakase `.pkg.tar.zst` after `SHA256SUMS`, and adds the Hyprland binding `SUPER + ALT + F`.

The NTFS reformat is not part of a normal run:

```bash
./post-install.sh --reformat-data
```

That destroys `/dev/nvme0n1p3`. It asks you to type `WIPE /dev/nvme0n1p3`, then creates a Btrfs volume labeled `Data` and an `/etc/fstab` line with `noatime,compress=zstd:3`. `--dry-run` prints that plan and does not format.

A log is appended to `~/.local/state/omarchy-playbook/post-install.log`. The script ends with what changed and whether a reboot is needed. The new keybinding is picked up by `hyprctl reload` or a new login.

## Sources

- [Omarchy manual](https://omarchy.org/manual/), including [Unattended installs](https://omarchy.org/manual/unattended-installs/)
- [learn.omacom.io/2/the-omarchy-manual](https://learn.omacom.io/2/the-omarchy-manual) is the legacy Omarchy 3 manual. It points Quattro readers at omarchy.org and does not document cidata.
- [omacom/omarchy](https://github.com/omacom/omarchy) branch `quattro`: `bin/omarchy-update`, `bin/omarchy-pkg-add`, `bin/omarchy-install-gaming-steam`, `bin/omarchy-install-gaming-gpu-lib32`, `bin/omarchy-plugin-add`, `bin/omarchy-plugin-enable`, `config/hypr/bindings.lua`, `default/hypr/helpers.lua`, `default/hypr/nvidia.lua`, `default/pacman/pacman-stable.conf`, `install/provisioning/setup-form.sh`
- [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso) branch `quattro`: `configs/airootfs/usr/local/bin/omarchy-cidata-load`, `configs/airootfs/root/configurator`
- [WhiskeyTangoFussell/omarchy-matrix-screens](https://github.com/WhiskeyTangoFussell/omarchy-matrix-screens)
- [SanchoKusika/omarchy-pulse](https://github.com/SanchoKusika/omarchy-pulse)
- [pch/rawmakase](https://github.com/pch/rawmakase) releases (`SHA256SUMS`, `sudo pacman -U` of the Arch package)
