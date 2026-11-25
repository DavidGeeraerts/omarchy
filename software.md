# Additional software

| Software / package | What it is | How the post-install scripts add it | Script(s) |
| --- | --- | --- | --- |
| `geeqie` | Image viewer; set as the default opener for Sony ARW/SR2/SRF files | `omarchy pkg add geeqie` | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `anki` | Flashcard application | `omarchy pkg add anki` | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `flea` | GUI file manager; `flea --default` sets it as the default file manager and file chooser | `omarchy pkg add flea` | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `zulu-25-bin` | Azul Zulu JDK 25 (LTS). Needed for ThinkOrSwim, the Schwab trading platform (a Java app) | `omarchy pkg aur add zulu-25-bin` | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh), [XPS postflight](./postflight-Dell-XPS-17-9720.sh) |
| `steam` | Game client | Installs detected lib32 GPU drivers with `omarchy install gaming gpu-lib32`, then runs `omarchy pkg add steam` | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `nvidia-prime` | NVIDIA PRIME offloading utility (`prime-run`) | `omarchy pkg add nvidia-prime` | [XPS 17 9720](./post-install-dell-xps-17-9720.sh) only |
| `rawmakase` | Sony RAW photo workflow application | Downloads the latest x86_64 Arch package from GitHub, verifies it against `SHA256SUMS`, then installs it with `pacman -U`. Skips this if `rawmakase-bin` is already installed. | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| Matrix Screens | Omarchy bar plugin and screensaver | Adds and enables the Matrix Screens plugin; turns on its screensaver | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| Pulse | Omarchy bar plugin | Adds and enables the Pulse plugin | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `omarchy-agents-nostarters` | Local helper that replaces the Agents panel with a copy that omits its starter tiles | Copies the repository script to `~/.local/bin` and runs it | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |

Package installs are skipped when the package is already installed. `zulu-25-bin` is the AUR package: the scripts call `omarchy pkg aur add zulu-25-bin` and skip that when `pacman -Q zulu-25-bin` already succeeds. `--dry-run` prints the command and does not install it. The lib32 GPU driver packages are selected at runtime for the detected GPU, so their individual package names are not fixed in the scripts. VLC is optional and its install command is commented out.

[`post-install-omarchy-generic.sh`](./post-install-omarchy-generic.sh) is the hardware-agnostic baseline. Use it for any other Omarchy system, and when you want only the shared steps. It installs every package in the table above except `nvidia-prime`, and it drops `obsidian`. It does not update firmware, disable a touchscreen, mount a data drive, or set a Steam library path, a monitor, a scale, or a hostname.

## Removed packages

Omarchy installs these by default. The post-install scripts remove them after `omarchy update`. `omarchy pkg drop` removes a name only when it is installed (`sudo pacman -Rns --noconfirm`). `--dry-run` prints that command and does not remove the package. `omarchy update` may not install them again; the drop still runs on every post-install.

| Software / package | What it is | How the post-install scripts remove it | Script(s) |
| --- | --- | --- | --- |
| `obsidian` | Notes app from Arch extra | `omarchy pkg drop obsidian` when `pacman -Q obsidian` succeeds | [generic](./post-install-omarchy-generic.sh), [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh), [XPS postflight](./postflight-Dell-XPS-17-9720.sh) |
