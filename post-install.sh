#!/usr/bin/env bash
# Post-install playbook for this Omarchy machine (Quattro / 4.x).
# Idempotent: each step checks current state before it changes anything.
# Refuses to run as root. Uses sudo for credential checks, packages, fstab,
# mounts, and format work.
#
# Sources for the Omarchy commands are cited next to the steps that call them.

set -euo pipefail

DRY_RUN=0
REFORMAT_DATA=0
HYPR_RELOAD=0
HYPR_RELOADED=0
DATA_READY=0

# Secondary drive, not the LUKS root. nvme1n1p1 (1M) and nvme1n1p2 (15M) are
# leftover Windows partitions and are never touched. The UUID is read from
# blkid at runtime: mkfs changes it, so it is not hardcoded. /data is
# unencrypted; do not point DATA_MOUNT at /home.
DATA_PART="/dev/nvme1n1p3"
DATA_LABEL="Data"
DATA_MOUNT="/data"
DATA_SUBVOL="@data"
DATA_CONFIRM="WIPE ${DATA_PART}"
FSTAB_OPTIONS="rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/${DATA_SUBVOL},nofail"
FSTAB_FILE="/etc/fstab"

# Public temporary password. The cidata loader copies user_credentials.json
# verbatim from this public repo, so the install cannot start from a secret.
TEMP_PASSWORD='2ChangeMe!'
LOGIN_USER='maquis'

MATRIX_ID="io.github.whiskeytangofussell.matrixscreens"
MATRIX_URL="https://github.com/WhiskeyTangoFussell/omarchy-matrix-screens"
MATRIX_SECTION="right"
PULSE_ID="io.github.sanchokusika.pulse"
PULSE_URL="https://github.com/SanchoKusika/omarchy-pulse"
PULSE_SECTION="left"

GEEQIE_DESKTOP="org.geeqie.Geeqie.desktop"
MPV_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mpv/mpv.conf"
BINDINGS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
# Omarchy 4.5 reads this Lua file (o.bind / o.rebind), not Hyprland bind= lines.
# SUPER + ALT + F is a new binding. The Grok chords already exist, so those use
# o.rebind: SUPER+SHIFT+A was ChatGPT, SUPER+SHIFT+ALT+A was the Grok web app.
BIND_LINE='o.bind("SUPER + ALT + F", "Maximize", "hyprctl dispatch fullscreen 1")'
GROK_BOT_COMMENT='-- Launch Grok Bot instead of the Grok web app.'
GROK_BOT_LINE='o.rebind("SUPER + SHIFT + ALT + A", "Grok Bot", { launch = "grok-bot", focus = "^grok-bot$" })'
GROK_WEB_LINE='o.rebind("SUPER + SHIFT + A", "Grok", { webapp = "https://grok.com" })'
GTK_BOOKMARKS="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"
# Steam's usual path on this machine. Not XDG_DATA_HOME: Steam keeps this file here.
STEAM_LIBRARY_VDF="$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
MATRIX_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/matrix-screens/settings.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-playbook"
LOG_FILE="$STATE_DIR/post-install.log"

CHANGES=()

usage() {
  cat <<EOF
Usage: ./post-install.sh [--dry-run] [--reformat-data]

  --dry-run         Print the actions. Do not change the system.
  --reformat-data   DESTRUCTIVE and off by default. Erase ${DATA_PART}
                    when its filesystem is NTFS and create a Btrfs volume
                    labeled ${DATA_LABEL}, subvolume ${DATA_SUBVOL}, mounted
                    at ${DATA_MOUNT}.
                    Requires typing: ${DATA_CONFIRM}
                    A volume that is already Btrfs labeled ${DATA_LABEL} is
                    not formatted again. nvme1n1p1 and nvme1n1p2 are leftover
                    Windows partitions and are never touched.
                    Ignored for execution when combined with --dry-run.

Without --reformat-data, a partition that is already Btrfs labeled ${DATA_LABEL}
with a ${DATA_SUBVOL} subvolume is mounted at ${DATA_MOUNT}. Anything else is
left unchanged and a warning is printed. ${DATA_MOUNT} is not encrypted. The
OS disk is LUKS. Do not move /home there.

The first step checks whether the temporary password ${TEMP_PASSWORD} is still
the ${LOGIN_USER} login password or a LUKS passphrase. When it is, the step runs
passwd and cryptsetup luksChangeKey. It also locks root. --dry-run prints
that plan and does not change credentials.

Run as the Omarchy user (not root). sudo is used where a step needs it.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

step() {
  log ""
  log "==> $*"
}

changed() {
  if [[ $DRY_RUN -eq 1 ]]; then
    CHANGES+=("would: $*")
  else
    CHANGES+=("$*")
  fi
}

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    local line
    line=$(printf 'dry-run:'
      printf ' %q' "$@"
      printf '\n')
    log "$line"
    return 0
  fi
  "$@"
}

require_cmd() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

pkg_installed() {
  pacman -Q "$1" >/dev/null 2>&1
}

pkg_add() {
  local pkg=$1
  if pkg_installed "$pkg"; then
    log "$pkg already installed"
    return 0
  fi
  # omarchy-pkg-add (quattro bin/omarchy-pkg-add) installs with
  # pacman -S --needed --noconfirm and checks the package landed.
  run omarchy pkg add "$pkg"
  changed "installed $pkg"
}

ensure_line() {
  local file=$1
  local line=$2
  local dir
  dir=$(dirname "$file")
  if [[ -f $file ]] && grep -qxF -- "$line" "$file"; then
    log "already present in $file"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log "would append to $file: $line"
    changed "append to $file: $line"
    return 0
  fi
  mkdir -p "$dir"
  printf '%s\n' "$line" >>"$file"
  changed "appended to $file: $line"
}

# --- temporary credentials ---------------------------------------------------
# The install password is a known default. passwd changes the login password
# only, so the LUKS passphrase has to be rotated with luksChangeKey.

ensure_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    die "sudo is required to check temporary credentials, and no terminal is available"
  fi
  log "sudo is required to read /etc/shadow and to test the disk passphrase"
  # sudo reads its own password from the terminal, not from stdin.
  sudo -v
  sudo -n true
}

print_temp_credential_warning() {
  cat <<EOF | tee -a "$LOG_FILE" >&2

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! TEMPORARY CREDENTIALS ARE STILL ACTIVE
!!
!! This repository is public. The password ${TEMP_PASSWORD} is a known
!! default for the ${LOGIN_USER} login and for the disk passphrase.
!! Anyone who has read the repo can use a machine that still has it.
!!
!! Change them before this laptop leaves home or a trusted network.
!! passwd changes only the login password. The disk passphrase stays
!! the same until cryptsetup luksChangeKey runs.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
}

# Returns 0 when the hash verifies, 1 when it does not.
# python3 crypt, then passlib, then openssl passwd -6 -salt.
hash_matches_password() {
  local hash=$1
  local password=$2
  local result rc salt computed

  if command -v python3 >/dev/null 2>&1; then
    set +e
    result=$(
      HASH="$hash" PASSWORD="$password" PYTHONWARNINGS='ignore::DeprecationWarning' \
        python3 - <<'PY'
import os
import sys

password = os.environ["PASSWORD"]
shadow = os.environ["HASH"]
if not shadow.startswith("$6$"):
    print("no")
    raise SystemExit(0)

crypt = None
try:
    import crypt as crypt_mod
    crypt = crypt_mod
except ImportError:
    crypt = None

if crypt is not None:
    try:
        got = crypt.crypt(password, shadow)
    except (OSError, ValueError):
        got = None
    if got:
        print("yes" if got == shadow else "no")
        raise SystemExit(0)

try:
    from passlib.hash import sha512_crypt
    print("yes" if sha512_crypt.verify(password, shadow) else "no")
except ImportError:
    raise SystemExit(2)
except Exception:
    raise SystemExit(2)
PY
    )
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      [[ $result == yes ]]
      return
    fi
    if [[ $rc -ne 2 ]]; then
      die "python could not check the shadow hash (exit $rc)"
    fi
  fi

  command -v openssl >/dev/null 2>&1 || die "python crypt/passlib and openssl are unavailable; cannot check the temporary password"
  case $hash in
    *\$rounds=*)
      die "the shadow hash uses an explicit rounds count, and python crypt/passlib could not check it"
      ;;
  esac
  salt=$(printf '%s\n' "$hash" | awk -F'$' 'NF < 4 { exit 1 } { print $3; exit }')
  [[ -n $salt ]] || die "could not read the salt from the shadow hash for $LOGIN_USER"
  computed=$(printf '%s' "$password" | openssl passwd -6 -salt "$salt" -stdin)
  [[ $computed == "$hash" ]]
}

user_password_is_temporary() {
  local hash rc
  set +e
  hash=$(sudo -n awk -F: -v user="$LOGIN_USER" '$1 == user { print $2; found = 1; exit } END { if (!found) exit 1 }' /etc/shadow)
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    die "could not read the shadow entry for $LOGIN_USER"
  fi
  if [[ -z $hash ]]; then
    return 1
  fi
  case $hash in
    \$6\$*) ;;
    *) return 1 ;;
  esac
  hash_matches_password "$hash" "$TEMP_PASSWORD"
}

# Appends $2 to the nameref array named by $1 when it is a new block device.
record_luks_device() {
  local -n _bucket=$1
  local dev=$2
  local existing
  [[ -n $dev && $dev == /dev/* ]] || return 0
  if [[ -e $dev ]]; then
    dev=$(readlink -f -- "$dev")
  fi
  if [[ ${#_bucket[@]} -gt 0 ]]; then
    for existing in "${_bucket[@]}"; do
      [[ $existing == "$dev" ]] && return 0
    done
  fi
  _bucket+=("$dev")
}

luks_backing_from_status() {
  local name=$1
  sudo -n cryptsetup status "$name" 2>/dev/null | awk 'tolower($1) ~ /^device:$/ { print $2; exit }'
}

# Fills the nameref array named by $1. Root-backing devices first, then any
# other crypto_LUKS device. Runs in the current shell so a failure can abort.
collect_luks_devices() {
  local dest=$1
  local root_src name type fstype scan pass row_backing
  root_src=$(findmnt -nro SOURCE / 2>/dev/null || true)
  root_src=${root_src%%\[*}

  for pass in root all; do
    if [[ $pass == root ]]; then
      [[ -n $root_src ]] || continue
      # The source can be a subvolume path lsblk does not accept. The full
      # scan below is the one that must succeed.
      scan=$(sudo -n lsblk -nr -s -o NAME,TYPE,FSTYPE -- "$root_src" 2>/dev/null || true)
    else
      scan=$(sudo -n lsblk -nr -o NAME,TYPE,FSTYPE) || die "lsblk failed; cannot look for LUKS devices"
    fi
    while read -r name type fstype; do
      [[ -n $name ]] || continue
      if [[ $fstype == crypto_LUKS ]]; then
        if [[ $name == /* ]]; then
          record_luks_device "$dest" "$name"
        else
          record_luks_device "$dest" "/dev/$name"
        fi
      elif [[ $type == crypt ]]; then
        row_backing=$(luks_backing_from_status "$name")
        record_luks_device "$dest" "$row_backing"
      fi
    done <<<"$scan"
  done
}

# Returns 0 when the temporary passphrase still opens the device.
# Exit 2, or cryptsetup's "No key available" message, means it does not.
luks_accepts_temp_passphrase() {
  local dev=$1
  local err rc
  err=$(mktemp)
  set +e
  printf '%s' "$TEMP_PASSWORD" | sudo -n cryptsetup open --test-passphrase "$dev" - 2>"$err"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    rm -f "$err"
    return 0
  fi
  if [[ $rc -eq 2 ]] || grep -qi 'no key available' "$err"; then
    rm -f "$err"
    return 1
  fi
  log "cryptsetup failed on $dev: $(tr '\n' ' ' <"$err")"
  rm -f "$err"
  die "could not test the LUKS passphrase on $dev (cryptsetup exit $rc)"
}

root_account_is_locked() {
  local status state err rc
  err=$(mktemp)
  set +e
  status=$(sudo -n passwd -S root 2>"$err")
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "passwd -S root failed: $(tr '\n' ' ' <"$err")"
    rm -f "$err"
    die "could not read whether root is locked"
  fi
  rm -f "$err"
  state=$(awk '{ print $2 }' <<<"$status")
  [[ $state == L || $state == LK ]]
}

step_rotate_credentials() {
  local user_temp=0
  local dev
  local -a luks_devs=()
  local -a temp_devs=()
  local -a other_devs=()

  command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup is required to test the temporary disk passphrase"
  command -v findmnt >/dev/null 2>&1 || die "findmnt is required to find the LUKS device backing /"
  command -v lsblk >/dev/null 2>&1 || die "lsblk is required to find LUKS devices"
  command -v awk >/dev/null 2>&1 || die "awk is required to read account status"
  command -v passwd >/dev/null 2>&1 || die "passwd is required to rotate the temporary password"

  ensure_sudo

  if user_password_is_temporary; then
    user_temp=1
  fi

  collect_luks_devices luks_devs
  if [[ ${#luks_devs[@]} -gt 0 ]]; then
    for dev in "${luks_devs[@]}"; do
      if luks_accepts_temp_passphrase "$dev"; then
        temp_devs+=("$dev")
      else
        other_devs+=("$dev")
      fi
    done
  fi

  # Before any other step output, so a still-default install is obvious.
  if [[ $user_temp -eq 1 || ${#temp_devs[@]} -gt 0 ]]; then
    print_temp_credential_warning
  fi

  step "Rotate temporary credentials"

  if [[ $user_temp -eq 1 ]]; then
    log "The login password for $LOGIN_USER is still the temporary default."
    log "passwd prompts for the current password, then the new password twice."
    log "Current password: $TEMP_PASSWORD"
    log "passwd does not change the disk passphrase."
    if [[ $DRY_RUN -eq 1 ]]; then
      log "dry-run: would run passwd for $LOGIN_USER"
      changed "change the $LOGIN_USER login password"
    else
      if [[ $(id -un) != "$LOGIN_USER" ]]; then
        die "run ./post-install.sh as $LOGIN_USER to change the temporary login password"
      fi
      if [[ ! -r /dev/tty ]]; then
        die "changing the $LOGIN_USER password needs a terminal"
      fi
      passwd </dev/tty
      if user_password_is_temporary; then
        die "the $LOGIN_USER password is still the temporary default"
      fi
      changed "changed the $LOGIN_USER login password"
    fi
  else
    log "The $LOGIN_USER password is not the temporary default."
  fi

  if [[ ${#luks_devs[@]} -eq 0 ]]; then
    log "WARNING: no LUKS device was found. The disk passphrase was not checked and was not changed."
    log "passwd does not change a disk passphrase. If this system is encrypted, run: sudo cryptsetup luksChangeKey <device>"
  elif [[ ${#temp_devs[@]} -eq 0 ]]; then
    log "No LUKS device still uses the temporary passphrase."
  elif [[ ${#other_devs[@]} -gt 0 ]]; then
    for dev in "${other_devs[@]}"; do
      log "LUKS passphrase on $dev is not the temporary default."
    done
  fi

  if [[ ${#temp_devs[@]} -gt 1 ]]; then
    log "More than one LUKS device still uses the temporary passphrase."
    log "The prompt repeats for each device. Each one still expects ${TEMP_PASSWORD} until that device is changed."
  fi

  if [[ ${#temp_devs[@]} -gt 0 ]]; then
    for dev in "${temp_devs[@]}"; do
      log "The disk passphrase on $dev is still the temporary default."
      log "sudo cryptsetup luksChangeKey prompts for the current passphrase, then the new one twice."
      log "Current passphrase: $TEMP_PASSWORD"
      log "passwd does not change this passphrase. There is no recovery if the new one is lost."
      if [[ $DRY_RUN -eq 1 ]]; then
        log "dry-run: would run sudo cryptsetup luksChangeKey $dev"
        changed "change the LUKS passphrase on $dev"
      else
        if [[ ! -r /dev/tty ]]; then
          die "changing the LUKS passphrase on $dev needs a terminal"
        fi
        # cryptsetup reads the passphrase from stdin. Point that at the
        # terminal so an earlier pipe cannot answer the prompt.
        # shellcheck disable=SC2024
        sudo -n cryptsetup luksChangeKey "$dev" </dev/tty
        if luks_accepts_temp_passphrase "$dev"; then
          die "the LUKS passphrase on $dev is still the temporary default"
        fi
        changed "changed the LUKS passphrase on $dev"
      fi
    done
  fi

  if root_account_is_locked; then
    log "root account is already locked"
  else
    log "locking the root account"
    run sudo -n passwd -l root
    changed "locked the root account"
  fi
}

# --- steps -------------------------------------------------------------------

step_update() {
  step "System update"
  # bin/omarchy-update: -y skips the start confirmation and sets
  # OMARCHY_UPDATE_UNATTENDED. It does not reboot by itself; a needed reboot
  # is printed as "Run omarchy-system reboot when ready."
  log "omarchy update -y"
  run omarchy update -y
  changed "ran omarchy update -y"
}

ensure_multilib() {
  local tmp
  # Quattro ships [multilib] enabled in default/pacman/pacman-stable.conf.
  # Older installs sometimes left the section commented, which makes steam
  # and lib32-* uninstallable (omarchy issue 1790).
  if grep -Eq '^[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf; then
    log "[multilib] already enabled"
    return 0
  fi
  if ! grep -Eq '^[[:space:]]*#[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf; then
    die "[multilib] is missing from /etc/pacman.conf. Omarchy's pacman template enables it; this script will not invent a repository block."
  fi
  log "enabling the commented [multilib] section"
  if [[ $DRY_RUN -eq 1 ]]; then
    changed "enable [multilib] in /etc/pacman.conf and pacman -Sy"
    return 0
  fi
  tmp=$(mktemp)
  awk '
    BEGIN { state = 0 }
    state == 0 && /^[[:space:]]*#[[:space:]]*\[multilib\][[:space:]]*$/ {
      print "[multilib]"
      state = 1
      next
    }
    state == 1 && /^[[:space:]]*#[[:space:]]*Include[[:space:]]*=/ {
      sub(/^[[:space:]]*#[[:space:]]*/, "")
      print
      state = 2
      next
    }
    { print }
  ' /etc/pacman.conf >"$tmp"
  if ! grep -Eq '^\[multilib\]$' "$tmp"; then
    rm -f "$tmp"
    die "failed to uncomment [multilib]"
  fi
  if [[ ! -f /etc/pacman.conf.bak.omarchy-playbook ]]; then
    sudo cp -a /etc/pacman.conf /etc/pacman.conf.bak.omarchy-playbook
  fi
  sudo install -m 644 "$tmp" /etc/pacman.conf
  rm -f "$tmp"
  sudo pacman -Sy --noconfirm
  changed "enabled [multilib]"
}

step_packages() {
  step "Packages"
  pkg_add geeqie
  ensure_multilib

  # Steam: bin/omarchy-install-gaming-steam installs lib32 drivers first
  # (bin/omarchy-install-gaming-gpu-lib32, which is what pulls multilib
  # packages for the detected GPUs) then `omarchy pkg add steam`. That
  # command also launches the Steam GUI. This step uses the same package
  # commands and skips the launch so a re-run stays quiet.
  if pkg_installed steam; then
    log "steam already installed"
  else
    log "installing lib32 GPU drivers, then steam"
    run omarchy install gaming gpu-lib32
    run omarchy pkg add steam
    changed "installed steam"
  fi

  pkg_add nvidia-prime

  # vlc is optional. Uncomment the next line to install it.
  # pkg_add vlc
  log "vlc left uninstalled (optional; uncomment pkg_add vlc in step_packages)"
}

step_mpv() {
  step "mpv hardware decoding"
  # Keep VA-API on the Intel iGPU. default/hypr/nvidia.lua on quattro sets
  # LIBVA_DRIVER_NAME=nvidia only when NVIDIA drives the display, which it
  # does not on this hybrid laptop. hwdec=vaapi is the player-side match.
  if [[ -f $MPV_CONF ]] && grep -Eq '^[[:space:]]*hwdec=vaapi[[:space:]]*(#.*)?$' "$MPV_CONF"; then
    log "hwdec=vaapi already set in $MPV_CONF"
    return 0
  fi
  ensure_line "$MPV_CONF" "hwdec=vaapi"
}

step_default_apps() {
  step "Default apps for Sony RAW"
  local desktop mime current
  desktop="/usr/share/applications/$GEEQIE_DESKTOP"
  if [[ ! -f $desktop ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log "would set Sony RAW defaults to $GEEQIE_DESKTOP after geeqie is installed"
      changed "xdg-mime default $GEEQIE_DESKTOP for Sony RAW types"
      return 0
    fi
    die "missing $desktop. geeqie did not install the expected desktop file."
  fi
  for mime in image/x-sony-arw image/x-sony-sr2 image/x-sony-srf; do
    current=$(xdg-mime query default "$mime" || true)
    if [[ $current == "$GEEQIE_DESKTOP" ]]; then
      log "$mime already opens with $GEEQIE_DESKTOP"
      continue
    fi
    run xdg-mime default "$GEEQIE_DESKTOP" "$mime"
    changed "default for $mime is $GEEQIE_DESKTOP"
  done
}

plugin_installed() {
  [[ -f $HOME/.config/omarchy/plugins/$1/manifest.json ]]
}

plugin_enabled() {
  local id=$1
  local json
  # bin/omarchy-plugin-list --json. For a bar widget, "enabled" means it is
  # in the bar (shell/shell.qml listPlugins).
  if ! json=$(omarchy plugin list --json 2>/dev/null); then
    return 1
  fi
  jq -e --arg id "$id" 'any(.[]; .id == $id and .enabled == true)' <<<"$json" >/dev/null
}

ensure_plugin() {
  local id=$1
  local url=$2
  local section=$3
  if ! plugin_installed "$id"; then
    # bin/omarchy-plugin-add: without --yes a non-interactive shell refuses.
    # --enable is available, but --yes skips the bar-section prompt, so enable
    # is a separate call that passes the manifest defaultSection.
    run omarchy plugin add "$url" --yes
    if [[ $DRY_RUN -eq 0 ]]; then
      plugin_installed "$id" || die "plugin $id was not installed from $url"
    fi
    changed "added plugin $id"
  else
    log "$id already installed"
  fi
  if plugin_enabled "$id"; then
    log "$id already enabled"
    return 0
  fi
  # setEnabled inserts a bar entry only when the widget is not already on the
  # bar (shell/services/PluginRegistry.qml), so a repeated enable does not
  # duplicate it. Checking first keeps the log quiet.
  run omarchy plugin enable "$id" --section "$section"
  changed "enabled plugin $id in section $section"
}

step_matrix_screensaver() {
  local bin settings_dir tmp
  bin="$HOME/.config/omarchy/plugins/$MATRIX_ID/bin/matrix-screens"
  if [[ -f $MATRIX_SETTINGS ]] && jq -e '.screensaver == true' "$MATRIX_SETTINGS" >/dev/null 2>&1; then
    log "Matrix Screens screensaver already on"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log "would turn the Matrix Screens screensaver on"
    changed "Matrix Screens screensaver on"
    return 0
  fi
  # The plugin CLI edits settings.json over IPC when the shell is up
  # (WhiskeyTangoFussell/omarchy-matrix-screens bin/matrix-screens).
  # The same file is the source of truth when the shell is not running.
  if [[ -x $bin ]] && "$bin" screensaver on; then
    changed "Matrix Screens screensaver on"
    return 0
  fi
  settings_dir=$(dirname "$MATRIX_SETTINGS")
  mkdir -p "$settings_dir"
  tmp=$(mktemp)
  if [[ -f $MATRIX_SETTINGS ]]; then
    jq -e 'type == "object"' "$MATRIX_SETTINGS" >/dev/null || die "$MATRIX_SETTINGS is not a JSON object"
    jq '.screensaver = true' "$MATRIX_SETTINGS" >"$tmp"
  else
    printf '%s\n' '{"screensaver":true}' >"$tmp"
  fi
  mv -f "$tmp" "$MATRIX_SETTINGS"
  changed "set screensaver true in $MATRIX_SETTINGS"
}

step_plugins() {
  step "Omarchy plugins"
  ensure_plugin "$MATRIX_ID" "$MATRIX_URL" "$MATRIX_SECTION"
  step_matrix_screensaver
  ensure_plugin "$PULSE_ID" "$PULSE_URL" "$PULSE_SECTION"
}

step_rawmakase() {
  step "RAWmakase"
  local api tag asset_name asset_url sums_url work count installed installed_ver pacman_status
  # README also documents `omarchy pkg add rawmakase-bin` for Omarchy.
  # This step follows the requested GitHub release .pkg.tar.zst path.
  # If the Omarchy -bin package is already installed, leave it: the two
  # packages would conflict.
  if pkg_installed rawmakase-bin; then
    log "rawmakase-bin is already installed via Omarchy. Leaving it in place."
    return 0
  fi
  if [[ $(uname -m) != "x86_64" ]]; then
    die "this step installs the x86_64 .pkg.tar.zst. This machine is $(uname -m)."
  fi
  require_cmd curl
  require_cmd jq
  require_cmd sha256sum
  api=$(curl -fsSL "https://api.github.com/repos/pch/rawmakase/releases/latest")
  tag=$(jq -r '.tag_name' <<<"$api")
  [[ $tag == v* ]] || die "unexpected RAWmakase release tag: $tag"
  asset_name=$(jq -r '.assets[].name | select(endswith("-x86_64.pkg.tar.zst"))' <<<"$api")
  count=$(printf '%s\n' "$asset_name" | grep -c . || true)
  [[ $count -eq 1 ]] || die "expected one x86_64 package in $tag, found ${count:-0}"
  asset_url=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$api")
  sums_url=$(jq -r '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' <<<"$api")
  [[ -n $asset_url && $asset_url != null ]] || die "release $tag has no package URL"
  [[ -n $sums_url && $sums_url != null ]] || die "release $tag has no SHA256SUMS"
  if pkg_installed rawmakase; then
    installed=$(pacman -Q rawmakase)
    installed_ver=${installed#* }
    installed_ver=${installed_ver%-*}
    if [[ $installed_ver == "${tag#v}" ]]; then
      log "rawmakase $installed_ver already matches $tag"
      return 0
    fi
    log "installed rawmakase is $installed_ver; latest release is $tag"
  fi
  log "release $tag: $asset_name"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "would verify SHA256SUMS and sudo pacman -U $asset_name"
    changed "install RAWmakase $tag from the GitHub release"
    return 0
  fi
  work=$(mktemp -d)
  if ! curl -fsSL --output "$work/$asset_name" "$asset_url" ||
    ! curl -fsSL --output "$work/SHA256SUMS" "$sums_url"; then
    rm -rf -- "$work"
    die "failed to download $tag"
  fi
  if ! grep -F -- "$asset_name" "$work/SHA256SUMS" >/dev/null; then
    rm -rf -- "$work"
    die "SHA256SUMS does not list $asset_name"
  fi
  if ! (
    cd "$work"
    sha256sum --ignore-missing -c SHA256SUMS
  ); then
    rm -rf -- "$work"
    die "SHA256SUMS did not match $asset_name"
  fi
  pacman_status=0
  sudo pacman -U --noconfirm -- "$work/$asset_name" || pacman_status=$?
  rm -rf -- "$work"
  [[ $pacman_status -eq 0 ]] || die "pacman -U failed for $asset_name"
  changed "installed RAWmakase $tag with pacman -U after SHA256SUMS"
}

step_bindings() {
  step "Hyprland keybindings"
  # config/hypr/bindings.lua is the Quattro user file, loaded after the defaults.
  # o.bind adds a key. o.rebind (default/hypr/helpers.lua) unbinds first, which
  # is required for SUPER+SHIFT+A (ChatGPT) and SUPER+SHIFT+ALT+A (Grok web app).
  # fullscreen 1 is Hyprland's maximize mode. This file is Lua, not bind= lines.
  local dir wrote
  local -a grok=()
  local -a managed=()
  grok=("$GROK_WEB_LINE")
  if command -v grok-bot >/dev/null 2>&1; then
    grok=("$GROK_BOT_COMMENT" "$GROK_BOT_LINE" "$GROK_WEB_LINE")
  elif [[ -f $BINDINGS ]] && grep -qxF -- "$GROK_BOT_LINE" "$BINDINGS"; then
    log "grok-bot is not on PATH. Leaving the existing Grok Bot rebind in $BINDINGS."
  else
    log "grok-bot is not on PATH. Skipping the SUPER + SHIFT + ALT + A rebind."
  fi
  managed=("$BIND_LINE" "$GROK_BOT_COMMENT" "$GROK_BOT_LINE" "$GROK_WEB_LINE")

  if bindings_satisfied "$BIND_LINE" "${grok[@]}"; then
    if has_duplicate_managed_lines "$BINDINGS" "${managed[@]}"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log "would back up $BINDINGS and remove duplicate binding lines"
      else
        backup_file "$BINDINGS"
        dedupe_managed_lines "$BINDINGS" "${managed[@]}"
        changed "removed duplicate bindings in $BINDINGS"
      fi
      HYPR_RELOAD=1
      maybe_reload_hyprland
      return 0
    fi
    log "bindings already present in $BINDINGS"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ -f $BINDINGS ]]; then
      log "would back up $BINDINGS"
    else
      log "would create $BINDINGS"
    fi
    log_missing_bindings "$BIND_LINE"
    log_missing_bindings "${grok[@]}"
    changed "Hyprland bindings in $BINDINGS"
    HYPR_RELOAD=1
    maybe_reload_hyprland
    return 0
  fi

  dir=$(dirname "$BINDINGS")
  mkdir -p -- "$dir"
  wrote=0
  if [[ -f $BINDINGS ]]; then
    backup_file "$BINDINGS"
    if dedupe_managed_lines "$BINDINGS" "${managed[@]}"; then
      changed "removed duplicate bindings in $BINDINGS"
      wrote=1
    fi
  else
    printf '%s\n' "-- Personal bindings. Loaded after Omarchy defaults." >"$BINDINGS"
    wrote=1
  fi
  if append_new_lines "$BINDINGS" "$BIND_LINE"; then
    changed "added SUPER + ALT + F in $BINDINGS"
    wrote=1
  fi
  if append_new_lines "$BINDINGS" "${grok[@]}"; then
    changed "added Grok bindings in $BINDINGS"
    wrote=1
  fi
  if [[ $wrote -eq 1 ]]; then
    HYPR_RELOAD=1
  fi
  maybe_reload_hyprland
}

bindings_satisfied() {
  local line
  [[ -f $BINDINGS ]] || return 1
  for line in "$@"; do
    grep -qxF -- "$line" "$BINDINGS" || return 1
  done
}

log_missing_bindings() {
  local line
  for line in "$@"; do
    if [[ -f $BINDINGS ]] && grep -qxF -- "$line" "$BINDINGS"; then
      continue
    fi
    log "would append to $BINDINGS: $line"
  done
}

backup_file() {
  local file=$1
  local bak stamp
  [[ -f $file ]] || return 0
  stamp=$(date +%Y%m%d-%H%M%S)
  bak="${file}.bak.${stamp}"
  if [[ -e $bak ]]; then
    bak="${bak}.$$"
  fi
  cp -a -- "$file" "$bak"
  log "backed up $file to $bak"
}

has_duplicate_managed_lines() {
  local file=$1
  shift
  local line want managed
  local -A seen=()
  [[ -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    managed=0
    for want in "$@"; do
      if [[ $line == "$want" ]]; then
        managed=1
        break
      fi
    done
    if [[ $managed -eq 1 ]]; then
      if [[ -n ${seen[$line]+x} ]]; then
        return 0
      fi
      seen[$line]=1
    fi
  done <"$file"
  return 1
}

dedupe_managed_lines() {
  local file=$1
  shift
  local tmp line want managed changed
  local -A seen=()
  changed=0
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    managed=0
    for want in "$@"; do
      if [[ $line == "$want" ]]; then
        managed=1
        break
      fi
    done
    if [[ $managed -eq 1 ]]; then
      if [[ -n ${seen[$line]+x} ]]; then
        changed=1
        continue
      fi
      seen[$line]=1
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  if [[ $changed -eq 1 ]]; then
    mv -f -- "$tmp" "$file"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

append_new_lines() {
  local file=$1
  shift
  local line
  local -a missing=()
  for line in "$@"; do
    if [[ -f $file ]] && grep -qxF -- "$line" "$file"; then
      log "already present in $file: $line"
      continue
    fi
    missing+=("$line")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 1
  fi
  {
    printf '\n'
    printf '%s\n' "${missing[@]}"
  } >>"$file"
  return 0
}

hyprland_is_running() {
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    return 0
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -x Hyprland >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

maybe_reload_hyprland() {
  if [[ $HYPR_RELOAD -eq 0 ]]; then
    return 0
  fi
  if ! hyprland_is_running; then
    log "Hyprland is not running. Bindings apply on the next login."
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run: would run hyprctl reload"
    return 0
  fi
  if ! command -v hyprctl >/dev/null 2>&1; then
    log "hyprctl is not on PATH. Bindings apply on the next login."
    return 0
  fi
  if hyprctl reload; then
    HYPR_RELOADED=1
    changed "reloaded Hyprland"
  else
    log "WARNING: hyprctl reload failed. $BINDINGS was still updated."
  fi
}

partition_field() {
  local field=$1
  local dev=$2
  lsblk -no "$field" "$dev" 2>/dev/null | awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' || true
}

partition_fstype() {
  partition_field FSTYPE "$1"
}

partition_label() {
  partition_field LABEL "$1"
}

partition_type() {
  partition_field TYPE "$1"
}

partition_pkname() {
  partition_field PKNAME "$1"
}

partition_uuid() {
  local dev=$1
  local uuid attempt
  for attempt in 1 2; do
    uuid=$(blkid -c /dev/null -o value -s UUID -- "$dev" 2>/dev/null | awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' || true)
    if [[ -z $uuid ]] && sudo -n true 2>/dev/null; then
      uuid=$(sudo -n blkid -c /dev/null -o value -s UUID -- "$dev" 2>/dev/null | awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' || true)
    fi
    if [[ -n $uuid ]]; then
      break
    fi
    if [[ $attempt -eq 1 ]] && command -v udevadm >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo -n udevadm settle || true
    fi
  done
  printf '%s\n' "$uuid"
}

data_disk_name() {
  local path=$DATA_PART
  local base
  if [[ -e $path ]]; then
    path=$(readlink -f -- "$path")
  fi
  base=${path##*/}
  if [[ $base =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ $base =~ ^(mmcblk[0-9]+)p[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

refuse_protected_mount() {
  local part=$1
  local target
  while IFS= read -r target; do
    [[ -n $target ]] || continue
    case $target in
      / | /boot | /boot/* | /efi | /efi/* | /home | /home/*)
        die "refusing to change $part because it is mounted at $target"
        ;;
    esac
  done < <(findmnt -nro TARGET -- "$part" 2>/dev/null || true)
}

refuse_small_data_partition() {
  local size
  size=$(lsblk -bno SIZE "$DATA_PART" 2>/dev/null | awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' || true)
  if [[ ! $size =~ ^[0-9]+$ ]]; then
    die "could not read the size of $DATA_PART. Not formatting it."
  fi
  # nvme1n1p1 is 1M and nvme1n1p2 is 15M. The Data partition is about 1.8T.
  if ((size < 1073741824)); then
    die "$DATA_PART is only ${size} bytes. Refusing to format a small partition."
  fi
}

validate_data_partition() {
  local type pk expected
  type=$(partition_type "$DATA_PART")
  [[ $type == part ]] || die "$DATA_PART is not a partition (lsblk TYPE=${type:-unknown}). Refusing to change it."
  if ! expected=$(data_disk_name); then
    die "could not derive the parent disk from $DATA_PART"
  fi
  pk=$(partition_pkname "$DATA_PART")
  [[ -n $pk ]] || die "could not read the parent disk of $DATA_PART. Refusing to change it."
  [[ $pk == "$expected" ]] || die "$DATA_PART parent is '$pk', not $expected. Refusing to change it."
  [[ $pk != nvme0n1 ]] || die "refusing to change a partition of nvme0n1, the encrypted OS disk"
  refuse_protected_mount "$DATA_PART"
}

filesystem_is_ntfs() {
  local fstype=${1,,}
  [[ $fstype == ntfs || $fstype == ntfs3 ]]
}

mount_options_have_subvol() {
  local target=$1
  local name=$2
  local opts
  opts=$(findmnt -nro OPTIONS -- "$target" 2>/dev/null || true)
  case ,$opts, in
    *",subvol=/${name},"* | *",subvol=${name},"*) return 0 ;;
  esac
  return 1
}

subvolume_listed_at() {
  local target=$1
  local name=$2
  local listed
  command -v btrfs >/dev/null 2>&1 || return 1
  listed=$(btrfs subvolume list -- "$target" 2>/dev/null || true)
  [[ -n $listed ]] || return 1
  awk -v n="$name" '$NF == n { found = 1 } END { exit found ? 0 : 1 }' <<<"$listed"
}

probe_subvolume_readonly() {
  local name=$1
  local tmp found
  found=1
  tmp=$(mktemp -d)
  if ! sudo mount -o ro,subvolid=5 -- "$DATA_PART" "$tmp" 2>/dev/null; then
    if ! sudo mount -o ro -- "$DATA_PART" "$tmp" 2>/dev/null; then
      rmdir -- "$tmp" || true
      return 1
    fi
  fi
  if [[ -d $tmp/$name ]] || subvolume_listed_at "$tmp" "$name"; then
    found=0
  fi
  sudo umount "$tmp" || true
  rmdir -- "$tmp" || true
  return "$found"
}

data_has_subvolume() {
  local name=$1
  local target
  if mount_options_have_subvol "$DATA_MOUNT" "$name"; then
    return 0
  fi
  while IFS= read -r target; do
    [[ -n $target ]] || continue
    if mount_options_have_subvol "$target" "$name"; then
      return 0
    fi
    if subvolume_listed_at "$target" "$name"; then
      return 0
    fi
  done < <(findmnt -nro TARGET -- "$DATA_PART" 2>/dev/null || true)
  # Dry-run does not mount. A stub can answer `btrfs subvolume list <dev>`.
  if subvolume_listed_at "$DATA_PART" "$name"; then
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    return 1
  fi
  probe_subvolume_readonly "$name"
}

fstab_has_mount() {
  local mount=$1
  local file=$2
  [[ -f $file ]] || return 1
  awk -v m="$mount" '
    /^[[:space:]]*#/ { next }
    {
      for (i = 1; i <= NF; i++) if ($i == m) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

fstab_mount_has_subvol() {
  local mount=$1
  local file=$2
  local needle="subvol=/${DATA_SUBVOL}"
  awk -v m="$mount" -v needle="$needle" '
    /^[[:space:]]*#/ { next }
    {
      hit = 0
      for (i = 1; i <= NF; i++) if ($i == m) hit = 1
      if (hit && index($0, needle) > 0) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

data_fstab_line() {
  printf 'UUID=%s  %s  btrfs  %s  0 0' "$1" "$DATA_MOUNT" "$FSTAB_OPTIONS"
}

ensure_data_bookmark() {
  local file uri line
  file=$GTK_BOOKMARKS
  uri="file://${DATA_MOUNT}"
  line="$uri $DATA_LABEL"
  if [[ -f $file ]] && grep -qxF -- "$line" "$file"; then
    log "bookmark already present in $file"
    return 0
  fi
  if [[ -f $file ]] && awk -v uri="$uri" '$1 == uri { found = 1 } END { exit found ? 0 : 1 }' "$file"; then
    log "a bookmark for $uri is already in $file. Not adding a second one."
    return 0
  fi
  ensure_line "$file" "$line"
}

ensure_data_mount() {
  local uuid line owner
  command -v blkid >/dev/null 2>&1 || die "blkid is required to read the UUID of $DATA_PART"
  uuid=$(partition_uuid "$DATA_PART")
  [[ -n $uuid ]] || die "could not read a UUID for $DATA_PART via blkid"
  line=$(data_fstab_line "$uuid")

  run sudo mkdir -p -- "$DATA_MOUNT"

  if fstab_has_mount "$DATA_MOUNT" "$FSTAB_FILE"; then
    log "fstab already has an entry for $DATA_MOUNT"
    if ! fstab_mount_has_subvol "$DATA_MOUNT" "$FSTAB_FILE"; then
      log "WARNING: the existing $DATA_MOUNT line does not set subvol=/${DATA_SUBVOL}. Not changing it."
    fi
  elif [[ $DRY_RUN -eq 1 ]]; then
    log "would append to $FSTAB_FILE: $line"
    changed "fstab entry for $DATA_MOUNT"
  else
    printf '%s\n' "$line" | sudo tee -a "$FSTAB_FILE" >/dev/null
    changed "added fstab entry for $DATA_MOUNT"
  fi

  run sudo systemctl daemon-reload
  if findmnt -M "$DATA_MOUNT" >/dev/null 2>&1; then
    log "$DATA_MOUNT is already mounted"
  else
    run sudo mount -- "$DATA_MOUNT"
    changed "mounted $DATA_MOUNT"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    run sudo chown "$USER:$USER" -- "$DATA_MOUNT"
  else
    owner=$(stat -c '%U:%G' -- "$DATA_MOUNT" 2>/dev/null || true)
    if [[ $owner == "$USER:$USER" ]]; then
      log "$DATA_MOUNT already owned by $USER"
    else
      sudo chown "$USER:$USER" -- "$DATA_MOUNT"
      changed "chown $USER:$USER $DATA_MOUNT"
    fi
  fi
  ensure_data_bookmark
}

mount_and_create_subvolume() {
  local dev=$1
  local tmp
  tmp=$(mktemp -d)
  # Top-level tree (subvolid 5) so @data is created at the filesystem root.
  # `btrfs subvolume create @data` is the same command with this directory as cwd.
  if sudo mount -o subvolid=5 -- "$dev" "$tmp"; then
    :
  elif sudo mount -- "$dev" "$tmp"; then
    :
  else
    rmdir -- "$tmp" || true
    die "could not mount $dev to create $DATA_SUBVOL"
  fi
  if [[ -d $tmp/$DATA_SUBVOL ]]; then
    log "$DATA_SUBVOL already exists on $dev"
  elif sudo btrfs subvolume create -- "$tmp/$DATA_SUBVOL"; then
    log "created $DATA_SUBVOL with: btrfs subvolume create @data"
    changed "created subvolume $DATA_SUBVOL on $dev"
  else
    sudo umount "$tmp" || true
    rmdir -- "$tmp" || true
    die "btrfs subvolume create @data failed on $dev"
  fi
  if ! sudo umount "$tmp"; then
    die "could not unmount $tmp after creating $DATA_SUBVOL"
  fi
  rmdir -- "$tmp" || log "WARNING: could not remove $tmp"
}

create_missing_data_subvolume() {
  log "$DATA_PART is already Btrfs labeled $DATA_LABEL. Not running mkfs."
  log "Creating the missing $DATA_SUBVOL subvolume. This does not erase the filesystem."
  if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run: would mount $DATA_PART, run 'btrfs subvolume create @data', and unmount"
    changed "create subvolume $DATA_SUBVOL on $DATA_PART"
    return 0
  fi
  command -v btrfs >/dev/null 2>&1 || die "btrfs is not installed (btrfs-progs)"
  mount_and_create_subvolume "$DATA_PART"
}

step_reformat_data() {
  local fstype=$1
  local label=$2
  local answer mounts
  fstype=${fstype,,}
  step "Reformat NTFS Data partition"
  log "********************************************************************"
  log "* DATA LOSS: this step destroys every file on $DATA_PART."
  log "* The filesystem (${fstype:-unknown}, label '${label:-none}') is"
  log "* replaced by a new empty Btrfs volume labeled $DATA_LABEL."
  log "* Subvolume: $DATA_SUBVOL. Mount: $DATA_MOUNT."
  log "* Options: $FSTAB_OPTIONS."
  log "* There is no recovery after mkfs.btrfs runs."
  log "********************************************************************"

  if [[ $fstype == crypto_luks || $fstype == lvm2_member ]]; then
    die "$DATA_PART is $fstype. Refusing to format it."
  fi
  if ! filesystem_is_ntfs "$fstype"; then
    die "$DATA_PART filesystem is '${fstype:-unknown}', not NTFS. Refusing to format it."
  fi
  refuse_small_data_partition

  if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run: would require the typed confirmation '$DATA_CONFIRM'"
    log "dry-run: would umount $DATA_PART if mounted, then mkfs.btrfs -f -L $DATA_LABEL $DATA_PART"
    log "dry-run: would mount it, run 'btrfs subvolume create @data', and unmount"
    log "dry-run: would read the new UUID with blkid and append the $DATA_MOUNT fstab line ($FSTAB_OPTIONS)"
    changed "reformat $DATA_PART from NTFS to Btrfs labeled $DATA_LABEL with subvolume $DATA_SUBVOL"
    DATA_READY=1
    return 0
  fi

  if [[ ! -b $DATA_PART ]]; then
    die "$DATA_PART is not a block device. Nothing was formatted."
  fi
  command -v mkfs.btrfs >/dev/null 2>&1 || die "mkfs.btrfs is not installed (btrfs-progs)"
  command -v btrfs >/dev/null 2>&1 || die "btrfs is not installed (btrfs-progs)"
  if [[ ! -r /dev/tty ]]; then
    die "the reformat needs a terminal so the confirmation can be typed."
  fi
  printf 'Type %s to destroy %s: ' "$DATA_CONFIRM" "$DATA_PART" >/dev/tty
  IFS= read -r answer </dev/tty || true
  if [[ $answer != "$DATA_CONFIRM" ]]; then
    die "confirmation did not match. $DATA_PART was not formatted."
  fi

  fstype=$(partition_fstype "$DATA_PART")
  fstype=${fstype,,}
  if ! filesystem_is_ntfs "$fstype"; then
    die "$DATA_PART changed while waiting (now '${fstype:-unknown}'). Not formatting it."
  fi
  refuse_protected_mount "$DATA_PART"
  refuse_small_data_partition
  mounts=$(findmnt -nro TARGET -- "$DATA_PART" || true)
  if [[ -n $mounts ]]; then
    log "unmounting $DATA_PART ($mounts)"
    sudo umount "$DATA_PART"
  fi
  sudo mkfs.btrfs -f -L "$DATA_LABEL" -- "$DATA_PART"
  changed "formatted $DATA_PART as Btrfs labeled $DATA_LABEL"
  mount_and_create_subvolume "$DATA_PART"
  ensure_data_mount
  DATA_READY=1
}

step_data_drive() {
  local fstype label part_type
  step "Data drive (${DATA_PART} -> ${DATA_MOUNT})"
  DATA_READY=0
  command -v lsblk >/dev/null 2>&1 || die "lsblk is required to identify $DATA_PART"
  case $(basename -- "$DATA_PART") in
    nvme1n1p1 | nvme1n1p2)
      die "$DATA_PART is a leftover Windows partition and is left untouched."
      ;;
  esac

  fstype=$(partition_fstype "$DATA_PART")
  label=$(partition_label "$DATA_PART")
  part_type=$(partition_type "$DATA_PART")
  fstype=${fstype,,}

  if [[ -z $part_type && -z $fstype ]]; then
    if [[ $REFORMAT_DATA -eq 1 ]]; then
      die "$DATA_PART is not visible to lsblk. Nothing was formatted."
    fi
    log "WARNING: $DATA_PART is not visible to lsblk. Skipping the Data drive. Nothing was formatted."
    return 0
  fi
  validate_data_partition
  if [[ -z $fstype ]]; then
    if [[ $REFORMAT_DATA -eq 0 ]]; then
      log "WARNING: $DATA_PART has no filesystem."
      log "Skipping the Data drive. Nothing was formatted. --reformat-data only replaces NTFS."
      return 0
    fi
    die "$DATA_PART has no filesystem, not NTFS. Refusing to format it."
  fi

  if [[ $fstype == btrfs && $label == "$DATA_LABEL" ]]; then
    if data_has_subvolume "$DATA_SUBVOL"; then
      log "$DATA_PART is Btrfs labeled $DATA_LABEL with subvolume $DATA_SUBVOL."
      if [[ $REFORMAT_DATA -eq 1 ]]; then
        log "Layout already matches. Not formatting again."
      fi
      ensure_data_mount
      DATA_READY=1
      return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      log "dry-run: $DATA_PART is Btrfs labeled $DATA_LABEL, but $DATA_SUBVOL was not listed without mounting."
      log "dry-run: a real run mounts it read-only to look for the subvolume and does not format when that subvolume is there."
      if [[ $REFORMAT_DATA -eq 0 ]]; then
        log "dry-run: if $DATA_SUBVOL is missing, the Data drive is skipped with a warning. Nothing would be formatted."
      else
        log "dry-run: if $DATA_SUBVOL is missing, --reformat-data would create it and would not run mkfs."
      fi
      log "dry-run: the ${DATA_MOUNT} mount and the Steam library step run only after ${DATA_SUBVOL} is confirmed."
      return 0
    fi
    if [[ $REFORMAT_DATA -eq 0 ]]; then
      log "WARNING: $DATA_PART is Btrfs labeled $DATA_LABEL but has no $DATA_SUBVOL subvolume."
      log "Skipping the Data drive. Nothing was formatted. Pass --reformat-data to create the subvolume without erasing the filesystem."
      return 0
    fi
    create_missing_data_subvolume
    ensure_data_mount
    DATA_READY=1
    return 0
  fi

  if [[ $REFORMAT_DATA -eq 0 ]]; then
    log "WARNING: $DATA_PART filesystem is '${fstype:-unknown}', label '${label:-none}'."
    log "It is not Btrfs labeled $DATA_LABEL with subvolume $DATA_SUBVOL."
    log "Skipping the Data drive. Nothing was formatted. Pass --reformat-data to erase an NTFS filesystem on it and create the Data volume."
    return 0
  fi
  step_reformat_data "$fstype" "$label"
}

note_steam_library_manual() {
  log "Add ${DATA_MOUNT}/SteamLibrary in Steam > Settings > Storage and make it the default."
  log "This script does not write a new libraryfolders.vdf entry."
}

steam_is_running() {
  if command -v pgrep >/dev/null 2>&1 && pgrep -x steam >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

rewrite_steam_library_path() {
  local file=$1
  local old=$2
  local new=$3
  local tmp
  command -v python3 >/dev/null 2>&1 || die "python3 is required to edit $file"
  tmp=$(mktemp)
  OLD_PATH="$old" NEW_PATH="$new" python3 - "$file" "$tmp" <<'PY'
import os
import pathlib
import sys

src, dst = sys.argv[1:]
text = pathlib.Path(src).read_text()
old = os.environ["OLD_PATH"]
new = os.environ["NEW_PATH"]
if old not in text:
    raise SystemExit(1)
pathlib.Path(dst).write_text(text.replace(old, new))
PY
  chmod --reference="$file" "$tmp"
  mv -f -- "$tmp" "$file"
}

step_steam_library() {
  local lib apps old new vdf bak
  step "Steam library on ${DATA_MOUNT}"
  lib="${DATA_MOUNT}/SteamLibrary"
  apps="${lib}/steamapps"
  old="/run/media/${USER}/Data/SteamLibrary"
  new=$lib
  vdf=$STEAM_LIBRARY_VDF

  if [[ $DATA_READY -ne 1 ]]; then
    log "Skipped. ${DATA_MOUNT} is not the Data drive, so the Steam library was not created."
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run: would mkdir -p $apps"
    log "dry-run: would chown $USER:$USER $lib $apps"
  elif [[ -d $apps ]]; then
    log "$apps already exists"
  else
    mkdir -p -- "$apps"
    changed "created $apps"
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    if ! chown "$USER:$USER" -- "$lib" "$apps"; then
      sudo chown "$USER:$USER" -- "$lib" "$apps"
    fi
  fi

  if [[ ! -f $vdf ]]; then
    log "No Steam libraryfolders.vdf at $vdf."
    note_steam_library_manual
    return 0
  fi

  if steam_is_running; then
    log "Steam is running, so $vdf was not changed."
    if grep -qF -- "$new" "$vdf"; then
      log "$new is already in $vdf."
    else
      if grep -qF -- "$old" "$vdf"; then
        log "Quit Steam and run ./post-install.sh again to rewrite $old to $new."
      fi
      note_steam_library_manual
    fi
    return 0
  fi

  if grep -qF -- "$old" "$vdf"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log "dry-run: would back up $vdf and replace $old with $new"
      changed "rewrite Steam library path $old to $new"
    else
      bak="${vdf}.bak.$(date +%Y%m%d-%H%M%S)"
      if [[ -e $bak ]]; then
        bak="${bak}.$$"
      fi
      cp -a -- "$vdf" "$bak"
      log "backed up $vdf to $bak"
      rewrite_steam_library_path "$vdf" "$old" "$new"
      changed "rewrote Steam library path $old to $new"
    fi
  fi

  if grep -qF -- "$new" "$vdf"; then
    log "Steam library path $new is present"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]] && grep -qF -- "$old" "$vdf"; then
    log "Steam library path $new would be present after the rewrite"
    return 0
  fi
  note_steam_library_manual
}

reboot_reason() {
  local marker running dir kernel seen match
  marker="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/reboot-required"
  if [[ -f $marker ]]; then
    printf '%s\n' "Omarchy recorded $marker"
    return 0
  fi
  # Same idea as bin/omarchy-update-restart: a kernel package whose modules
  # are not the running kernel means the update wants a reboot.
  running=$(uname -r)
  seen=0
  match=0
  for dir in /usr/lib/modules/*; do
    [[ -f $dir/modules.builtin ]] || continue
    pacman -Qo "$dir/modules.builtin" >/dev/null 2>&1 || continue
    seen=1
    kernel=$(basename "$dir")
    if [[ $kernel == "$running" ]]; then
      match=1
      break
    fi
  done
  if [[ $seen -eq 1 && $match -eq 0 ]]; then
    printf '%s\n' "running kernel $running has no matching installed module tree"
    return 0
  fi
  return 1
}

step_summary() {
  local reason item
  step "Summary"
  if [[ ${#CHANGES[@]} -eq 0 ]]; then
    log "No changes."
  else
    log "Changes:"
    for item in "${CHANGES[@]}"; do
      log "  - $item"
    done
  fi
  if [[ $HYPR_RELOAD -eq 1 ]]; then
    if [[ $HYPR_RELOADED -eq 1 ]]; then
      log "Hyprland reload: hyprctl reload ran. A reboot is not required for bindings.lua."
    elif [[ $DRY_RUN -eq 1 ]]; then
      log "Hyprland reload: dry-run did not reload. A reboot is not required for bindings.lua."
    else
      log "Hyprland reload: bindings.lua changed. Hyprland was not reloaded. A reboot is not required for that file."
    fi
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log "Reboot: not evaluated. omarchy update -y reports one when a real run needs it."
    return 0
  fi
  if reason=$(reboot_reason); then
    log "Reboot: yes. $reason"
    log "When you are ready: omarchy-system reboot"
  else
    log "Reboot: no marker and the running kernel matches an installed module tree."
  fi
}

main() {
  local arg
  for arg in "$@"; do
    case $arg in
      --dry-run) DRY_RUN=1 ;;
      --reformat-data) REFORMAT_DATA=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $arg"
        ;;
    esac
  done

  if [[ ${EUID} -eq 0 ]]; then
    die "Refusing to run as root. Run as the Omarchy user; sudo is used where needed."
  fi

  require_cmd sudo

  mkdir -p "$STATE_DIR"
  log ""
  log "==> post-install $(date -Is) dry_run=$DRY_RUN reformat_data=$REFORMAT_DATA"

  # Credential rotation is first. A machine still using the public default
  # must not wait on package commands before the password and passphrase change.
  step_rotate_credentials

  require_cmd omarchy
  require_cmd pacman
  require_cmd jq
  [[ -f /etc/pacman.conf ]] || die "/etc/pacman.conf is missing"

  step_update
  step_packages
  step_mpv
  step_default_apps
  step_plugins
  step_rawmakase
  step_bindings
  step_data_drive
  step_steam_library
  step_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
