#!/bin/bash

echo "======================================"
echo "  Arch Linux Automated Installer    "
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
# export LC_ALL="$LOCALE" ## Commented to avoid LC_ALL error
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
    terminus-font

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

# Find UUID of encrypted partition (FIXED)
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
echo "[1/11] Configuring timezone..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "✓ Timezone: $TIMEZONE"

# ========================================
# 2. LOCALIZATION
# ========================================
echo "[2/11] Configuring locale..."
sed -i "s/^#$LOCALE/$LOCALE/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "✓ Locale: $LOCALE"

# ========================================
# 3. KEYBOARD
# ========================================
echo "[3/11] Configuring keyboard..."
cat > /etc/vconsole.conf << EOF
KEYMAP=$KEYBOARD
FONT=ter-118n
FONT_MAP=8859-1_to_uni
EOF
echo "✓ Keyboard: $KEYBOARD"

# ========================================
# 4. HOSTNAME
# ========================================
echo "[4/11] Configuring hostname..."
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
echo "[5/11] Configuring mkinitcpio for LUKS..."

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
echo "[6/11] Setting root password..."
echo "Enter password for root user:"
passwd

# ========================================
# 7. USER CREATION
# ========================================
echo "[7/11] Creating regular user..."
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
echo "[8/11] Configuring GRUB..."

# Modify /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub

# Enable os-prober for dual boot
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

echo "✓ GRUB configured for LUKS"

# ========================================
# 9. GRUB INSTALLATION
# ========================================
echo "[9/11] Installing GRUB to EFI..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

echo "[10/11] Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "✓ GRUB installed and configured"

# ========================================
# 10. ENABLING SERVICES
# ========================================
echo "[11/11] Enabling network services..."
systemctl enable NetworkManager

echo "✓ NetworkManager enabled"

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
echo
echo "=== Next Steps ==="
echo "1. Exit chroot: exit"
echo "2. Unmount partitions: umount -R /mnt"
echo "3. Close LUKS: cryptsetup close cryptroot"
echo "4. Reboot: reboot"
echo
echo "After reboot:"
echo "  - You will be prompted for LUKS password"
echo "  - Login with root or created user"
echo "  - Connect to network: nmtui or nmcli"
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
    echo "⚠ WARNING: An error occurred in chroot"
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
echo "=== To Complete ==="
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
echo "   - Login with created credentials"
echo "   - Connect to network: nmtui"
echo
echo "=== Recommended Post-Installation ==="
echo "- Install desktop environment: pacman -S xorg gnome"
echo "- Configure firewall: pacman -S ufw && ufw enable"
echo "- Install appropriate video drivers"
echo "- Configure btrfs snapshots: pacman -S snapper"
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