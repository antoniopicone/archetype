FROM --platform=linux/amd64 archlinux:latest

# Set architecture variable
ENV ARCH=x86_64

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    archiso \
    git \
    base-devel \
    squashfs-tools

WORKDIR /build

# Copy releng config as base
RUN cp -r /usr/share/archiso/configs/releng /build/archlive

# Create directory for installation script
RUN mkdir -p /build/archlive/airootfs/root

# Copy installation script
COPY scripts/arch-install.sh /build/archlive/airootfs/root/
RUN chmod +x /build/archlive/airootfs/root/arch-install.sh

# Auto-run installer on first login (zsh compatible)
RUN cat >> /build/archlive/airootfs/root/.zprofile << 'EOF'
# Auto-run installer on first login
if [ -z "$INSTALLER_RAN" ]; then
    setfont ter-118n
    export INSTALLER_RAN=1
    clear
    echo "╔════════════════════════════════════════╗"
    echo "║   Archetype Linux Installer (x86_64)   ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo "Installation script available at: /root/arch-install.sh"
    echo ""

    echo -n "Run automated installer now? (yes/no) [yes]: "
    read RUN_INSTALLER
    RUN_INSTALLER=${RUN_INSTALLER:-yes}

    if [ "$RUN_INSTALLER" = "yes" ]; then
        chmod +x /root/arch-install.sh
        /root/arch-install.sh
    else
        echo ""
        echo "You can run the installer manually anytime with:"
        echo "  /root/arch-install.sh"
        echo ""
    fi
fi
EOF

# Add additional packages for x86_64
RUN echo "reflector" >> /build/archlive/packages.x86_64 && \
    echo "dialog" >> /build/archlive/packages.x86_64

# Create custom MOTD
RUN cat > /build/archlive/airootfs/etc/motd << 'EOF'
╔══════════════════════════════════════════════════════╗
║                                                      ║
║        Archetype Linux - x86_64 Installation         ║
║                                                      ║
║  This custom ISO includes an automated installer     ║
║  that will guide you through the installation.       ║
║                                                      ║
║  Run: /root/arch-install.sh                          ║
║                                                      ║
╚══════════════════════════════════════════════════════╝
EOF

# Create output directory
RUN mkdir -p /output

# Build script
RUN cat > /build/build-iso.sh << 'EOF'
#!/bin/bash
set -e

echo "======================================"
echo "  Building Archetype Linux x86_64    "
echo "======================================"
echo

cd /build/archlive

# Clean previous builds
rm -rf /tmp/archiso-tmp work out

# Build ISO
mkarchiso -v -w /tmp/archiso-tmp -o /output .

echo
echo "✓ ISO built successfully!"
echo
ls -lh /output/*.iso
echo
echo "SHA256 checksum:"
sha256sum /output/*.iso

# Rename with timestamp and architecture
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ISO_NAME=$(ls /output/*.iso)
NEW_NAME="/output/archetype-x86_64-${TIMESTAMP}.iso"
mv "$ISO_NAME" "$NEW_NAME"

echo
echo "✓ ISO saved as: $NEW_NAME"
EOF

RUN chmod +x /build/build-iso.sh

CMD ["/build/build-iso.sh"]
