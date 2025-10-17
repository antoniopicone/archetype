#!/bin/bash
# Script: build-alpine-universal.sh
# Purpose: Build Alpine ARM64 ISO with true auto-login using initramfs modification
# This approach modifies the initramfs directly for guaranteed auto-start

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Configuration
ALPINE_VERSION="3.20"
ALPINE_ARCH="aarch64"
ALPINE_ISO="alpine-virt-${ALPINE_VERSION}.0-${ALPINE_ARCH}.iso"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ALPINE_ISO}"
WORK_DIR="alpine-custom-build"
OUTPUT_ISO="alpine-archetype-autoinstall-${ALPINE_ARCH}.iso"

# Check dependencies
info "Checking dependencies..."
for cmd in wget xorriso cpio gzip; do
    if ! command -v "$cmd" &> /dev/null; then
        error "$cmd is required. Install: brew install $cmd"
    fi
done

# Clean up previous build
if [ -d "$WORK_DIR" ]; then
    warn "Removing previous build directory..."
    rm -rf "$WORK_DIR"
fi

# Create work directory
info "Creating work directory: $WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Download Alpine ISO
if [ ! -f "../$ALPINE_ISO" ]; then
    info "Downloading Alpine Linux ISO..."
    wget -q --show-progress "$ALPINE_URL" -O "../$ALPINE_ISO"
else
    info "Using existing Alpine ISO: $ALPINE_ISO"
fi

# Extract ISO
info "Extracting Alpine ISO..."
mkdir -p iso_content
xorriso -osirrox on -indev "../$ALPINE_ISO" -extract / iso_content/ 2>&1 | grep -v "^xorriso : UPDATE" || true

# Make extracted files writable
chmod -R u+w iso_content/

# Extract initramfs
info "Extracting and modifying initramfs..."
mkdir -p initramfs_content
cd initramfs_content

# Decompress initramfs (it's a gzipped cpio archive)
if [ -f ../iso_content/boot/initramfs-virt ]; then
    gzip -dc ../iso_content/boot/initramfs-virt | cpio -idm 2>/dev/null
else
    error "initramfs-virt not found in ISO"
fi

# Create our auto-start script in initramfs
info "Adding auto-start script to initramfs..."
mkdir -p init.d
cat > init.d/autostart << 'AUTOSTART'
#!/bin/sh
# Auto-start installer script

# Wait for system to be ready
sleep 2

# Only on tty1 and only once
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/.autoinstall-ran ]; then
    touch /tmp/.autoinstall-ran

    clear
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║              ARCHETYPE AUTO-INSTALLER                        ║
║         Arch Linux ARM64 Installation System                ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

Starting automatic installation in 3 seconds...
Press CTRL+C to abort and access shell.

BANNER

    sleep 1 && echo "3..." || exit
    sleep 1 && echo "2..." || exit
    sleep 1 && echo "1..." || exit

    echo ""
    echo "Starting installation..."
    echo ""

    # Find and run installer
    for path in /media/cdrom /media/sr0 /.modloop; do
        if [ -f "$path/autoinstall.sh" ]; then
            exec /bin/sh "$path/autoinstall.sh"
        fi
    done

    echo "ERROR: Installation script not found!"
    echo "Dropping to shell..."
fi

# Fall through to normal login
AUTOSTART

chmod +x init.d/autostart

# Modify inittab to auto-login root on tty1
info "Modifying inittab for auto-login..."
if [ -f etc/inittab ]; then
    cp etc/inittab etc/inittab.orig

    # Replace tty1 line with auto-login version
    sed -i.bak 's|tty1::.*|tty1::respawn:/bin/login -f root|' etc/inittab

    # Add our autostart to boot sequence
    if ! grep -q "autostart" etc/inittab; then
        sed -i.bak '/::sysinit/a ::sysinit:/init.d/autostart' etc/inittab
    fi
else
    warn "inittab not found in initramfs, creating custom one..."
    mkdir -p etc
    cat > etc/inittab << 'INITTAB'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::sysinit:/init.d/autostart
::wait:/sbin/openrc default

# Auto-login on tty1
tty1::respawn:/bin/login -f root

# Normal login on other ttys
tty2::askfirst:/sbin/getty 38400 tty2
tty3::askfirst:/sbin/getty 38400 tty3
tty4::askfirst:/sbin/getty 38400 tty4

ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
ttyAMA0::respawn:/sbin/getty -L ttyAMA0 115200 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
INITTAB
fi

# Create root's profile to auto-start the installer
info "Creating root auto-start profile..."
mkdir -p root
cat > root/.profile << 'PROFILE'
# Auto-start installer on first login to tty1
if [ -z "$AUTOINSTALL_DONE" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export AUTOINSTALL_DONE=1

    clear
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║              ARCHETYPE AUTO-INSTALLER                        ║
║         Arch Linux ARM64 Installation System                ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

Starting automatic installation in 3 seconds...
Press CTRL+C to abort and access shell.

BANNER

    sleep 1 && echo "3..."
    sleep 1 && echo "2..."
    sleep 1 && echo "1..."

    echo ""
    echo "Starting installation..."
    echo ""

    # Find and run installer
    for path in /media/cdrom /media/sr0; do
        if [ -f "$path/autoinstall.sh" ]; then
            exec /bin/sh "$path/autoinstall.sh"
        fi
    done

    echo "ERROR: Installation script not found!"
    echo "Tried: /media/cdrom/autoinstall.sh, /media/sr0/autoinstall.sh"
    echo ""
fi
PROFILE

# Repackage initramfs
info "Repackaging modified initramfs..."
find . | cpio -o -H newc 2>/dev/null | gzip -9 > ../iso_content/boot/initramfs-virt.new
mv ../iso_content/boot/initramfs-virt.new ../iso_content/boot/initramfs-virt

cd ..

# Copy installation script to ISO root
info "Embedding installation script..."
cp ../step-by-step-no-encryption.sh iso_content/autoinstall.sh
chmod +x iso_content/autoinstall.sh

# Update GRUB configuration
info "Configuring GRUB boot menu..."
if [ -f "iso_content/boot/grub/grub.cfg" ]; then
    cp iso_content/boot/grub/grub.cfg iso_content/boot/grub/grub.cfg.orig

    cat > iso_content/boot/grub/grub.cfg << 'GRUBEOF'
set timeout=1
set default=0

menuentry "Archetype Auto-Installer (Arch Linux ARM64)" {
    linux /boot/vmlinuz-virt modules=loop,squashfs,sd-mod,usb-storage quiet
    initrd /boot/initramfs-virt
}

menuentry "Alpine Linux (Manual Mode)" {
    linux /boot/vmlinuz-virt modules=loop,squashfs,sd-mod,usb-storage
    initrd /boot/initramfs-virt.orig
}
GRUBEOF

    # Keep original initramfs for manual mode
    cp iso_content/boot/initramfs-virt iso_content/boot/initramfs-virt.orig
fi

# Rebuild ISO
info "Building custom ISO..."

# Get volume ID from original ISO
VOLID=$(xorriso -indev "../$ALPINE_ISO" -report_el_torito as_mkisofs 2>&1 | grep "^-V" | cut -d"'" -f2 || echo "ALPINE")

# Extract MBR for ARM64 boot
dd if="../$ALPINE_ISO" of=mbr_area.img bs=512 count=16 2>/dev/null

# Create new ISO
xorriso -as mkisofs \
    -o "../$OUTPUT_ISO" \
    -V "$VOLID" \
    -J -joliet-long \
    -R \
    -G mbr_area.img \
    -efi-boot-part --efi-boot-image \
    -c /boot.catalog \
    -e /boot/grub/efi.img \
    -no-emul-boot \
    -boot-load-size 2880 \
    -partition_offset 0 \
    -partition_hd_cyl 64 \
    -partition_sec_hd 32 \
    -partition_cyl_align off \
    iso_content/ 2>&1 | grep -v "^xorriso : UPDATE" || true

# Clean up
rm -f mbr_area.img
cd ..

info "Cleaning up build directory..."
rm -rf "$WORK_DIR"

# Show result
echo ""
info "═══════════════════════════════════════════════════════════"
info "Custom Alpine ISO created successfully!"
info "═══════════════════════════════════════════════════════════"
echo ""
echo "  Output: $(pwd)/$OUTPUT_ISO"
echo "  Size: $(du -h "$OUTPUT_ISO" | cut -f1)"
echo ""
echo "Features:"
echo "  ✓ Auto-login as root on tty1"
echo "  ✓ Auto-starts installation after 3-second countdown"
echo "  ✓ Press CTRL+C during countdown to abort"
echo "  ✓ Manual mode available from GRUB menu"
echo ""
echo "Usage:"
echo "  1. Boot from this ISO in UTM/QEMU"
echo "  2. Wait for auto-login and countdown"
echo "  3. Installation starts automatically"
echo ""
info "═══════════════════════════════════════════════════════════"
