# omarchy

Personal playbook for a Dell hybrid laptop on Omarchy 4.5 (Quattro: Quickshell bar, Lua Hyprland config). Intel Iris Xe plus NVIDIA RTX 3060 Mobile, user `maquis`, timezone `America/Los_Angeles`, US keyboard, Btrfs on LUKS with Limine.

System snapshot: [fastfetch.md](fastfetch.md), captured 2026-11-14.

## Pre-install: BIOS settings

Do these in the Dell firmware setup before the Omarchy ISO boots. Press F2 at the logo. The key and the menu names vary by model. This is a checklist so later firmware choices can be added here.

- [ ] **Touchscreen: off.** `post-install.sh` does this automatically on a Dell machine that exposes `dell-wmi-sysman`. The step skips with a log when `/sys/class/firmware-attributes/dell-wmi-sysman/attributes/Touchscreen` does not exist (another vendor, or the module is not loaded). It writes `Disabled` only when that word is in `possible_values`, `current_value` is not already `Disabled`, and `authentication/Admin/is_enabled` is `0`. On this XPS 17 9720, `possible_values` is `Disabled;Enabled;`, `current_value` is root-readable only, and the BIOS admin password is not set (`is_enabled` is `0`). The write is staged in firmware (`pending_reboot`) and takes effect after a reboot. If a BIOS admin password is set (`is_enabled` is `1`), the step skips: it does not handle passwords, and the touchscreen has to be turned off in BIOS setup. The manual fallback, and the way to do it before the OS is installed, is F2, then System Configuration or Integrated Devices, then Touchscreen, then Off. From a shell:

```bash
ls /sys/class/firmware-attributes/dell-wmi-sysman/attributes/ | grep -i touch
A=/sys/class/firmware-attributes/dell-wmi-sysman/attributes/Touchscreen
cat $A/current_value $A/possible_values
echo Disabled | sudo tee $A/current_value
```

`current_value` is not readable by the login user, so `cat` of that file needs sudo. `sudo cat` shows it. The `echo` line is what stages `Disabled`.

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
| Disk | `/dev/nvme0n1`, Btrfs subvolumes on LUKS, `wipe: true` | OS disk only. The Data drive is `/dev/nvme1n1` and is not in this file |

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

**This full-disk file wipes `/dev/nvme0n1`.** That is the OS disk. Quattro's interactive installer can instead use free space and leave other partitions alone, but that path partitions in the configurator and then writes `pre_mounted_config`. The cidata loader skips the configurator, so a free-space install cannot be reproduced by these JSON files.

The secondary drive is `/dev/nvme1n1`. It is not in `disk_config`, and the install must not be pointed at it. `post-install.sh` is what mounts it. The layout left on that drive is:

| Partition | Size | Role |
| --- | --- | --- |
| `/dev/nvme1n1p1` | 1M | Leftover Windows partition. The script never touches it |
| `/dev/nvme1n1p2` | 15M | Leftover Windows partition. The script never touches it |
| `/dev/nvme1n1p3` | about 1.8T | Btrfs label `Data`, subvolume `@data`, mounted at `/data` |

`/data` is not encrypted. The root filesystem is LUKS. Do not move `/home` onto `/data`. The UUID is not stored in this repo. A reformat changes it, so the script reads it from `blkid` at runtime. The partition path is the variable `DATA_PART` (default `/dev/nvme1n1p3`).

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

Run it as `maquis`, not as root. The script uses sudo for the credential check, for packages, for the `/data` fstab entry and mount, for the Dell touchscreen attribute, and, only if you ask, for erasing the Data partition.

Do this on the first login, while the laptop is still at home. The repo is public and the install password is the known default `2ChangeMe!`.

The first step rotates those temporary credentials before any package work. If the `maquis` hash in `/etc/shadow` still matches `2ChangeMe!`, the script runs `passwd`. If a LUKS device still opens with that passphrase (`cryptsetup open --test-passphrase`), it prints the current passphrase and runs `sudo cryptsetup luksChangeKey` on each such device. `passwd` does not change the disk passphrase, which is why the LUKS command is separate. It then locks `root` with `sudo passwd -l root` when `passwd -S root` says the account is not already locked. A second run skips `passwd` and `luksChangeKey` once those checks show the temporary password is gone, and it leaves `root` locked. `--dry-run` prints that plan and does not change the password, the passphrase, or the lock.

`./post-install.sh` then updates via `omarchy update -y` and, next, installs `omarchy-agents-nostarters` and runs it so the Agents bar drops the three "Make something cool" starter tiles. It installs geeqie, Steam (through Omarchy's lib32 driver step, then `omarchy pkg add steam`), and `nvidia-prime` (`prime-run`). VLC is optional and the install line is commented out. It sets `hwdec=vaapi` for mpv, points Sony ARW/SR2/SRF at Geeqie, installs and enables Matrix Screens with the screensaver on, enables Pulse, and installs the latest RAWmakase `.pkg.tar.zst` after `SHA256SUMS`. On a Dell machine it then disables the touchscreen through `dell-wmi-sysman`, as described in the BIOS checklist above. That firmware change needs a reboot.

### Agents panel

The Agents bar panel shows three "Make something cool" starter tiles: theme, plugin, and app. Omarchy has no setting to hide them. The panel is `/usr/share/omarchy/shell/plugins/agents`, which the omarchy package owns, so a direct edit is overwritten on the next `omarchy update`.

After `omarchy update`, `post-install.sh` copies [`bin/omarchy-agents-nostarters`](bin/omarchy-agents-nostarters) to `~/.local/bin/omarchy-agents-nostarters` and runs it. The script builds a user-plugin copy at `~/.config/omarchy/plugins/local.agents` (id `local.agents`, display name "Agents (no starters)") and changes the bar entry in `~/.config/omarchy/shell.json` from `omarchy.agents` to `local.agents`. When it rewrites `shell.json`, it saves a copy next to it as `shell.json.bak.<unix time>`. If `/usr/share/omarchy/shell/plugins/agents` is not there, the step logs a skip and does not change the bar.

That copy does not receive later Agents-panel changes until you run `omarchy-agents-nostarters` again. `post-install.sh` does that after every `omarchy update`. After an update you ran by hand, run `omarchy-agents-nostarters` yourself.

If the upstream `Panel.qml` layout no longer matches the patch anchors, the script aborts and does not replace `~/.config/omarchy/plugins/local.agents` or edit `shell.json`.

To revert, change the bar entry id back to `omarchy.agents` in `~/.config/omarchy/shell.json` and delete `~/.config/omarchy/plugins/local.agents`.

### Data drive

A normal run does not format anything. If `/dev/nvme1n1p3` is already Btrfs labeled `Data` and has an `@data` subvolume, the script mounts it at `/data`. Any other filesystem is left alone, with a warning.

The UUID is not hardcoded. When `/etc/fstab` has no line whose mount point is `/data`, the script appends the line it read from `blkid`:

```
UUID=<uuid>  /data  btrfs  rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@data,nofail  0 0
```

It then runs `systemctl daemon-reload`, `mount /data`, and `chown` of `/data` to the login user. It adds one Nautilus bookmark, the line `file:///data Data` in `~/.config/gtk-3.0/bookmarks`. `nofail` keeps a missing drive from stopping boot. `/data` is unencrypted, unlike the LUKS root. Do not move `/home` there.

```bash
./post-install.sh --reformat-data
```

`--reformat-data` erases the Data drive. It does that only when the filesystem is NTFS (`ntfs` or `ntfs3`). It asks you to type `WIPE /dev/nvme1n1p3`, then runs `mkfs.btrfs -f -L Data` on `/dev/nvme1n1p3`, mounts the new filesystem, runs `btrfs subvolume create @data`, and unmounts. A volume that is already Btrfs labeled `Data` is not formatted again. If that volume is missing `@data`, the flag creates the subvolume and does not run `mkfs`. The flag refuses `nvme1n1p1`, `nvme1n1p2`, any partition of the encrypted OS disk `nvme0n1`, a partition mounted at `/`, `/boot`, `/efi`, or `/home`, `crypto_LUKS`, and a partition smaller than 1 GiB. `--dry-run` prints the plan and does not format.

### Steam library

When `/data` is the Data drive, the script creates `/data/SteamLibrary/steamapps` for the login user.

If `~/.local/share/Steam/steamapps/libraryfolders.vdf` exists and Steam is not running, the script copies it to a dated `.bak` beside it and rewrites `/run/media/<user>/Data/SteamLibrary` to `/data/SteamLibrary`. `<user>` is the account that runs the script. If the file has no `/data/SteamLibrary` entry, the script does not invent one. Add `/data/SteamLibrary` in Steam > Settings > Storage and make it the default. Quit Steam before a re-run that still has to edit the file.

### Keybindings

Omarchy 4.5 keeps personal bindings in `~/.config/hypr/bindings.lua`, loaded after the defaults. A new key uses `o.bind`. A key Omarchy already binds uses `o.rebind`. These are Lua calls, not Hyprland `bind=` lines in a `.conf` file. `SUPER + ALT + F` was already an `o.bind` line in that file. It maximizes the focused window.

The script keeps each of these lines once. It backs up `bindings.lua` before it writes, and it runs `hyprctl reload` when Hyprland is running:

```lua
o.bind("SUPER + ALT + F", "Maximize", "hyprctl dispatch fullscreen 1")
-- Launch Grok Bot instead of the Grok web app.
o.rebind("SUPER + SHIFT + ALT + A", "Grok Bot", { launch = "grok-bot", focus = "^grok-bot$" })
o.rebind("SUPER + SHIFT + A", "Grok", { webapp = "https://grok.com" })
```

`SUPER + SHIFT + A` was the ChatGPT web app and is now the Grok web app. `SUPER + SHIFT + ALT + A` was the Grok web app and is now Grok Bot. The Grok Bot line is written only when `grok-bot` is on `PATH`. Otherwise the script logs a skip and leaves an existing Bot line in place.

A log is appended to `~/.local/state/omarchy-playbook/post-install.log`. The script ends with what changed and whether a reboot is needed. A bindings change does not need a reboot. Disabling the touchscreen does: `dell-wmi-sysman` keeps it in `pending_reboot` until the next boot.

## Sources

- [Omarchy manual](https://omarchy.org/manual/), including [Unattended installs](https://omarchy.org/manual/unattended-installs/)
- [learn.omacom.io/2/the-omarchy-manual](https://learn.omacom.io/2/the-omarchy-manual) is the legacy Omarchy 3 manual. It points Quattro readers at omarchy.org and does not document cidata.
- [omacom/omarchy](https://github.com/omacom/omarchy) branch `quattro`: `bin/omarchy-update`, `bin/omarchy-pkg-add`, `bin/omarchy-install-gaming-steam`, `bin/omarchy-install-gaming-gpu-lib32`, `bin/omarchy-plugin-add`, `bin/omarchy-plugin-enable`, `shell/plugins/agents` (`Panel.qml`, `manifest.json`), `config/hypr/bindings.lua`, `default/hypr/helpers.lua`, `default/hypr/bindings/applications.lua`, `default/hypr/nvidia.lua`, `default/pacman/pacman-stable.conf`, `install/provisioning/setup-form.sh`
- Linux `dell-wmi-sysman` firmware attributes: `/sys/class/firmware-attributes/dell-wmi-sysman/attributes/Touchscreen` (`current_value`, `possible_values`), `authentication/Admin/is_enabled`, and `pending_reboot`
- [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso) branch `quattro`: `configs/airootfs/usr/local/bin/omarchy-cidata-load`, `configs/airootfs/root/configurator`
- [WhiskeyTangoFussell/omarchy-matrix-screens](https://github.com/WhiskeyTangoFussell/omarchy-matrix-screens)
- [SanchoKusika/omarchy-pulse](https://github.com/SanchoKusika/omarchy-pulse)
- [pch/rawmakase](https://github.com/pch/rawmakase) releases (`SHA256SUMS`, `sudo pacman -U` of the Arch package)
