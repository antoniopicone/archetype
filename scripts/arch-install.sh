#!/bin/bash

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ARCH_NAME="x86_64"
        ;;
    aarch64|arm64)
        ARCH_NAME="ARM64"
        ARCH="aarch64"
        ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac


echo "======================================"
echo "  Archetype Linux Installer ($ARCH_NAME)    "
echo "======================================"
echo

# ========================================
# PART 1: INITIAL CONFIGURATION
# ========================================

# ========================================
# 1. KEYBOARD LAYOUT
# ========================================
echo "=== Keyboard Layout ==="
echo "Common layouts available:"
echo "  us    - US English"
echo "  it    - Italian"
echo "  uk    - UK English"
echo "  de    - German"
echo "  fr    - French"
echo "  es    - Spanish"
echo
echo "To see all layouts: ls /usr/share/kbd/keymaps/**/*.map.gz"
echo
read -p "Enter keyboard layout [us]: " KEYBOARD
KEYBOARD=${KEYBOARD:-us}

echo "Loading keyboard layout: $KEYBOARD"
loadkeys "$KEYBOARD"
if [ $? -ne 0 ]; then
    echo "ERROR: Layout '$KEYBOARD' not found!"
    exit 1
fi
echo "✓ Keyboard layout set: $KEYBOARD"
echo

# ========================================
# 2. LOCALE
# ========================================
echo "=== Locale ==="
echo "Common locales available:"
echo "  en_US.UTF-8 - US English"
echo "  it_IT.UTF-8 - Italian"
echo "  en_GB.UTF-8 - UK English"
echo "  de_DE.UTF-8 - German"
echo "  fr_FR.UTF-8 - French"
echo "  es_ES.UTF-8 - Spanish"
echo
read -p "Enter locale [en_US.UTF-8]: " LOCALE
LOCALE=${LOCALE:-en_US.UTF-8}

echo "Setting locale: $LOCALE"
export LANG="$LOCALE"
echo "✓ Locale set: $LOCALE"
echo

# ========================================
# 3. TIMEZONE
# ========================================
echo "=== Timezone ==="
echo "Common timezones available:"
echo "  Europe/Rome       - Italy"
echo "  Europe/London     - UK"
echo "  Europe/Berlin     - Germany"
echo "  Europe/Paris      - France"
echo "  America/New_York  - EST (USA)"
echo "  America/Chicago   - CST (USA)"
echo "  America/Los_Angeles - PST (USA)"
echo
echo "To see all timezones: timedatectl list-timezones"
echo
read -p "Enter timezone [UTC]: " TIMEZONE
TIMEZONE=${TIMEZONE:-UTC}

echo "Setting timezone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"
if [ $? -ne 0 ]; then
    echo "ERROR: Timezone '$TIMEZONE' not valid!"
    exit 1
fi
timedatectl set-ntp true
echo "✓ Timezone set: $TIMEZONE"
echo "✓ NTP synchronization enabled"
echo

# Show current date and time
echo "Current date and time: $(date)"
echo
echo "======================================"
echo

# ========================================
# 4. DISK SELECTION
# ========================================
# Show available disks
echo "=== Available Disks ==="
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep disk
echo

# Ask which disk to use
echo "Enter the disk to use (e.g., sda, nvme0n1, vdb):"
read -p "Disk: " DISK_NAME

# Validate input
if [ -z "$DISK_NAME" ]; then
    echo "ERROR: No disk specified!"
    exit 1
fi

# Build full path
DISK="/dev/$DISK_NAME"

# Verify disk exists
if [ ! -b "$DISK" ]; then
    echo "ERROR: Disk $DISK does not exist!"
    exit 1
fi

# Show selected disk information
echo
echo "=== Selected Disk ==="
lsblk "$DISK" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
echo
echo "⚠️  WARNING: All data on $DISK will be DELETED! ⚠️"
echo
read -p "Are you sure you want to proceed? Type 'YES' to confirm: " CONFIRM_DISK

if [ "$CONFIRM_DISK" != "YES" ]; then
    echo "Operation cancelled."
    exit 0
fi

# ========================================
# 5. LUKS PASSWORD
# ========================================
# Request LUKS password (hidden input)
echo
echo "Enter password for disk encryption:"
read -s LUKS_PASSWORD
echo
echo "Confirm password:"
read -s LUKS_PASSWORD_CONFIRM
echo

# Verify passwords match
if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
    echo "ERROR: Passwords do not match!"
    exit 1
fi

# ========================================
# 6. BTRFS CONFIGURATION
# ========================================
echo
echo "=== Btrfs Configuration ==="
read -p "Create btrfs subvolumes (@, @home, @snapshots, @log)? (yes/no) [yes]: " CREATE_SUBVOL
CREATE_SUBVOL=${CREATE_SUBVOL:-yes}

# ========================================
# 7. CONFIGURATION SUMMARY
# ========================================
# Calculate sizes
EFI_END="1GiB"
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
SWAP_SIZE_MB=$((RAM_KB * 3 / 2 / 1024))
SWAP_END="$((1024 + SWAP_SIZE_MB))MiB"

echo
echo "=== Configuration Summary ==="
echo "  Keyboard: $KEYBOARD"
echo "  Locale: $LOCALE"
echo "  Timezone: $TIMEZONE"
echo "  Disk: $DISK"
echo "  EFI: 1GB (FAT32)"
echo "  SWAP: ${SWAP_SIZE_MB}MB (1.5x RAM)"
echo "  Root: remaining disk space (LUKS2 SHA-512 + Btrfs)"
echo "  Btrfs Subvolumes: $CREATE_SUBVOL"
echo
read -p "Proceed with partition creation? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Operation cancelled."
    exit 0
fi

# ========================================
# 8. PARTITIONING AND FORMATTING
# ========================================
# Partitioning
echo
echo "[1/8] Creating GPT partition table..."
parted -s "$DISK" mklabel gpt

echo "[2/8] Creating EFI partition..."
parted -s "$DISK" mkpart ESP fat32 1MiB "$EFI_END"
parted -s "$DISK" set 1 esp on

echo "[3/8] Creating SWAP partition..."
parted -s "$DISK" mkpart primary linux-swap "$EFI_END" "$SWAP_END"

echo "[4/8] Creating ROOT partition..."
parted -s "$DISK" mkpart primary "$SWAP_END" 100%

partprobe "$DISK"
sleep 2

# Determine partition names (handles both sda1 and nvme0n1p1)
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART1="${DISK}p1"
    PART2="${DISK}p2"
    PART3="${DISK}p3"
else
    PART1="${DISK}1"
    PART2="${DISK}2"
    PART3="${DISK}3"
fi

# Formatting
echo "[5/8] Formatting EFI partition..."
mkfs.fat -F32 "$PART1"

echo "[6/8] Creating SWAP area..."
mkswap "$PART2"
swapon "$PART2"

# LUKS
echo "[7/8] Encrypting ROOT partition with LUKS..."
echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --batch-mode --hash sha512 --type luks2 "$PART3" -
echo -n "$LUKS_PASSWORD" | cryptsetup open "$PART3" cryptroot -

# Btrfs formatting
echo "[8/8] Formatting ROOT partition with Btrfs..."
mkfs.btrfs -f -L ArchLinux /dev/mapper/cryptroot

# ========================================
# 9. SUBVOLUME CREATION AND MOUNTING
# ========================================
if [ "$CREATE_SUBVOL" == "yes" ]; then
    echo
    echo "Creating Btrfs subvolumes..."
    
    # Temporary mount to create subvolumes
    mount /dev/mapper/cryptroot /mnt
    
    # Create subvolumes
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@log
    
    # Unmount
    umount /mnt
    
    echo "✓ Subvolumes created: @, @home, @snapshots, @log"
    
    # Mount with subvolumes and optimal options
    echo "Mounting subvolumes..."
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt
    
    mkdir -p /mnt/{home,boot,.snapshots,var/log}
    
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
    mount -o noatime,compress=zstd,space_cache=v2,subvol=@log /dev/mapper/cryptroot /mnt/var/log
    
    mount "$PART1" /mnt/boot
    
else
    # Simple mount without subvolumes
    echo
    echo "Mounting root partition..."
    mount -o noatime,compress=zstd,space_cache=v2 /dev/mapper/cryptroot /mnt
    
    mkdir -p /mnt/boot
    mount "$PART1" /mnt/boot
fi

# ========================================
# 10. INITIAL SETUP SUMMARY
# ========================================
echo
echo "✓ ======================================"
echo "✓  Initial setup completed successfully!"
echo "✓ ======================================"
echo
echo "=== Applied Settings ==="
echo "  Keyboard: $KEYBOARD"
echo "  Locale: $LOCALE"
echo "  Timezone: $TIMEZONE"
echo "  Current date/time: $(date)"
echo "  Root filesystem: Btrfs"
echo "  Subvolumes: $CREATE_SUBVOL"
echo
echo "=== Partition Structure ==="
lsblk "$DISK" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
echo

if [ "$CREATE_SUBVOL" == "yes" ]; then
    echo "=== Btrfs Subvolumes ==="
    btrfs subvolume list /mnt
    echo
fi

# Save configuration for later use
cat > /mnt/install-config.txt << EOF
# Configuration used during installation
KEYBOARD=$KEYBOARD
LOCALE=$LOCALE
TIMEZONE=$TIMEZONE
DISK=$DISK
FILESYSTEM=btrfs
SUBVOLUMES=$CREATE_SUBVOL
INSTALL_DATE=$(date)

# Encrypted partition UUID (for bootloader)
PART3_UUID=$(blkid -s UUID -o value $PART3)

# Kernel parameters for GRUB/systemd-boot:
# cryptdevice=UUID=$PART3_UUID:cryptroot root=/dev/mapper/cryptroot
EOF

echo "✓ Configuration saved to /mnt/install-config.txt"
echo "✓ Encrypted partition UUID saved for bootloader configuration"

# Clean up password variables from memory
unset LUKS_PASSWORD
unset LUKS_PASSWORD_CONFIRM

echo
echo "======================================"
echo "  PART 2: BASE SYSTEM INSTALLATION   "
echo "======================================"
echo

# ========================================
# 11. MIRROR CONFIGURATION
# ========================================
echo "=== Mirror Configuration ==="
read -p "Do you want to optimize pacman mirrors? (yes/no) [no]: " OPTIMIZE_MIRRORS
OPTIMIZE_MIRRORS=${OPTIMIZE_MIRRORS:-no}

if [ "$OPTIMIZE_MIRRORS" == "yes" ]; then
    echo "Backing up original mirrors..."
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    
    echo "Optimizing mirrors (this may take a while)..."
    reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
    echo "✓ Mirrors optimized"
fi
echo

# ========================================
# 12. BASE SYSTEM INSTALLATION
# ========================================
echo "=== Base System Installation ==="
echo "Packages to install:"
echo "  - base, linux, linux-firmware"
echo "  - btrfs-progs (filesystem)"
echo "  - cryptsetup, lvm2 (LUKS)"
echo "  - grub, efibootmgr, os-prober (bootloader)"
echo "  - networkmanager (networking)"
echo "  - base-devel, git, vim, nano (development)"
echo

read -p "Proceed with installation? (yes/no) [yes]: " INSTALL_BASE
INSTALL_BASE=${INSTALL_BASE:-yes}

if [ "$INSTALL_BASE" != "yes" ]; then
    echo "Installation cancelled."
    exit 0
fi

echo
echo "[1/5] Installing base packages (this may take several minutes)..."
pacstrap /mnt base linux linux-firmware \
    btrfs-progs \
    cryptsetup lvm2 \
    grub efibootmgr os-prober \
    networkmanager \
    git vim \
    sudo \
    man-db man-pages texinfo \
    terminus-font \
    base-devel

if [ $? -ne 0 ]; then
    echo "ERROR: pacstrap installation failed!"
    exit 1
fi

echo "✓ Base system installed"
echo

# ========================================
# 13. FSTAB GENERATION
# ========================================
echo "[2/5] Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "✓ fstab generated"
echo "Contents of /etc/fstab:"
cat /mnt/etc/fstab
echo

# ========================================
# 14. CHROOT SCRIPT PREPARATION
# ========================================
echo "[3/5] Preparing chroot configuration..."

# Find UUID of encrypted partition
CRYPT_DEVICE=$(cryptsetup status cryptroot | grep device | awk '{print $2}')
CRYPT_UUID=$(blkid -s UUID -o value $CRYPT_DEVICE)

echo "Encrypted partition device: $CRYPT_DEVICE"
echo "Encrypted partition UUID: $CRYPT_UUID"

# Create script for chroot execution
cat > /mnt/chroot-setup.sh << 'CHROOT_EOF'
#!/bin/bash

echo "======================================"
echo "  System Configuration (chroot)      "
echo "======================================"
echo

# Variables passed from main script
KEYBOARD="__KEYBOARD__"
LOCALE="__LOCALE__"
TIMEZONE="__TIMEZONE__"
CRYPT_UUID="__CRYPT_UUID__"

# ========================================
# 1. TIMEZONE
# ========================================
echo "[1/16] Configuring timezone..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "✓ Timezone: $TIMEZONE"

# ========================================
# 2. LOCALIZATION
# ========================================
echo "[2/16] Configuring locale..."
sed -i "s/^#$LOCALE/$LOCALE/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "✓ Locale: $LOCALE"

# ========================================
# 3. KEYBOARD
# ========================================
echo "[3/16] Configuring keyboard..."
cat > /etc/vconsole.conf << EOF
KEYMAP=$KEYBOARD
FONT=ter-118n
FONT_MAP=8859-1_to_uni
EOF
echo "✓ Keyboard: $KEYBOARD"

# ========================================
# 4. HOSTNAME
# ========================================
echo "[4/16] Configuring hostname..."
read -p "Enter system hostname: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "✓ Hostname: $HOSTNAME"

# ========================================
# 5. MKINITCPIO (LUKS)
# ========================================
echo "[5/16] Configuring mkinitcpio for LUKS..."

# Backup original
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.backup

# Modify HOOKS to include keyboard, keymap and encrypt
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf

echo "✓ HOOKS configured for LUKS"
echo "Regenerating initramfs..."
mkinitcpio -P

# ========================================
# 6. ROOT PASSWORD
# ========================================
echo "[6/16] Setting root password..."
echo "Enter password for root user:"
passwd

# ========================================
# 7. USER CREATION
# ========================================
echo "[7/16] Creating regular user..."
read -p "Do you want to create a regular user? (yes/no) [yes]: " CREATE_USER
CREATE_USER=${CREATE_USER:-yes}

if [ "$CREATE_USER" == "yes" ]; then
    read -p "Username: " USERNAME
    useradd -m -G wheel,storage,power,audio,video -s /bin/bash $USERNAME
    echo "Set password for $USERNAME:"
    passwd $USERNAME
    
    # Enable sudo for wheel group
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    
    echo "✓ User $USERNAME created with sudo privileges"
fi

# ========================================
# 8. GRUB CONFIGURATION
# ========================================
echo "[8/16] Configuring GRUB..."

# Modify /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub

# Enable os-prober for dual boot
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

echo "✓ GRUB configured for LUKS"

# ========================================
# 9. GRUB INSTALLATION
# ========================================
echo "[9/16] Installing GRUB to EFI..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

echo "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "✓ GRUB installed and configured"

# ========================================
# 10. DESKTOP ENVIRONMENT INSTALLATION
# ========================================
echo "[10/16] Installing GNOME Desktop Environment..."
echo "This will install GNOME, GDM, and Chromium..."
echo "This may take several minutes..."

pacman -S --noconfirm gnome gnome-extra gdm chromium

if [ $? -ne 0 ]; then
    echo "⚠️  WARNING: Desktop environment installation encountered issues"
    echo "You can install manually later with: pacman -S gnome gnome-extra gdm chromium"
else
    echo "✓ GNOME Desktop Environment installed"
fi

# ========================================
# 11. ADDITIONAL FONTS
# ========================================
echo "[11/16] Installing additional fonts..."
pacman -S --noconfirm ttf-dejavu ttf-liberation noto-fonts

if [ $? -eq 0 ]; then
    echo "✓ Additional fonts installed"
else
    echo "⚠️  Warning: Font installation had issues"
fi

# ========================================
# 12. VIDEO DRIVERS DETECTION AND INSTALLATION
# ========================================
echo "[12/16] Detecting and installing video drivers..."

# Detect GPU
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

# ========================================
# 13. FIREWALL CONFIGURATION
# ========================================
echo "[13/16] Installing and configuring firewall..."
pacman -S --noconfirm ufw

if [ $? -eq 0 ]; then
    systemctl enable ufw
    # UFW will be enabled after first boot to avoid network issues during installation
    echo "✓ UFW firewall installed and enabled"
    echo "Note: UFW will be activated after first boot"
else
    echo "⚠️  Warning: UFW installation failed"
fi

# ========================================
# 14. BTRFS SNAPSHOTS CONFIGURATION
# ========================================
echo "[14/16] Installing and configuring Btrfs snapshots..."
pacman -S --noconfirm snapper snap-pac

if [ $? -eq 0 ]; then
    # Check if btrfs subvolumes were created
    if btrfs subvolume list / | grep -q "@"; then
        # Delete default .snapshots subvolume if it exists to avoid conflicts
        if [ -d "/.snapshots" ]; then
            umount /.snapshots 2>/dev/null
            rmdir /.snapshots 2>/dev/null
        fi
        
        # Create snapper config for root
        snapper -c root create-config /
        
        # Remove snapper's auto-created subvolume and use our existing one
        btrfs subvolume delete /.snapshots 2>/dev/null
        mkdir -p /.snapshots
        
        # The @snapshots subvolume should already be mounted from the main script
        
        # Configure snapper for home if @home subvolume exists
        if btrfs subvolume list /home | grep -q "@home" || btrfs subvolume list / | grep -q "@home"; then
            snapper -c home create-config /home
            echo "✓ Snapper configured for root and home"
        else
            echo "✓ Snapper configured for root"
        fi
        
        # Set permissions
        chmod 750 /.snapshots
        
        # Configure automatic snapshots
        sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root
        
        # Enable snapper timers
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

# ========================================
# 15. SSD TRIM CONFIGURATION
# ========================================
echo "[15/16] Configuring SSD TRIM..."

# Check if disk is SSD
DISK_ROTATIONAL=$(cat /sys/block/$(basename $(readlink -f /dev/mapper/cryptroot) | sed 's/[0-9]*$//p' | sed 's/p$//' | tail -1)/queue/rotational 2>/dev/null)

if [ "$DISK_ROTATIONAL" = "0" ]; then
    echo "SSD detected. Enabling periodic TRIM..."
    systemctl enable fstrim.timer
    echo "✓ TRIM timer enabled for SSD optimization"
else
    echo "HDD detected or unable to detect disk type. Skipping TRIM configuration."
fi

# ========================================
# 16. ENABLING SERVICES
# ========================================
echo "[16/16] Enabling system services..."
systemctl enable NetworkManager
systemctl enable gdm

echo "✓ NetworkManager enabled"
echo "✓ GDM (GNOME Display Manager) enabled"

# ========================================
# POST-INSTALL SCRIPT FOR USER (AUTO-RUN AT BOOT)
# ========================================
echo
echo "Creating automatic post-install setup (pre-login)..."

# Create the main post-install script
cat > /home/$USERNAME/post-install-user.sh << 'USER_SCRIPT_EOF'
#!/bin/bash

# Log file for debugging
LOGFILE="/home/__USERNAME__/post-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "======================================"
echo "  Post-Installation User Setup       "
echo "======================================"
echo "Starting at: $(date)"
echo

# Wait for network to be ready
echo "Waiting for network connection..."
for i in {1..60}; do
    if ping -c 1 8.8.8.8 &> /dev/null; then
        echo "✓ Network is ready"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "⚠️  Network timeout - installation may fail"
        echo "NETWORK_FAILED" > /tmp/post-install-status
        exit 1
    fi
    sleep 2
done

# ========================================
# 1. INSTALL YAY (AUR HELPER)
# ========================================
echo "[1/3] Installing yay (AUR helper)..."
cd /home/__USERNAME__
sudo -u __USERNAME__ git clone https://aur.archlinux.org/yay.git
cd yay
sudo -u __USERNAME__ makepkg -si --noconfirm
cd ..
rm -rf yay

if command -v yay &> /dev/null; then
    echo "✓ yay installed successfully"
else
    echo "⚠️  yay installation failed"
    echo "YAY_FAILED" > /tmp/post-install-status
    exit 1
fi

# ========================================
# 2. INSTALL BETTERBIRD
# ========================================
echo "[2/3] Installing Betterbird..."
sudo -u __USERNAME__ yay -S --noconfirm betterbird-bin

if [ $? -eq 0 ]; then
    echo "✓ Betterbird installed successfully"
else
    echo "⚠️  Betterbird installation failed (continuing anyway)"
fi

# ========================================
# 3. ENABLE UFW FIREWALL
# ========================================
echo "[3/3] Enabling UFW firewall..."
ufw --force enable

if [ $? -eq 0 ]; then
    echo "✓ UFW firewall enabled"
else
    echo "⚠️  UFW enable failed"
fi

# ========================================
# COMPLETION
# ========================================
echo
echo "======================================"
echo "✓ Post-installation completed!"
echo "======================================"
echo "Completed at: $(date)"
echo
echo "Installed applications:"
echo "  ✓ yay (AUR helper)"
echo "  ✓ Betterbird (email client)"
echo "  ✓ UFW firewall (enabled)"
echo
echo "Log saved to: $LOGFILE"
echo

# Create success flag file
cat > /tmp/post-install-status << EOF
SUCCESS
Installed at: $(date)

✓ yay (AUR helper)
✓ Betterbird (email client)  
✓ UFW firewall
EOF

# Make the flag readable by the user
chown __USERNAME__:__USERNAME__ /tmp/post-install-status

# Disable the systemd service so it doesn't run again
systemctl disable arch-post-install.service

# Remove the service file
rm -f /etc/systemd/system/arch-post-install.service

# Remove this script
rm -- "$0"

USER_SCRIPT_EOF

# Replace username placeholder in script
sed -i "s|__USERNAME__|$USERNAME|g" /home/$USERNAME/post-install-user.sh

# Make the script executable
chmod +x /home/$USERNAME/post-install-user.sh
chown root:root /home/$USERNAME/post-install-user.sh

# Create systemd SYSTEM service that runs at boot (before GDM)
cat > /mnt/etc/systemd/system/arch-post-install.service << 'SERVICE_EOF'
[Unit]
Description=Arch Linux Post-Installation Setup (Pre-Login)
After=network-online.target
Wants=network-online.target
Before=gdm.service

[Service]
Type=oneshot
ExecStart=/home/__USERNAME__/post-install-user.sh
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Replace username placeholder
sed -i "s|__USERNAME__|$USERNAME|g" /mnt/etc/systemd/system/arch-post-install.service

# Enable the service (will run at first boot)
arch-chroot /mnt systemctl enable arch-post-install.service

echo "✓ Automatic post-install service created and enabled"
echo "✓ Service will run automatically at first boot (before login)"

# Create a user service to show notification after first login
mkdir -p /home/$USERNAME/.config/systemd/user

cat > /home/$USERNAME/.config/systemd/user/post-install-notify.service << 'NOTIFY_SERVICE_EOF'
[Unit]
Description=Show post-installation notification
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=/home/__USERNAME__/show-post-install-notification.sh
RemainAfterExit=yes

[Install]
WantedBy=default.target
NOTIFY_SERVICE_EOF

# Create notification script
cat > /home/$USERNAME/show-post-install-notification.sh << 'NOTIFY_SCRIPT_EOF'
#!/bin/bash

# Check if post-install was successful
if [ -f /tmp/post-install-status ]; then
    STATUS=$(cat /tmp/post-install-status)
    
    if echo "$STATUS" | grep -q "SUCCESS"; then
        notify-send "Welcome to Arch Linux!" "✓ System setup completed successfully\n\n$(tail -n +3 /tmp/post-install-status)\n\nYour system is ready to use!" -u normal -t 15000 -i dialog-information
    else
        notify-send "Post-Installation" "⚠️  Some components failed to install\n\nCheck ~/post-install.log for details" -u critical -t 10000 -i dialog-warning
    fi
    
    # Clean up
    rm -f /tmp/post-install-status
fi

# Disable this service after first run
systemctl --user disable post-install-notify.service
rm -f ~/.config/systemd/user/post-install-notify.service
rm -f "$0"
NOTIFY_SCRIPT_EOF

# Replace username placeholder
sed -i "s|__USERNAME__|$USERNAME|g" /home/$USERNAME/.config/systemd/user/post-install-notify.service
sed -i "s|__USERNAME__|$USERNAME|g" /home/$USERNAME/show-post-install-notification.sh

# Set permissions
chmod +x /home/$USERNAME/show-post-install-notification.sh
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
chown $USERNAME:$USERNAME /home/$USERNAME/show-post-install-notification.sh

# Enable notification service
arch-chroot /mnt sudo -u $USERNAME systemctl --user enable post-install-notify.service

echo "✓ Post-login notification service created"

# ========================================
# POST-INSTALL NOTES
# ========================================
echo
echo "Creating comprehensive post-install notes..."

cat > /root/POST_INSTALL_NOTES.txt << 'NOTES_EOF'
==========================================
   POST-INSTALLATION NOTES
==========================================

=== ✓ COMPLETED DURING INSTALLATION ===

System Configuration:
  ✓ GNOME Desktop Environment
  ✓ GDM Display Manager (auto-start on boot)
  ✓ Chromium browser
  ✓ NetworkManager
  ✓ Additional fonts (DejaVu, Liberation, Noto)
  
Video Drivers:
  ✓ GPU drivers detected and installed automatically
  
Filesystem:
  ✓ Btrfs with subvolumes (@, @home, @snapshots, @log)
  ✓ Snapper configured for automatic snapshots
    - Hourly: 5 snapshots retained
    - Daily: 7 snapshots retained
  ✓ SSD TRIM enabled (if SSD detected)
  
Security:
  ✓ UFW firewall installed (to be enabled after first login)
  ✓ LUKS2 full disk encryption

=== ⚠️  AUTOMATIC POST-INSTALLATION ===

IMPORTANT: At FIRST BOOT (before login screen):

The system will automatically install additional components:
  ✓ yay (AUR helper)
  ✓ Betterbird (email client)
  ✓ UFW firewall

This happens BEFORE the login screen appears.
The first boot may take 5-10 minutes longer than usual.

When you see the GDM login screen, everything is ready!
After login, you'll see a notification confirming the setup.

The installation process is logged to: ~/post-install.log

=== MANUAL POST-INSTALLATION STEPS ===

System Updates:
  sudo pacman -Syu

GNOME Extensions (optional):
  sudo pacman -S gnome-browser-connector
  Visit: https://extensions.gnome.org
  Recommended:
    - Dash to Dock
    - AppIndicator Support
    - Clipboard Indicator

Additional Software (examples):
  yay -S visual-studio-code-bin     # VS Code
  yay -S spotify                     # Spotify
  yay -S discord                     # Discord
  sudo pacman -S libreoffice-fresh   # LibreOffice
  sudo pacman -S gimp                # GIMP
  sudo pacman -S vlc                 # VLC media player

Firewall Management:
  sudo ufw status                    # Check status
  sudo ufw allow 22/tcp              # Allow SSH (example)
  sudo ufw deny 80/tcp               # Deny HTTP (example)

Snapshot Management:
  sudo snapper list                  # List snapshots
  sudo snapper create -d "Description"  # Manual snapshot
  sudo snapper delete SNAPSHOT_NUM   # Delete snapshot

=== SYSTEM INFORMATION ===
Desktop: GNOME
Display Manager: GDM
Browser: Chromium
Email: Betterbird (install via post-install script)
Terminal: GNOME Terminal
File Manager: Nautilus
Firewall: UFW
Snapshots: Snapper + snap-pac
AUR Helper: yay (install via post-install script)

==========================================
NOTES_EOF

echo "✓ Post-install notes saved to /root/POST_INSTALL_NOTES.txt"

# Also create notes for the user
cp /root/POST_INSTALL_NOTES.txt /home/$USERNAME/POST_INSTALL_NOTES.txt
chown $USERNAME:$USERNAME /home/$USERNAME/POST_INSTALL_NOTES.txt

# ========================================
# FINAL SUMMARY
# ========================================
echo
echo "======================================"
echo "✓ Configuration completed!"
echo "======================================"
echo
echo "=== Summary ==="
echo "  Timezone: $TIMEZONE"
echo "  Locale: $LOCALE"
echo "  Keyboard: $KEYBOARD"
echo "  Hostname: $(cat /etc/hostname)"
echo "  Bootloader: GRUB (EFI)"
echo "  Filesystem: Btrfs + LUKS"
echo "  Desktop: GNOME + GDM"
echo "  Browser: Chromium"
echo "  Snapshots: Snapper (configured)"
echo "  Firewall: UFW (to enable after login)"
echo "  Video: Drivers auto-detected"
echo "  Fonts: Extended collection"
echo
echo "=== ⚠️  IMPORTANT: After First Login ==="
echo "Post-installation runs AUTOMATICALLY at first boot!"
echo
echo "The first boot will take 5-10 minutes longer because:"
echo "  - yay (AUR helper) is being installed"
echo "  - Betterbird (email client) is being installed"
echo "  - UFW firewall is being enabled"
echo
echo "This all happens BEFORE you see the login screen."
echo "When GDM appears, everything is ready!"
echo "After login, you'll see a notification confirming success."
echo
echo "=== Next Steps ==="
echo "1. Exit chroot: exit"
echo "2. Unmount partitions: umount -R /mnt"
echo "3. Close LUKS: cryptsetup close cryptroot"
echo "4. Reboot: reboot"
echo
echo "After reboot:"
echo "  - Enter LUKS password"
echo "  - Login with your user credentials"
echo "  - Run the post-installation script!"
echo

CHROOT_EOF

# Replace placeholders with actual values
sed -i "s|__KEYBOARD__|$KEYBOARD|g" /mnt/chroot-setup.sh
sed -i "s|__LOCALE__|$LOCALE|g" /mnt/chroot-setup.sh
sed -i "s|__TIMEZONE__|$TIMEZONE|g" /mnt/chroot-setup.sh
sed -i "s|__CRYPT_UUID__|$CRYPT_UUID|g" /mnt/chroot-setup.sh

chmod +x /mnt/chroot-setup.sh

echo "✓ Chroot script prepared"
echo

# ========================================
# 15. CHROOT EXECUTION
# ========================================
echo "[4/5] Running configuration in chroot..."
echo "--------------------------------------"
echo

arch-chroot /mnt /chroot-setup.sh

if [ $? -ne 0 ]; then
    echo
    echo "⚠️  WARNING: An error occurred in chroot"
    echo "The script is available at /mnt/chroot-setup.sh"
    echo "You can enter manually with: arch-chroot /mnt"
    exit 1
fi

# ========================================
# 16. CLEANUP AND FINAL INSTRUCTIONS
# ========================================
echo
echo "[5/5] Installation completed!"
echo

# Remove temporary script
rm /mnt/chroot-setup.sh

echo "======================================"
echo "✓ INSTALLATION COMPLETED!"
echo "======================================"
echo
echo "=== What Was Configured ==="
echo "✓ Base system + Linux kernel"
echo "✓ GNOME Desktop Environment"
echo "✓ Video drivers (auto-detected)"
echo "✓ Additional fonts"
echo "✓ Btrfs snapshots with Snapper"
echo "✓ SSD TRIM (if applicable)"
echo "✓ UFW firewall (installed, to enable after login)"
echo "✓ Chromium browser"
echo
echo "=== ⚠️  FIRST BOOT INFORMATION ==="
echo "✓ Post-installation will run AUTOMATICALLY at first boot!"
echo
echo "Before the login screen appears, the system will:"
echo "  - Install yay (AUR helper)"
echo "  - Install Betterbird (email client)"
echo "  - Enable UFW firewall"
echo
echo "⚠️  First boot takes 5-10 minutes longer than normal"
echo "When you see GDM login screen, everything is ready!"
echo "After login, you'll see a success notification."
echo
echo "=== To Complete Installation ==="
echo "1. Unmount partitions:"
echo "   umount -R /mnt"
echo "   swapoff -a"
echo "   cryptsetup close cryptroot"
echo
echo "2. Reboot the system:"
echo "   reboot"
echo
echo "3. After reboot:"
echo "   - Enter LUKS password"
echo "   - Wait 5-10 minutes (post-install running in background)"
echo "   - GDM login screen will appear when ready"
echo "   - Login with your user"
echo "   - You'll see a success notification!"
echo

read -p "Do you want to unmount partitions now? (yes/no) [no]: " UNMOUNT_NOW
UNMOUNT_NOW=${UNMOUNT_NOW:-no}

if [ "$UNMOUNT_NOW" == "yes" ]; then
    echo "Unmounting partitions..."
    umount -R /mnt
    swapoff -a
    cryptsetup close cryptroot
    echo "✓ Partitions unmounted. You can reboot with: reboot"
else
    echo
    echo "Remember to unmount manually before rebooting!"
fi