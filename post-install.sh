#!/usr/bin/env bash
# Post-install playbook for this Omarchy machine (Quattro / 4.x).
# Idempotent: each step checks current state before it changes anything.
# Refuses to run as root. Uses sudo only for package, fstab, and format work.
#
# Sources for the Omarchy commands are cited next to the steps that call them.

set -euo pipefail

DRY_RUN=0
REFORMAT_DATA=0
HYPR_RELOAD=0

DATA_PART="/dev/nvme0n1p3"
DATA_LABEL="Data"
DATA_MOUNT="/mnt/data"
DATA_CONFIRM="WIPE /dev/nvme0n1p3"
FSTAB_OPTIONS="noatime,compress=zstd:3"

MATRIX_ID="io.github.whiskeytangofussell.matrixscreens"
MATRIX_URL="https://github.com/WhiskeyTangoFussell/omarchy-matrix-screens"
MATRIX_SECTION="right"
PULSE_ID="io.github.sanchokusika.pulse"
PULSE_URL="https://github.com/SanchoKusika/omarchy-pulse"
PULSE_SECTION="left"

GEEQIE_DESKTOP="org.geeqie.Geeqie.desktop"
MPV_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mpv/mpv.conf"
BINDINGS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
BIND_LINE='o.bind("SUPER + ALT + F", "Maximize", "hyprctl dispatch fullscreen 1")'
MATRIX_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/matrix-screens/settings.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-playbook"
LOG_FILE="$STATE_DIR/post-install.log"

CHANGES=()

usage() {
  cat <<'EOF'
Usage: ./post-install.sh [--dry-run] [--reformat-data]

  --dry-run         Print the actions. Do not change the system.
  --reformat-data   DESTRUCTIVE and off by default. Replace the NTFS
                    filesystem on /dev/nvme0n1p3 with Btrfs labeled Data.
                    Requires typing: WIPE /dev/nvme0n1p3
                    Ignored for execution when combined with --dry-run.

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
  step "Hyprland keybinding"
  # config/hypr/bindings.lua documents o.bind(keys, description, command).
  # default/hypr/helpers.lua function o.bind passes a string dispatcher to
  # hl.dsp.exec_cmd. fullscreen 1 is Hyprland's maximize mode.
  local dir
  dir=$(dirname "$BINDINGS")
  if [[ -f $BINDINGS ]] && grep -qxF -- "$BIND_LINE" "$BINDINGS"; then
    log "binding already present in $BINDINGS"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log "would append to $BINDINGS: $BIND_LINE"
    changed "Hyprland binding SUPER + ALT + F"
    HYPR_RELOAD=1
    return 0
  fi
  mkdir -p "$dir"
  if [[ ! -f $BINDINGS ]]; then
    printf '%s\n' "-- Personal bindings. Loaded after Omarchy defaults." >"$BINDINGS"
  fi
  printf '\n%s\n' "$BIND_LINE" >>"$BINDINGS"
  changed "added SUPER + ALT + F in $BINDINGS"
  HYPR_RELOAD=1
}

partition_fstype() {
  lsblk -no FSTYPE "$1" 2>/dev/null | awk 'NF { print; exit }'
}

partition_label() {
  lsblk -no LABEL "$1" 2>/dev/null | awk 'NF { print; exit }'
}

refuse_protected_mount() {
  local part=$1
  local target
  while IFS= read -r target; do
    [[ -n $target ]] || continue
    case $target in
      / | /boot | /boot/* | /efi | /efi/* | /home | /home/*)
        die "refusing to format $part because it is mounted at $target"
        ;;
    esac
  done < <(findmnt -nro TARGET "$part" 2>/dev/null || true)
}

ensure_data_fstab() {
  local uuid line
  uuid=$(lsblk -no UUID "$DATA_PART" | awk 'NF { print; exit }')
  [[ -n $uuid ]] || die "could not read a UUID for $DATA_PART"
  line="UUID=${uuid} ${DATA_MOUNT} btrfs ${FSTAB_OPTIONS} 0 0"
  if grep -Eq "^UUID=${uuid}[[:space:]]+${DATA_MOUNT}[[:space:]]+" /etc/fstab; then
    log "fstab already mounts $DATA_MOUNT from this UUID"
  elif grep -Eq "[[:space:]]${DATA_MOUNT}[[:space:]]" /etc/fstab; then
    die "/etc/fstab already has an entry for $DATA_MOUNT with a different source. Not adding another."
  elif [[ $DRY_RUN -eq 1 ]]; then
    log "would append to /etc/fstab: $line"
    changed "fstab entry for $DATA_MOUNT"
    return 0
  else
    printf '%s\n' "$line" | sudo tee -a /etc/fstab >/dev/null
    changed "added fstab entry for $DATA_MOUNT ($FSTAB_OPTIONS)"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  sudo mkdir -p "$DATA_MOUNT"
  if ! findmnt -M "$DATA_MOUNT" >/dev/null 2>&1; then
    sudo mount "$DATA_MOUNT"
  fi
  sudo chown "$USER:$USER" "$DATA_MOUNT"
}

step_reformat_data() {
  step "Reformat NTFS Data partition"
  local fstype label answer mounts
  log "********************************************************************"
  log "* DATA LOSS: this step destroys every file on $DATA_PART."
  log "* The NTFS filesystem is replaced by a new empty Btrfs volume."
  log "* Label: $DATA_LABEL. Mount: $DATA_MOUNT ($FSTAB_OPTIONS)."
  log "* There is no recovery after mkfs.btrfs runs."
  log "********************************************************************"

  if [[ ! -b $DATA_PART ]]; then
    die "$DATA_PART is not a block device on this machine. Nothing was formatted."
  fi
  if [[ $(lsblk -no TYPE "$DATA_PART" | awk 'NF { print; exit }') != "part" ]]; then
    die "$DATA_PART is not a partition. Refusing to format it."
  fi
  if [[ $(lsblk -no PKNAME "$DATA_PART" | awk 'NF { print; exit }') != "nvme0n1" ]]; then
    die "$DATA_PART is not a partition of nvme0n1. Refusing to format it."
  fi
  refuse_protected_mount "$DATA_PART"

  fstype=$(partition_fstype "$DATA_PART")
  label=$(partition_label "$DATA_PART")
  fstype=${fstype,,}
  if [[ $fstype == "btrfs" && $label == "$DATA_LABEL" ]]; then
    log "$DATA_PART is already Btrfs labeled $DATA_LABEL. Checking fstab only."
    ensure_data_fstab
    return 0
  fi
  if [[ $fstype != "ntfs" && $fstype != "ntfs3" ]]; then
    die "$DATA_PART filesystem is '${fstype:-unknown}', not NTFS. Refusing to format it."
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run: would require the typed confirmation '$DATA_CONFIRM'"
    log "dry-run: would umount $DATA_PART if mounted, then mkfs.btrfs -L $DATA_LABEL -f"
    changed "reformat $DATA_PART from NTFS to Btrfs"
    return 0
  fi

  if [[ ! -r /dev/tty ]]; then
    die "the reformat needs a terminal so the confirmation can be typed."
  fi
  printf 'Type %s to destroy %s: ' "$DATA_CONFIRM" "$DATA_PART" >/dev/tty
  IFS= read -r answer </dev/tty || true
  if [[ $answer != "$DATA_CONFIRM" ]]; then
    die "confirmation did not match. $DATA_PART was not formatted."
  fi

  # Re-check after the prompt. The device must still be the NTFS partition.
  fstype=$(partition_fstype "$DATA_PART")
  fstype=${fstype,,}
  if [[ $fstype != "ntfs" && $fstype != "ntfs3" ]]; then
    die "$DATA_PART changed while waiting (now '${fstype:-unknown}'). Not formatting it."
  fi
  refuse_protected_mount "$DATA_PART"
  mounts=$(findmnt -nro TARGET "$DATA_PART" || true)
  if [[ -n $mounts ]]; then
    log "unmounting $DATA_PART ($mounts)"
    sudo umount "$DATA_PART"
  fi
  command -v mkfs.btrfs >/dev/null 2>&1 || die "mkfs.btrfs is not installed"
  sudo mkfs.btrfs -L "$DATA_LABEL" -f -- "$DATA_PART"
  changed "formatted $DATA_PART as Btrfs labeled $DATA_LABEL"
  ensure_data_fstab
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
    log "Hyprland reload: the new binding is read on the next 'hyprctl reload' or login. A reboot is not required for that file."
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

  require_cmd omarchy
  require_cmd sudo
  require_cmd pacman
  require_cmd jq
  [[ -f /etc/pacman.conf ]] || die "/etc/pacman.conf is missing"

  mkdir -p "$STATE_DIR"
  log ""
  log "==> post-install $(date -Is) dry_run=$DRY_RUN reformat_data=$REFORMAT_DATA"

  step_update
  step_packages
  step_mpv
  step_default_apps
  step_plugins
  step_rawmakase
  step_bindings
  if [[ $REFORMAT_DATA -eq 1 ]]; then
    step_reformat_data
  else
    step "NTFS data partition"
    log "Skipped. Pass --reformat-data to reformat $DATA_PART. That flag destroys the filesystem on it."
  fi
  step_summary
}

main "$@"
