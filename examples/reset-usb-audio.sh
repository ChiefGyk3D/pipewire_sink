#!/usr/bin/env bash
# Reset USB audio device that's connected but not playing audio
# This deauthorizes and reauthorizes the USB device without physically unplugging it
#
# Usage:
#   sudo reset-rodecaster                    # Auto-detect RØDECaster Pro II
#   sudo reset-rodecaster 19f7:0026          # Specify VID:PID
#   sudo reset-rodecaster "RØDE"             # Find by device name
#
# Set AUTO_RESET_PIPEWIRE=0 to skip automatic PipeWire reset

set -euo pipefail

LOG() { echo "$(date +'%F %T') $*"; }

# Default to auto-reset PipeWire unless explicitly disabled
AUTO_RESET_PIPEWIRE="${AUTO_RESET_PIPEWIRE:-1}"

# Default device: RØDECaster Pro II
DEFAULT_VENDOR_ID="19f7"
DEFAULT_PRODUCT_ID="0026"
DEFAULT_NAME="RØDECaster Pro II"

VENDOR_ID=""
PRODUCT_ID=""
SEARCH_NAME=""

# Parse arguments
if [ $# -gt 0 ]; then
    if [[ "$1" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
        # Format: VID:PID
        VENDOR_ID="${1%%:*}"
        PRODUCT_ID="${1##*:}"
        LOG "Searching for device with VID:PID = ${VENDOR_ID}:${PRODUCT_ID}"
    else
        # Search by name
        SEARCH_NAME="$1"
        LOG "Searching for USB audio device matching: $SEARCH_NAME"
    fi
else
    # Use default
    VENDOR_ID="$DEFAULT_VENDOR_ID"
    PRODUCT_ID="$DEFAULT_PRODUCT_ID"
    LOG "Searching for $DEFAULT_NAME (VID:PID = ${VENDOR_ID}:${PRODUCT_ID})"
fi

# Find device in sysfs
USB_PATH=""
FOUND_DEVICE_NAME=""

for dev in /sys/bus/usb/devices/*; do
    if [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ]; then
        vid=$(cat "$dev/idVendor" 2>/dev/null || echo "")
        pid=$(cat "$dev/idProduct" 2>/dev/null || echo "")
        
        # Try to get product name
        product=$(cat "$dev/product" 2>/dev/null || echo "")
        
        # Check if this matches our search
        if [ -n "$VENDOR_ID" ] && [ -n "$PRODUCT_ID" ]; then
            # Search by VID:PID
            if [ "$vid" = "$VENDOR_ID" ] && [ "$pid" = "$PRODUCT_ID" ]; then
                USB_PATH="$dev"
                FOUND_DEVICE_NAME="$product"
                break
            fi
        elif [ -n "$SEARCH_NAME" ]; then
            # Search by name (case insensitive)
            if echo "$product" | grep -qi "$SEARCH_NAME"; then
                USB_PATH="$dev"
                FOUND_DEVICE_NAME="$product"
                VENDOR_ID="$vid"
                PRODUCT_ID="$pid"
                break
            fi
        fi
    fi
done

if [ -z "$USB_PATH" ]; then
    LOG "ERROR: USB audio device not found."
    LOG ""
    LOG "Available USB audio devices:"
    lsusb | grep -iE 'audio|rode|behringer|focusrite|scarlett|presonus|m-audio' || LOG "  No USB audio devices detected"
    LOG ""
    LOG "To reset a specific device, use:"
    LOG "  sudo reset-rodecaster VID:PID"
    LOG "  sudo reset-rodecaster \"Device Name\""
    exit 1
fi

DEVICE_NAME=$(basename "$USB_PATH")
LOG "Found device: $FOUND_DEVICE_NAME"
LOG "  VID:PID = ${VENDOR_ID}:${PRODUCT_ID}"
LOG "  Path = $DEVICE_NAME"

# Check if device has a driver bound
if [ ! -e "$USB_PATH/driver" ]; then
    LOG "WARNING: Device doesn't appear to have a driver bound"
    LOG "Device might already be in a disconnected state"
fi

# Method 1: Try to unbind using authorized flag (safest)
LOG "Deauthorizing device..."
if echo 0 | sudo tee "$USB_PATH/authorized" >/dev/null 2>&1; then
    LOG "Device deauthorized successfully"
    sleep 2
    
    LOG "Reauthorizing device..."
    if echo 1 | sudo tee "$USB_PATH/authorized" >/dev/null 2>&1; then
        LOG "Device reauthorized successfully"
    else
        LOG "ERROR: Failed to reauthorize device"
        exit 1
    fi
else
    LOG "Deauthorization failed, trying driver unbind method..."
    
    # Method 2: Unbind/rebind driver
    if [ -e "$USB_PATH/driver" ]; then
        DRIVER=$(basename "$(readlink -f "$USB_PATH/driver")")
        LOG "Unbinding from driver: $DRIVER"
        
        if echo "$DEVICE_NAME" | sudo tee "$USB_PATH/driver/unbind" >/dev/null 2>&1; then
            LOG "Device unbound successfully"
            sleep 2
            
            LOG "Rebinding to driver..."
            if echo "$DEVICE_NAME" | sudo tee "/sys/bus/usb/drivers/$DRIVER/bind" >/dev/null 2>&1; then
                LOG "Device rebound successfully"
            else
                LOG "ERROR: Failed to rebind device"
                exit 1
            fi
        else
            LOG "ERROR: Failed to unbind device"
            exit 1
        fi
    else
        LOG "ERROR: No driver found and deauthorization failed"
        exit 1
    fi
fi

LOG "Device reset complete. Waiting for audio system to recognize it..."
sleep 3

# Get the original user (in case running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
RESET_SCRIPT="$REAL_HOME/.local/bin/reset-pipewire"

LOG "USB device has been reset successfully."
LOG ""

# Automatically run PipeWire reset if enabled
if [ "$AUTO_RESET_PIPEWIRE" = "1" ]; then
    if [ -x "$RESET_SCRIPT" ]; then
        LOG "Resetting PipeWire and recreating combined sink..."
        LOG "(Set AUTO_RESET_PIPEWIRE=0 to disable automatic reset)"
        LOG ""
        
        # Create a script that will run as the user after we exit
        TEMP_SCRIPT=$(mktemp)
        cat > "$TEMP_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash
sleep 2  # Wait for sudo to finish
exec "$HOME/.local/bin/reset-pipewire"
EOFSCRIPT
        chmod +x "$TEMP_SCRIPT"
        chown "$REAL_USER:$(id -gn "$REAL_USER")" "$TEMP_SCRIPT" 2>/dev/null || true
        
        # Schedule it to run as the user after we exit
        if [ -n "${SUDO_USER:-}" ]; then
            # Run in background as the real user
            sudo -u "$SUDO_USER" bash -c "nohup '$TEMP_SCRIPT' > /dev/null 2>&1 & disown" &
            LOG "PipeWire reset scheduled to run automatically in 2 seconds..."
            LOG "Watch progress with: journalctl --user -f -u pipewire"
        else
            # Not running with sudo, run directly
            nohup "$RESET_SCRIPT" > /dev/null 2>&1 & disown
            LOG "PipeWire reset started in background..."
        fi
        
        LOG ""
        LOG "Done! USB device reset complete."
        LOG "PipeWire will reset automatically and recreate your combined sink."
    else
        LOG "Note: reset-pipewire script not found at $RESET_SCRIPT"
        LOG "Your audio devices should reappear automatically."
        LOG "If you had a combined sink, recreate it manually with: reset-pipewire"
    fi
else
    LOG "Automatic PipeWire reset disabled (AUTO_RESET_PIPEWIRE=0)."
    if [ -x "$RESET_SCRIPT" ]; then
        LOG "Run the following command to reset PipeWire and recreate the combined sink:"
        LOG "  reset-pipewire"
    else
        LOG "Your audio devices should reappear automatically."
    fi
fi
