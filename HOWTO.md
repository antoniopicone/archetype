# Arch Linux Custom ISO Builder

Automated builder for custom Arch Linux installation ISO using Docker.

## Prerequisites

- Docker
- Docker Compose
- (Optional) QEMU for testing

## Quick Start

1. Clone this repository
2. Place your `arch-install.sh` script in the `scripts/` directory
3. Run the builder:
```bash
chmod +x build.sh
./build.sh