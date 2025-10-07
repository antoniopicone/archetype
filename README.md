# Archetype Linux

A full-fledged Linux distribution based on Arch Linux, designed to build your digital ecosystem with security and flexibility in mind.

## Features

- **Multi-architecture Support**: x86_64 and ARM64 (aarch64)
- **Full Disk Encryption**: LUKS2 encryption with AES-256
- **Btrfs Filesystem**: Modern filesystem with compression, snapshots, and subvolumes
- **Essential Services**: NetworkManager, Avahi, OpenSSH, Bluetooth pre-configured
- **Optimized Layout**: Separate subvolumes for root, home, var, and snapshots
- **Desktop Ready**: Choose your desktop environment during or after installation

## Quick Start

### Create Bootable USB

Download the latest Arch Linux ISO and write it to a USB drive:

```bash
# On Linux
sudo dd bs=4M if=archlinux-x86_64.iso of=/dev/sdX conv=fsync oflag=direct status=progress

# On macOS
sudo dd if=archlinux-x86_64.iso of=/dev/rdiskN bs=4m status=progress
```

### Install Archetype

Boot from the USB and run:

```bash
# Connect to internet (if using WiFi)
iwctl
# Then in iwctl prompt:
# station wlan0 connect "YOUR_SSID"

# Download and run installation script
curl -LO https://raw.githubusercontent.com/antoniopicone/archetype/main/scripts/install.sh
chmod +x install.sh
sudo ./install.sh
```

## Documentation

- [Installation Guide](docs/INSTALLATION.md) - Automated installation instructions
- [Manual Installation](docs/MANUAL_INSTALL.md) - Step-by-step manual installation
- [CLAUDE.md](CLAUDE.md) - Developer documentation for working with this repository

## System Architecture

### Disk Layout

- **UEFI**: 1GB EFI partition + LUKS-encrypted root partition
- **BIOS**: 1MB BIOS boot partition + LUKS-encrypted root partition

### Btrfs Subvolumes

```
/dev/mapper/cryptroot (btrfs)
├── @ (/)
├── @home (/home)
├── @var (/var)
├── @snapshots (/.snapshots)
└── @swap (/swap)
```

### Pre-configured Services

- **NetworkManager**: Network connectivity management
- **Avahi**: Zero-configuration networking (mDNS/DNS-SD)
- **OpenSSH**: Secure remote access
- **Bluetooth**: Bluetooth device support

## Project Structure

```
archetype/
├── docs/           # Documentation
├── scripts/        # Installation scripts
│   ├── lib/        # Helper libraries
│   └── install.sh  # Main installer
└── configs/        # System configurations
```

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details

## Contributing

Contributions are welcome! This project is in early development.

## Credits

Built on top of [Arch Linux](https://archlinux.org/)
