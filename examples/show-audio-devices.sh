#!/usr/bin/env bash
# Show all audio devices and which ones will be used in combined sink

set -euo pipefail

echo "=== All Audio Sinks ==="
pactl list short sinks | nl -w2 -s'. '

echo ""
echo "=== Devices Currently in Combined Sink ==="
if pactl list sinks short | grep -q "combined_out"; then
    combined_slaves=$(pactl list sinks | grep -A 20 "Name: combined_out" | grep "device.master_device" | sed 's/.*= "\(.*\)"/\1/')
    if [ -n "$combined_slaves" ]; then
        echo "$combined_slaves" | tr ',' '\n' | nl -w2 -s'. '
    else
        echo "No slaves detected (combined sink may not be loaded)"
    fi
else
    echo "Combined sink not currently loaded"
fi

echo ""
echo "=== To exclude a device ==="
echo "Edit reset_pipewire.sh and uncomment/modify the EXCLUDE_PATTERNS line:"
echo "  EXCLUDE_PATTERNS=(\"Jieli_Technology\")"
echo ""
echo "Then run: reset-pipewire"
