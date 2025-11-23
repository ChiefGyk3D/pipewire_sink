#!/usr/bin/env bash
# Capture complete audio system state for comparison

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${1:-audio-state-${TIMESTAMP}.txt}"

echo "Capturing audio state to: $OUTPUT_FILE"
echo "========================================" | tee "$OUTPUT_FILE"
echo "Audio System State Capture" | tee -a "$OUTPUT_FILE"
echo "Timestamp: $(date)" | tee -a "$OUTPUT_FILE"
echo "========================================" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

{
    echo "=== PIPEWIRE/WIREPLUMBER SERVICES ==="
    systemctl --user status pipewire.service pipewire-pulse.service wireplumber.service | grep -E "(Active:|Main PID:)"
    echo ""
    
    echo "=== USB DEVICES ==="
    lsusb | grep -i "audio\|rode\|focusrite\|behringer"
    echo ""
    
    echo "=== USB DEVICE DETAILS (R__DE) ==="
    for dev in /sys/bus/usb/devices/*; do
        if [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ]; then
            vid=$(cat "$dev/idVendor")
            pid=$(cat "$dev/idProduct")
            if [ "$vid" = "19f7" ] && [ "$pid" = "0026" ]; then
                echo "Device path: $dev"
                echo "  VID:PID = $vid:$pid"
                echo "  Authorized: $(cat $dev/authorized 2>/dev/null || echo 'N/A')"
                echo "  Product: $(cat $dev/product 2>/dev/null || echo 'N/A')"
                echo "  Manufacturer: $(cat $dev/manufacturer 2>/dev/null || echo 'N/A')"
            fi
        fi
    done
    echo ""
    
    echo "=== ALSA CARDS ==="
    cat /proc/asound/cards
    echo ""
    
    echo "=== PACTL LIST SHORT CARDS ==="
    pactl list short cards
    echo ""
    
    echo "=== CARD PROFILES (USB) ==="
    pactl list cards | grep -B 5 -A 100 "usb-" | head -120
    echo ""
    
    echo "=== PACTL LIST SHORT SINKS ==="
    pactl list short sinks
    echo ""
    
    echo "=== SINK DETAILS (USB) ==="
    pactl list sinks | grep -B 2 -A 40 "usb-"
    echo ""
    
    echo "=== PACTL LIST SHORT SOURCES ==="
    pactl list short sources
    echo ""
    
    echo "=== SOURCE DETAILS (USB) ==="
    pactl list sources | grep -B 2 -A 40 "usb-"
    echo ""
    
    echo "=== DEFAULT SINK ==="
    pactl get-default-sink
    echo ""
    
    echo "=== DEFAULT SOURCE ==="
    pactl get-default-source
    echo ""
    
    echo "=== COMBINED SINK MODULE ==="
    pactl list short modules | grep combine
    echo ""
    
    echo "=== COMBINED SINK DETAILS ==="
    pactl list sinks | grep -A 50 "Name: combined_out"
    echo ""
    
    echo "=== WIREPLUMBER STATE - default-profile ==="
    cat ~/.local/state/wireplumber/default-profile 2>/dev/null || echo "File not found"
    echo ""
    
    echo "=== WIREPLUMBER STATE - default-nodes ==="
    cat ~/.local/state/wireplumber/default-nodes 2>/dev/null || echo "File not found"
    echo ""
    
    echo "=== WIREPLUMBER STATE - default-routes ==="
    cat ~/.local/state/wireplumber/default-routes 2>/dev/null || echo "File not found"
    echo ""
    
    echo "=== PIPEWIRE RUNTIME FILES ==="
    ls -la ${XDG_RUNTIME_DIR}/pipewire-* 2>/dev/null || echo "No pipewire runtime files"
    echo ""
    
    echo "=== KERNEL MODULES ==="
    lsmod | grep -E "snd_usb_audio|snd_hda_intel|snd_pcm"
    echo ""
    
    echo "=== DMESG (last 50 lines, audio related) ==="
    if sudo -n dmesg >/dev/null 2>&1; then
        # Can use sudo without password
        sudo dmesg | grep -i "usb\|audio\|alsa" | tail -50
    elif dmesg >/dev/null 2>&1; then
        # Can read dmesg without sudo
        dmesg | grep -i "usb\|audio\|alsa" | tail -50
    else
        echo "(Skipped - requires sudo/root access. Run 'sudo dmesg | grep -i audio' manually if needed)"
    fi
    echo ""
    
} >> "$OUTPUT_FILE"

echo ""
echo "State captured successfully!"
echo "File: $OUTPUT_FILE"
