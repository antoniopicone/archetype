# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Archetype is an Arch Linux-based distribution with:
- Multi-architecture support (x86_64, ARM64)
- LUKS2 full disk encryption
- Btrfs filesystem with optimized subvolume layout
- Pre-configured essential services (NetworkManager, Avahi, OpenSSH, Bluetooth)

## Installation Scripts Architecture

### Main Installation Flow

The installation is orchestrated by [scripts/install.sh](scripts/install.sh), which:
1. Validates environment (root, boot mode, internet)
2. Gathers user input (disk, hostname, username, timezone)
3. Calls modular library functions in sequence
4. Handles cleanup and error reporting

### Library Modules

All helper functions are in `scripts/lib/`:

- **[utils.sh](scripts/lib/utils.sh)**: Logging utilities (info, success, warning, error)
- **[disk.sh](scripts/lib/disk.sh)**: Disk partitioning and LUKS encryption setup
  - `partition_disk()`: Creates GPT partitions for UEFI or MBR for BIOS
  - `setup_luks()`: Configures LUKS2 encryption with AES-256
- **[btrfs.sh](scripts/lib/btrfs.sh)**: Btrfs filesystem and subvolume management
  - `setup_btrfs()`: Creates and mounts subvolumes (@, @home, @var, @snapshots, @swap)
  - `create_swapfile()`: Creates CoW-disabled swapfile in @swap subvolume
- **[chroot.sh](scripts/lib/chroot.sh)**: System installation and configuration
  - `install_base_system()`: Uses pacstrap to install base packages
  - `configure_system()`: Chroots and configures timezone, locale, users, services, bootloader

### Btrfs Subvolume Layout

The system uses separate subvolumes for snapshot flexibility:
```
@ → /              (root filesystem)
@home → /home      (user data)
@var → /var        (logs, cache)
@snapshots → /.snapshots
@swap → /swap      (swapfile, no CoW)
```

Mount options: `defaults,noatime,compress=zstd:1,space_cache=v2,autodefrag`

### Pre-configured Services

These services are enabled by default in [chroot.sh](scripts/lib/chroot.sh):
- NetworkManager (network connectivity)
- avahi-daemon (mDNS/DNS-SD)
- sshd (SSH with root login disabled)
- bluetooth (Bluetooth support)

### Testing Installation Scripts

To test script modifications:
1. Use a VM with at least 20GB disk space
2. Boot Arch Linux ISO
3. Copy modified scripts to `/tmp/`
4. Run: `bash -x /tmp/install.sh` for verbose output
5. Check logs in case of errors

### Common Development Tasks

**Add a new service:**
1. Add package to `base_packages` array in [chroot.sh:install_base_system()](scripts/lib/chroot.sh)
2. Add `systemctl enable <service>` in [chroot.sh:configure_system()](scripts/lib/chroot.sh)

**Modify subvolume layout:**
1. Edit `setup_btrfs()` in [btrfs.sh](scripts/lib/btrfs.sh)
2. Update documentation in [MANUAL_INSTALL.md](docs/MANUAL_INSTALL.md)

**Change partition scheme:**
1. Modify `partition_disk()` in [disk.sh](scripts/lib/disk.sh)
2. Ensure bootloader configuration in [chroot.sh](scripts/lib/chroot.sh) matches

**Add architecture support:**
1. Add detection in [install.sh](scripts/install.sh) (see `ARCH` variable)
2. Add architecture-specific packages in [chroot.sh:install_base_system()](scripts/lib/chroot.sh)
3. Handle bootloader differences in [chroot.sh:configure_system()](scripts/lib/chroot.sh)

## Important Notes

- All scripts assume they're run in the Arch Linux live environment
- **ARM64 GRUB**: GRUB's auto-detection doesn't work with ARM64 kernels (Image/Image.gz). The installer creates a manual grub.cfg for ARM64 systems at [chroot.sh:182-221](scripts/lib/chroot.sh#L182-L221)
- LUKS encryption requires user interaction for password setup
- The installer creates a minimal base system; desktop environment is installed separately
- Disk operations are destructive - always verify target disk before execution
- Scripts use `set -e` to fail fast on errors

## Documentation

- [docs/INSTALLATION.md](docs/INSTALLATION.md): User-facing installation guide with USB creation
- [docs/MANUAL_INSTALL.md](docs/MANUAL_INSTALL.md): Complete manual installation steps for advanced users

## License

MIT License - see [LICENSE](LICENSE)
