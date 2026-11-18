# System snapshot (fastfetch)

Captured with `fastfetch` on 2026-11-14 (America/Los_Angeles), three days after a fresh Omarchy install.

## Hardware

| Item | Value |
|---|---|
| Model | Dell XPS 17 9720 |
| CPU | 12th Gen Intel Core i9-12900HK (12+8) @ 5.00 GHz |
| dGPU | NVIDIA GeForce RTX 3060 Mobile / Max-Q |
| iGPU | Intel Iris Xe Graphics |
| Display | 3840x2400 @ 2x scale, 17", 60 Hz (built-in) |
| Disk `/` (LUKS + Btrfs, nvme0n1) | 46.97 GiB / 474.92 GiB (10%) |
| Disk `/data` (Btrfs, nvme1n1p3) | 4.54 GiB / 1.82 TiB (0%) |
| Memory | 6.79 GiB / 31.02 GiB (22%) |
| Swap | 0 B / 62.04 GiB (zram + Btrfs swapfile) |

## Software

| Item | Value |
|---|---|
| OS | Omarchy 4.5.0-3 (stable channel) |
| Kernel | Linux 7.2.15-1-omarchy |
| Compositor | Hyprland 0.56.2 (Wayland) |
| Packages | 1040 (pacman) |
| Prompt | Starship |

## Regenerate

```bash
fastfetch --pipe --logo none
```
