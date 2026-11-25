# Additional software

| Software / package | What it is | How the post-install scripts add it | Script(s) |
| --- | --- | --- | --- |
| `geeqie` | Image viewer; set as the default opener for Sony ARW/SR2/SRF files | `omarchy pkg add geeqie` | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `anki` | Flashcard application | `omarchy pkg add anki` | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `flea` | GUI file manager; `flea --default` sets it as the default file manager and file chooser | `omarchy pkg add flea` | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `steam` | Game client | Installs detected lib32 GPU drivers with `omarchy install gaming gpu-lib32`, then runs `omarchy pkg add steam` | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `nvidia-prime` | NVIDIA PRIME offloading utility (`prime-run`) | `omarchy pkg add nvidia-prime` | [XPS 17 9720](./post-install-dell-xps-17-9720.sh) only |
| `rawmakase` | Sony RAW photo workflow application | Downloads the latest x86_64 Arch package from GitHub, verifies it against `SHA256SUMS`, then installs it with `pacman -U`. Skips this if `rawmakase-bin` is already installed. | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| Matrix Screens | Omarchy bar plugin and screensaver | Adds and enables the Matrix Screens plugin; turns on its screensaver | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| Pulse | Omarchy bar plugin | Adds and enables the Pulse plugin | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |
| `omarchy-agents-nostarters` | Local helper that replaces the Agents panel with a copy that omits its starter tiles | Copies the repository script to `~/.local/bin` and runs it | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh) |

Package installs are skipped when the package is already installed. The lib32 GPU driver packages are selected at runtime for the detected GPU, so their individual package names are not fixed in the scripts. VLC is optional and its install command is commented out.

## Removed packages

Omarchy installs these by default. The post-install scripts remove them after `omarchy update`. `omarchy pkg drop` removes a name only when it is installed (`sudo pacman -Rns --noconfirm`). `--dry-run` prints that command and does not remove the package. `omarchy update` may not install them again; the drop still runs on every post-install.

| Software / package | What it is | How the post-install scripts remove it | Script(s) |
| --- | --- | --- | --- |
| `obsidian` | Notes app from Arch extra | `omarchy pkg drop obsidian` when `pacman -Q obsidian` succeeds | [XPS 17 9720](./post-install-dell-xps-17-9720.sh), [Latitude 5540](./post-install-dell-latitude-5540.sh), [XPS postflight](./postflight-Dell-XPS-17-9720.sh) |
