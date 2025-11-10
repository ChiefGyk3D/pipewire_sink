#!/usr/bin/env bash
# Quick reset for RØDECaster Pro that's connected but not playing audio
# This unbinds and rebinds the USB device without physically unplugging it

set -euo pipefail

LOG() { echo "$(date +'%F %T') $*"; }

# Find RØDECaster device
RODECASTER=$(lsusb | grep -i "rode" | head -1)

if [ -z "$RODECASTER" ]; then
    LOG "ERROR: RØDECaster not found. Is it connected?"
    exit 1
fi

# Extract bus and device number
BUS=$(echo "$RODECASTER" | awk '{print $2}')
DEV=$(echo "$RODECASTER" | awk '{print $4}' | tr -d ':')

LOG "Found RØDECaster: $RODECASTER"
LOG "Bus $BUS, Device $DEV"

# Find the USB device path in sysfs
USB_PATH=$(find /sys/bus/usb/devices -name "${BUS}-*" -type d 2>/dev/null | head -1)

if [ -z "$USB_PATH" ]; then
    LOG "ERROR: Could not find USB device path in sysfs"
    exit 1
fi

# Get the driver being used
DRIVER=$(basename "$(readlink -f "$USB_PATH/driver" 2>/dev/null)" 2>/dev/null || echo "unknown")
LOG "Using driver: $DRIVER"

# Unbind the device
LOG "Unbinding device..."
echo "$BUS-$DEV" | sudo tee /sys/bus/usb/drivers/$DRIVER/unbind >/dev/null 2>&1 || {
    # Try alternative path
    DEVICE_NAME=$(basename "$USB_PATH")
    LOG "Trying alternative unbind with device name: $DEVICE_NAME"
    echo "$DEVICE_NAME" | sudo tee "$USB_PATH/driver/unbind" >/dev/null 2>&1 || {
        LOG "ERROR: Failed to unbind device. You may need to run with sudo"
        exit 1
    }
}

sleep 2

# Rebind the device
LOG "Rebinding device..."
echo "$BUS-$DEV" | sudo tee /sys/bus/usb/drivers/$DRIVER/bind >/dev/null 2>&1 || {
    DEVICE_NAME=$(basename "$USB_PATH")
    echo "$DEVICE_NAME" | sudo tee "$USB_PATH/driver/bind" >/dev/null 2>&1 || {
        LOG "ERROR: Failed to rebind device"
        exit 1
    }
}

LOG "Device reset complete. Waiting for audio system to recognize it..."
sleep 3

# Now run the PipeWire reset script if available
if [ -x "$HOME/.local/bin/reset-pipewire" ]; then
    LOG "Running PipeWire reset to recreate combined sink..."
    "$HOME/.local/bin/reset-pipewire"
else
    LOG "Note: reset-pipewire script not found. You may need to manually recreate your audio setup."
fi

LOG "Done! Your RØDECaster should now work."
