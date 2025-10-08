FROM debian:13 AS builder
RUN apt update && apt install -y wget
WORKDIR /build
RUN wget http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz && \
    mkdir archroot && \
    tar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C archroot

FROM scratch
COPY --from=builder /build/archroot/ /

# Configure pacman - proper fix for NoExtract
RUN awk '/^\[options\]/{print; print "NoExtract = etc/hosts etc/resolv.conf etc/hostname"; next}1' /etc/pacman.conf > /tmp/pacman.conf && \
    mv /tmp/pacman.conf /etc/pacman.conf && \
    sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf

# Initialize and upgrade
RUN pacman-key --init && \
    pacman-key --populate archlinuxarm && \
    pacman -Syu --noconfirm

RUN pacman -S --noconfirm \
    git \
    base-devel \
    arch-install-scripts \
    squashfs-tools \
    libisoburn \
    dosfstools \
    e2fsprogs \
    erofs-utils \
    mtools \
    libarchive \
    wget \
    curl

WORKDIR /build

# Clone archiso-aarch64
RUN git clone https://github.com/archlinux-jerry/archiso-aarch64.git /build/archiso-aarch64

# Create working directory for ISO build
RUN mkdir -p /build/archlive

# Copy the releng config as base
RUN cp -r /build/archiso-aarch64/configs/releng/* /build/archlive/

# IMPORTANT: Remove problematic preset files that cause conflicts
RUN rm -f /build/archlive/airootfs/etc/mkinitcpio.d/*.preset

# Create directory for installation script
RUN mkdir -p /build/archlive/airootfs/root

# Copy installation script
COPY scripts/arch-install-arm64.sh /build/archlive/airootfs/root/arch-install.sh
RUN chmod +x /build/archlive/airootfs/root/arch-install.sh

# Auto-run installer on first login
RUN cat >> /build/archlive/airootfs/root/.zprofile << 'EOF'
if [ -z "$INSTALLER_RAN" ]; then
    setfont ter-118n 2>/dev/null || true
    export INSTALLER_RAN=1
    clear
    echo "╔════════════════════════════════════════╗"
    echo "║   Archetype Linux Installer (ARM64)    ║"
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

# Remove packages not available in ARM repos
RUN sed -i '/^reiserfsprogs$/d' /build/archlive/packages.aarch64 && \
    sed -i '/^reflector$/d' /build/archlive/packages.aarch64 && \
    sed -i '/^edk2-shell$/d' /build/archlive/packages.aarch64

# CRITICAL: Ensure keyring is in the ISO
RUN grep -q "^archlinuxarm-keyring$" /build/archlive/packages.aarch64 || \
    echo "archlinuxarm-keyring" >> /build/archlive/packages.aarch64

# Add additional packages that ARE available
RUN echo "dialog" >> /build/archlive/packages.aarch64 && \
    echo "vim" >> /build/archlive/packages.aarch64 && \
    echo "networkmanager" >> /build/archlive/packages.aarch64

# Custom MOTD
RUN cat > /build/archlive/airootfs/etc/motd << 'EOF'
╔══════════════════════════════════════════════════════╗
║        Archetype Linux - ARM64 Installation          ║
╚══════════════════════════════════════════════════════╝
Run: /root/arch-install.sh
EOF

# Setup mirrors
RUN cat > /build/archlive/airootfs/etc/pacman.d/mirrorlist << 'EOF'
Server = http://mirror.archlinuxarm.org/$arch/$repo
Server = http://de.mirror.archlinuxarm.org/$arch/$repo
Server = http://fl.us.mirror.archlinuxarm.org/$arch/$repo
EOF

# Create output directory
RUN mkdir -p /output

# Build script with proper cleanup
RUN cat > /build/build-iso.sh << 'EOF'
#!/bin/bash
set -e

echo "======================================"
echo "  Building Archetype Linux ARM64     "
echo "======================================"
cd /build/archlive

# Complete cleanup of any previous build artifacts
echo "Cleaning up previous build artifacts..."
rm -rf /tmp/archiso-tmp work out
# Also clean any stale airootfs subdirectories that might have conflicts
find airootfs -name "*.preset" -delete 2>/dev/null || true

echo "Starting mkarchiso..."
echo ""

# Run mkarchiso with verbose output
/build/archiso-aarch64/archiso/mkarchiso -v -w /tmp/archiso-tmp -o /output .

BUILD_EXIT=$?

if [ $BUILD_EXIT -ne 0 ]; then
    echo ""
    echo "ERROR: mkarchiso exited with code $BUILD_EXIT"
    exit 1
fi

if ls /output/*.iso 1> /dev/null 2>&1; then
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    ISO_NAME=$(ls /output/*.iso | head -1)
    NEW_NAME="/output/archetype-arm64-${TIMESTAMP}.iso"
    mv "$ISO_NAME" "$NEW_NAME"
    echo ""
    echo "✓ ======================================"
    echo "✓ ISO built successfully!"
    echo "✓ ======================================"
    echo "✓ ISO saved as: $NEW_NAME"
    echo ""
    ls -lh "$NEW_NAME"
    echo ""
    sha256sum "$NEW_NAME"
else
    echo ""
    echo "ERROR: ISO build failed - no output file generated"
    echo "Check the output above for errors"
    exit 1
fi
EOF

RUN chmod +x /build/build-iso.sh

CMD ["/build/build-iso.sh"]