# UTM Setup Instructions for Archetype Installer

## Step 1: Create UTM Virtual Machine

1. **Open UTM**
   ```bash
   open -a UTM
   ```

2. **Create New VM**
   - Click "+" → "Virtualize"
   - Select "Other"
   - Click "Browse" and select: `alpine-virt-3.22.2-aarch64.iso`

3. **Configure VM**
   - **Memory:** 2048 MB (minimum)
   - **CPU Cores:** 2
   - **Storage:** 20 GB (minimum)
   - Click "Save"

## Step 2: Start HTTP Server (keep this terminal open)

In your project directory, run:
```bash
python3 -m http.server 8000
```

This serves the installation script to the VM.

## Step 3: Boot Alpine in UTM

1. Start the VM
2. Wait for Alpine to boot to login prompt
3. Login as `root` (no password needed)

## Step 4: Run Auto-Installer

At the Alpine prompt, paste this one-liner:

```bash
setup-interfaces -a && rc-service networking restart && sleep 2 && wget -O - http://192.168.0.32:8000/step-by-step-no-encryption.sh | sh
```

Or step by step:
```bash
# Setup networking
setup-interfaces -a
rc-service networking restart

# Download and run the installer
wget -O /tmp/start.sh http://10.0.2.2:8000/alpine-autostart.sh
chmod +x /tmp/start.sh
/tmp/start.sh
```

## Step 5: Follow Installation Prompts

The installer will:
1. Setup Alpine environment
2. Download Arch Linux installation script
3. Prompt you for:
   - Target disk (usually `/dev/vda`)
   - Username and password
   - Timezone
4. Install Arch Linux ARM with Btrfs

## Step 6: Reboot

After installation completes:
1. Type `reboot`
2. In UTM, remove the CD/DVD (Alpine ISO)
3. Boot into your new Arch Linux system!

## Troubleshooting

### Network not working
```bash
# Check if interface is up
ip a

# Restart networking
setup-interfaces -a
rc-service networking restart

# Test connectivity
ping -c 3 google.com
```

### Can't reach host (10.0.2.2)
- Make sure HTTP server is running on your Mac
- UTM's default network should be NAT (automatic)
- Try accessing: `wget -O - http://10.0.2.2:8000/alpine-autostart.sh`

### Installation script not found (404)
- Make sure you're running `python3 -m http.server 8000` from the project directory
- Check that `step-by-step-no-encryption.sh` exists
- Check HTTP server output for access logs

## Quick Reference

**Alpine Login:** `root` (no password)

**One-liner installer:**
```bash
setup-interfaces -a && rc-service networking restart && sleep 2 && wget -O - http://10.0.2.2:8000/alpine-autostart.sh | sh
```

**Default disk in UTM:** `/dev/vda`

**After installation:**
- Remove Alpine ISO from VM
- Reboot
- Login with your created user
- Access via SSH: `ssh username@<vm-ip>`
