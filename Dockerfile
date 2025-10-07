FROM --platform=linux/amd64 archlinux:latest

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    archiso \
    git \
    base-devel \
    squashfs-tools

WORKDIR /build

RUN cp -r /usr/share/archiso/configs/releng /build/archlive

RUN mkdir -p /build/archlive/airootfs/root

COPY scripts/arch-install.sh /build/archlive/airootfs/root/
RUN chmod +x /build/archlive/airootfs/root/arch-install.sh

# ✅ CORRETTO: Script compatibile con zsh
RUN cat >> /build/archlive/airootfs/root/.zprofile << 'EOF'
# Auto-run installer on first login
if [ -z "$INSTALLER_RAN" ]; then
    setfont ter-118n
    export INSTALLER_RAN=1
    clear
    echo "╔════════════════════════════════════════╗"
    echo "║   Arch Linux Automated Installer       ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo "Installation script available at: /root/arch-install.sh"
    echo ""
    
    # Sintassi corretta per zsh
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

RUN echo "reflector" >> /build/archlive/packages.x86_64 && \
    echo "dialog" >> /build/archlive/packages.x86_64

RUN cat > /build/archlive/airootfs/etc/motd << 'EOF'
╔══════════════════════════════════════════════════════╗
║                                                      ║
║        Arch Linux - Automated Installation ISO       ║
║                                                      ║
║  This custom ISO includes an automated installer     ║
║  that will guide you through the installation.       ║
║                                                      ║
║  Run: /root/arch-install.sh                          ║
║                                                      ║
╚══════════════════════════════════════════════════════╝
EOF

RUN mkdir -p /output

RUN cat > /build/build-iso.sh << 'EOF'
#!/bin/bash
set -e

echo "======================================"
echo "  Building Custom Arch Linux ISO     "
echo "======================================"
echo

cd /build/archlive

rm -rf /tmp/archiso-tmp work out

mkarchiso -v -w /tmp/archiso-tmp -o /output .

echo
echo "✓ ISO built successfully!"
echo
ls -lh /output/*.iso
echo
echo "SHA256 checksum:"
sha256sum /output/*.iso

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ISO_NAME=$(ls /output/*.iso)
NEW_NAME="/output/archlinux-custom-${TIMESTAMP}.iso"
mv "$ISO_NAME" "$NEW_NAME"

echo
echo "✓ ISO saved as: $NEW_NAME"
EOF

RUN chmod +x /build/build-iso.sh

CMD ["/build/build-iso.sh"]