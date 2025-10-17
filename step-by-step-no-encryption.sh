#!/bin/sh

# Script: step-by-step-no-encryption.sh
# Purpose: Install Arch Linux ARM64 from Alpine ISO with Btrfs root (no encryption)
# Hardware: UTM, Raspberry Pi 4/5, ARM64 UEFI systems
# Layout: EFI boot (FAT32) + Btrfs root with subvolumes

# Verbosity control
DEBUG=0
for arg in "$@"; do
    [ "$arg" = "--debug" ] && DEBUG=1
done

log() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "$@"
    fi
}

banner() {
    clear
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║              ARCHETYPE AUTO-INSTALLER                        ║
║         Arch Linux ARM64 Installation System                ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
BANNER
}

# ==============================================================================
# PART 1: ALPINE LINUX SETUP (Live Environment)
# ==============================================================================

banner
echo "\n[Auto-install] Setting up Alpine Linux..."
log "== Verbose output enabled =="

# Configure keyboard and timezone
setup-keymap it it
setup-timezone Europe/Rome

# Setup networking
printf 'n\n' | setup-interfaces
echo "nameserver 8.8.8.8" > /etc/resolv.conf
rc-service networking restart

# Setup and update repositories
cat > /etc/apk/repositories << EOF
https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF

apk update
apk upgrade --available

# Install required packages for remote setup and installation
apk add --no-cache \
    openssh-server \
    sudo \
    bash \
    curl \
    wget \
    avahi \
    dbus \
    vim \
    htop \
    parted \
    btrfs-progs \
    e2fsprogs \
    dosfstools \
    util-linux \
    coreutils \
    tar \
    gzip \
    lsblk
    terminus-font

# Set console font (Terminus)
setfont ter-118n || true

# Enable and configure SSH
rc-update add sshd
echo "root:root" | chpasswd
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
rc-service sshd restart

# Set hostname for mDNS
hostname "alpine-arch"
echo "127.0.0.1 alpine-arch localhost localhost.localdomain" > /etc/hosts
echo "::1       alpine-arch localhost localhost.localdomain" >> /etc/hosts

# Enable Avahi mDNS for network discovery
rc-update add dbus
rc-update add avahi-daemon
rc-service dbus start
rc-service avahi-daemon start

echo ""
echo "✓ Alpine setup complete!"
echo ""
echo "You can now connect via SSH: ssh root@alpine-arch.local"
echo "Password: root"
echo ""
echo "Press ENTER to continue with disk setup or CTRL+C to setup remotely..."
read

# ==============================================================================
# PART 2: DISK PREPARATION
# ==============================================================================

echo "\n[Auto-install] Preparing disk..."
log "== Disk setup details =="

# Load Btrfs kernel module
modprobe btrfs

# Show available disks
echo ""
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL | grep -E "vd|sd|nvme|mmcblk"
echo ""

# Prompt for disk
read -p "Enter target disk (e.g., /dev/vda or /dev/sda): " DISK

if [ ! -b "$DISK" ]; then
    echo "Error: Disk $DISK not found!"
    exit 1
fi

echo ""
echo "WARNING: This will DESTROY all data on $DISK"
lsblk "$DISK"
echo ""
read -p "Type 'yes' to continue: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Wipe disk
echo "Wiping disk signatures..."
wipefs -a "$DISK"

# Create GPT partition table
echo "Creating GPT partition table..."
parted -s "$DISK" mklabel gpt

# Create partitions:
# 1. EFI boot partition (512MB)
# 2. Root partition (rest of disk)
echo "Creating partitions..."
parted -s "$DISK" mkpart primary fat32 1MiB 512MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary btrfs 512MiB 100%

# Determine partition naming scheme
if echo "$DISK" | grep -q "nvme\|mmcblk"; then
    BOOT="${DISK}p1"
    ROOT="${DISK}p2"
else
    BOOT="${DISK}1"
    ROOT="${DISK}2"
fi

# Wait for partitions to be recognized
sleep 2
partprobe "$DISK" 2>/dev/null || true
sleep 1

echo "✓ Disk partitioned successfully"
echo "  $BOOT -> EFI boot (512MB)"
echo "  $ROOT -> Btrfs root (remaining space)"

# ==============================================================================
# PART 3: FORMAT AND MOUNT FILESYSTEMS
# ==============================================================================

echo ""
echo "=========================================="
echo "Part 3: Formatting Filesystems"
echo "=========================================="

# Format partitions
echo "Formatting EFI boot partition..."
mkfs.fat -F32 "$BOOT"

echo "Formatting root partition with Btrfs..."
mkfs.btrfs -f "$ROOT"

# Mount root partition temporarily
mount "$ROOT" /mnt

# Create Btrfs subvolumes
echo "Creating Btrfs subvolumes..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap

# Unmount to remount with proper subvolumes
umount /mnt

# Mount subvolumes with optimal options
echo "[Auto-install] Mounting Btrfs subvolumes..."
mount -o defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@ "$ROOT" /mnt

mkdir -p /mnt/home
mount -o defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@home "$ROOT" /mnt/home

mkdir -p /mnt/var
mount -o defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@var "$ROOT" /mnt/var

mkdir -p /mnt/.snapshots
mount -o defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@snapshots "$ROOT" /mnt/.snapshots

mkdir -p /mnt/swap
mount -o defaults,noatime,subvol=@swap "$ROOT" /mnt/swap

# Mount EFI boot partition
mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

#FIXME: durante il setup, non viene eseguito

# Install additional fonts in Arch chroot
cat > /mnt/root/install-fonts.sh << 'EOFFONT'
#!/bin/bash
set -e
pacman -S --noconfirm terminus-font ttf-dejavu ttf-liberation noto-fonts
echo "FONT=ter-118n" > /etc/vconsole.conf
echo "FONT_MAP=8859-1_to_uni" >> /etc/vconsole.conf
# Enable color support in terminal
echo "export TERM=xterm-256color" >> /etc/profile
echo 'export PS1="\[\e[32m\]\u@\h:\w\$\[\e[0m\] "' >> /etc/profile
# Also set for new users
echo "export TERM=xterm-256color" >> /etc/skel/.bashrc
echo 'export PS1="\[\e[32m\]\u@\h:\w\$\[\e[0m\] "' >> /etc/skel/.bashrc

# Video drivers detection and installation
echo "[Auto-install] Detecting and installing video drivers..."
GPU_INTEL=$(lspci | grep -i "vga\|3d" | grep -i intel)
GPU_AMD=$(lspci | grep -i "vga\|3d" | grep -i "amd\|ati")
GPU_NVIDIA=$(lspci | grep -i "vga\|3d" | grep -i nvidia)

if [ -n "$GPU_INTEL" ]; then
    echo "Intel GPU detected: $GPU_INTEL"
    echo "Installing Intel drivers..."
    pacman -S --noconfirm mesa
    echo "✓ Intel video drivers installed"
fi

if [ -n "$GPU_AMD" ]; then
    echo "AMD GPU detected: $GPU_AMD"
    echo "Installing AMD drivers..."
    pacman -S --noconfirm mesa xf86-video-amdgpu
    echo "✓ AMD video drivers installed"
fi

if [ -n "$GPU_NVIDIA" ]; then
    echo "NVIDIA GPU detected: $GPU_NVIDIA"
    echo "Installing NVIDIA drivers..."
    pacman -S --noconfirm nvidia nvidia-utils
    echo "✓ NVIDIA video drivers installed"
fi

if [ -z "$GPU_INTEL" ] && [ -z "$GPU_AMD" ] && [ -z "$GPU_NVIDIA" ]; then
    echo "⚠️  No recognized GPU detected. Installing generic mesa drivers..."
    pacman -S --noconfirm mesa
fi

# Firewall configuration
echo "[Auto-install] Installing and configuring firewall..."
pacman -S --noconfirm ufw
if [ $? -eq 0 ]; then
    systemctl enable ufw
    echo "✓ UFW firewall installed and enabled"
    echo "Note: UFW will be activated after first boot"
else
    echo "⚠️  Warning: UFW installation failed"
fi

# Btrfs Snapshots configuration
echo "[Auto-install] Installing and configuring Btrfs snapshots..."
pacman -S --noconfirm snapper snap-pac
if [ $? -eq 0 ]; then
    if btrfs subvolume list / | grep -q "@"; then
        snapper -c root create-config /
        mkdir -p /.snapshots
        chmod 750 /.snapshots
        sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root
        systemctl enable snapper-timeline.timer
        systemctl enable snapper-cleanup.timer
        echo "✓ Automatic snapshots configured (hourly: 5, daily: 7)"
    else
        echo "⚠️  Btrfs subvolumes not detected. Snapper installed but not configured."
        echo "You can configure it manually after boot."
    fi
else
    echo "⚠️  Warning: Snapper installation failed"
fi

# SSD TRIM configuration
echo "[Auto-install] Configuring SSD TRIM..."
DISK_ROTATIONAL=$(cat /sys/block/$(lsblk -no PKNAME $ROOT | head -1)/queue/rotational 2>/dev/null)
if [ "$DISK_ROTATIONAL" = "0" ]; then
    echo "SSD detected. Enabling periodic TRIM..."
    systemctl enable fstrim.timer
    echo "✓ TRIM timer enabled for SSD optimization"
else
    echo "HDD detected or unable to detect disk type. Skipping TRIM configuration."
fi

# Enable essential services
echo "[Auto-install] Enabling system services..."
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable avahi-daemon
EOFFONT
chmod +x /mnt/root/install-fonts.sh

echo "✓ Filesystems mounted"

# ==============================================================================
# PART 4: INSTALL ARCH LINUX ARM
# ==============================================================================

echo ""
echo "=========================================="
echo "Part 4: Installing Arch Linux ARM"
echo "=========================================="

# Download Arch Linux ARM root filesystem
echo "Downloading Arch Linux ARM (this may take several minutes)..."
cd /tmp

# BusyBox wget doesn't support --show-progress, use -O for output
if wget --help 2>&1 | grep -q -- '--show-progress'; then
    # GNU wget
    wget -q --show-progress http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
else
    # BusyBox wget (Alpine)
    wget -O ArchLinuxARM-aarch64-latest.tar.gz http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
fi

# Extract to mounted root
echo "Extracting Arch Linux ARM..."
tar xzf ArchLinuxARM-aarch64-latest.tar.gz -C /mnt
rm ArchLinuxARM-aarch64-latest.tar.gz

echo "✓ Arch Linux ARM extracted"

# ==============================================================================
# PART 5: GENERATE FSTAB
# ==============================================================================

echo ""
echo "Generating fstab..."

# Get UUIDs
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT")

# Create fstab
cat > /mnt/etc/fstab << EOF
# /etc/fstab: static file system information
#
# <file system>              <dir>         <type>  <options>                                           <dump> <pass>
UUID=$ROOT_UUID              /             btrfs   defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@           0 0
UUID=$ROOT_UUID              /home         btrfs   defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@home       0 0
UUID=$ROOT_UUID              /var          btrfs   defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@var        0 0
UUID=$ROOT_UUID              /.snapshots   btrfs   defaults,noatime,compress=zstd:1,space_cache=v2,subvol=@snapshots  0 0
UUID=$ROOT_UUID              /swap         btrfs   defaults,noatime,subvol=@swap                                      0 0
UUID=$BOOT_UUID              /boot         vfat    defaults,noatime                                                   0 2
EOF

echo "✓ fstab generated"

# ==============================================================================
# PART 6: CHROOT AND CONFIGURE SYSTEM
# ==============================================================================

echo ""
echo "=========================================="
echo "Part 6: Configuring System (chroot)"
echo "=========================================="

# Mount pseudo filesystems for chroot
mount -t proc /proc /mnt/proc
mount -t sysfs /sys /mnt/sys
mount --rbind /dev /mnt/dev
mount --rbind /run /mnt/run

# Copy DNS configuration
rm -f /mnt/etc/resolv.conf
cp /etc/resolv.conf /mnt/etc/

# Create configuration script to run in chroot
cat > /mnt/root/configure.sh << 'EOFCHROOT'
#!/bin/bash
set -e

echo "Initializing pacman..."
pacman-key --init
pacman-key --populate archlinuxarm

# Configure mirrors
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
echo 'Server = http://de4.mirror.archlinuxarm.org/$arch/$repo/' > /etc/pacman.d/mirrorlist

echo "Updating system..."
pacman -Syu --noconfirm

echo "Installing essential packages..."
pacman -S --noconfirm \
    base \
    base-devel \
    linux-aarch64 \
    linux-firmware \
    btrfs-progs \
    grub \
    efibootmgr \
    networkmanager \
    openssh \
    avahi \
    nss-mdns \
    sudo \
    vim \
    nano \
    bash-completion \
    curl \
    wget \
    htop \
    git \
    e2fsprogs \
    dosfstools

echo "Configuring timezone..."
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
hwclock --systohc

echo "Configuring locale..."
echo "it_IT.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=it_IT.UTF-8" > /etc/locale.conf

echo "Setting hostname..."
echo "archetype" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   archetype.local archetype
EOF


echo "Configuring mkinitcpio..."
# Add btrfs module and ensure proper hooks
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf

# Generate initramfs
mkinitcpio -P

echo "Installing GRUB bootloader..."
# Install GRUB for ARM64 UEFI with removable media path
grub-install --target=arm64-efi --efi-directory=/boot --bootloader-id=GRUB --removable --recheck

# Copy kernel to standard location (GRUB expects vmlinuz-linux)
if [ -f /boot/Image ]; then
    cp /boot/Image /boot/vmlinuz-linux
fi

# Configure GRUB with proper rootflags for Btrfs subvolume
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet rootflags=subvol=@"/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="rootflags=subvol=@"/' /etc/default/grub

# Ensure GRUB can find the kernel
sed -i 's/^#GRUB_DISABLE_LINUX_UUID=.*/GRUB_DISABLE_LINUX_UUID=false/' /etc/default/grub

# Generate GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg

# Verify GRUB installation
echo "Verifying GRUB installation..."
ls -la /boot/EFI/BOOT/ || echo "Warning: EFI/BOOT directory not found"
ls -la /boot/grub/grub.cfg || echo "Warning: grub.cfg not found"

echo "Creating user account..."
read -p "Enter username [antonio]: " USERNAME
USERNAME=${USERNAME:-antonio}

useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "Set password for user $USERNAME:"
passwd "$USERNAME"

# Configure sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "Set password for root:"
passwd

echo "Enabling services..."
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable avahi-daemon

# Configure SSH (disable root login)
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Configure Avahi for mDNS
sed -i 's/hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf

echo ""
echo "✓ System configuration complete!"
EOFCHROOT

chmod +x /mnt/root/configure.sh

# Execute configuration in chroot
echo "Running system configuration..."
chroot /mnt /bin/bash /root/configure.sh

# Install fonts in chroot
chroot /mnt /bin/bash /root/install-fonts.sh
rm /mnt/root/install-fonts.sh

# Cleanup
rm /mnt/root/configure.sh

# ==============================================================================
# PART 7: FINALIZE
# ==============================================================================

echo ""
echo "\n[Auto-install] Installation Complete!"
banner
echo ""
echo "Disk layout:"
echo "  $BOOT -> /boot (FAT32, 512MB)"
echo "  $ROOT -> / (Btrfs with subvolumes)"
echo ""
echo "Btrfs subvolumes:"
echo "  @ -> /"
echo "  @home -> /home"
echo "  @var -> /var"
echo "  @snapshots -> /.snapshots"
echo "  @swap -> /swap"
echo ""
echo "All subvolumes use zstd:1 compression (except @swap)"
echo "No encryption is used"
echo ""
echo "Services enabled:"
echo "  - NetworkManager (DHCP networking)"
echo "  - OpenSSH (root login disabled)"
echo "  - Avahi (mDNS - hostname.local)"
echo ""
echo "Next steps:"
echo "  1. Unmount: umount -R /mnt"
echo "  2. Reboot: reboot"
echo "  3. Remove installation media"
echo "  4. Login with your user account"
echo "  5. Access via SSH: ssh username@archetype.local"
echo ""
