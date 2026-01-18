#!/usr/bin/env bash
# Nuclear option for PipeWire - when normal reset fails
# This aggressively kills everything and cleans all state

set -euo pipefail

LOG() { echo "$(date +'%F %T') $*"; }

# ============================================================================
# Exclude specific devices from volume setting (same patterns as reset-pipewire)
# These devices will be muted instead of set to 100%
# Example: EXCLUDE_PATTERNS=("Jieli_Technology" "clock" "USB_Speaker")
# ============================================================================
EXCLUDE_PATTERNS=()

# Helper function to check if a sink should be excluded
is_excluded() {
    local sink="$1"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$sink" == *"$pattern"* ]]; then
            return 0  # Excluded
        fi
    done
    return 1  # Not excluded
}

LOG "=== NUCLEAR PIPEWIRE RESET ==="
LOG "This will forcefully kill all audio processes and clean all state"
LOG ""

# Kill everything audio-related
LOG "Killing all PipeWire/WirePlumber processes..."
pkill -9 pipewire 2>/dev/null || true
pkill -9 wireplumber 2>/dev/null || true
pkill -9 pipewire-pulse 2>/dev/null || true
pkill -9 pipewire-media-session 2>/dev/null || true

sleep 2

# Clean all runtime state
LOG "Cleaning runtime directories..."
rm -rf "${XDG_RUNTIME_DIR:-/run/user/$UID}"/pipewire* 2>/dev/null || true
rm -rf "${XDG_RUNTIME_DIR:-/run/user/$UID}"/pulse* 2>/dev/null || true
rm -rf "${XDG_RUNTIME_DIR:-/run/user/$UID}"/pw-* 2>/dev/null || true

# Clean WirePlumber state
LOG "Cleaning WirePlumber state..."
rm -rf ~/.local/state/wireplumber/* 2>/dev/null || true

# Clean PipeWire state
LOG "Cleaning PipeWire state..."
rm -rf ~/.local/state/pipewire 2>/dev/null || true

# Stop all systemd services
LOG "Stopping systemd services..."
systemctl --user stop pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service wireplumber.service 2>/dev/null || true

sleep 2

# Reload kernel audio modules (requires sudo)
if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
    LOG "Reloading ALSA kernel modules..."
    sudo modprobe -r snd_seq_dummy 2>/dev/null || true
    sudo modprobe -r snd_hda_intel 2>/dev/null || true
    sleep 1
    sudo modprobe snd_hda_intel 2>/dev/null || true
    LOG "Kernel modules reloaded"
else
    LOG "Skipping kernel module reload (no sudo access)"
fi

sleep 2

# Start services
LOG "Starting PipeWire services..."
systemctl --user start pipewire.socket pipewire-pulse.socket
sleep 3

# Wait for PipeWire to be ready
LOG "Waiting for PipeWire to initialize..."
for i in {1..10}; do
    if pactl info >/dev/null 2>&1; then
        LOG "PipeWire is ready!"
        break
    fi
    LOG "  Attempt $i/10..."
    sleep 2
done

# Disable excluded devices completely (set profile to off)
LOG ""
LOG "Disabling excluded audio devices..."
while IFS= read -r card_name; do
    if is_excluded "$card_name"; then
        LOG "  Disabling card '$card_name'"
        pactl set-card-profile "$card_name" off 2>/dev/null || true
    fi
done < <(pactl list short cards 2>/dev/null | awk '{print $2}')

# Restore analog profiles for USB devices (WirePlumber resets to digital by default)
LOG ""
LOG "Restoring analog profiles for USB audio devices..."
while IFS= read -r card; do
    # Skip excluded devices
    if is_excluded "$card"; then
        continue
    fi
    if pactl list cards | grep -A1 "Name: $card" | grep -q "usb-"; then
        # Check if analog-stereo profile is available
        if pactl list cards | grep -A50 "Name: $card" | grep -q "output:analog-stereo:"; then
            LOG "  Setting $card to analog-stereo"
            pactl set-card-profile "$card" output:analog-stereo 2>/dev/null || true
        fi
    fi
done < <(pactl list short cards | awk '{print $2}')

sleep 2

# Show status
LOG ""
LOG "Current audio status:"
if pactl list short sinks 2>/dev/null | head -10; then
    LOG ""
    LOG "=== Nuclear reset complete! ==="
    LOG ""
    
    # Set audio devices to 100% volume (respecting exclusions)
    LOG "Setting audio devices to 100% volume (excluded devices will be muted)..."
    
    # Set all sinks to 100% (or mute if excluded)
    while IFS= read -r sink; do
        if [ -n "$sink" ]; then
            if is_excluded "$sink"; then
                LOG "  Muting excluded sink: $sink"
                pactl set-sink-mute "$sink" 1 2>/dev/null || true
                pactl set-sink-volume "$sink" 0% 2>/dev/null || true
            else
                LOG "  Setting sink $sink to 100%"
                pactl set-sink-volume "$sink" 100% 2>/dev/null || true
                pactl set-sink-mute "$sink" 0 2>/dev/null || true
            fi
        fi
    done < <(pactl list short sinks | awk '{print $2}')
    
    # Set all sources (microphones/inputs) to 100%
    while IFS= read -r source; do
        # Skip monitors (they're output monitors, not real inputs)
        if [[ ! "$source" =~ \.monitor$ ]]; then
            LOG "  Setting source $source to 100%"
            pactl set-source-volume "$source" 100% 2>/dev/null || true
            pactl set-source-mute "$source" 0 2>/dev/null || true
        fi
    done < <(pactl list short sources | awk '{print $2}')
    
    sleep 1
    
    # Automatically recreate combined sink
    if [ -x "$HOME/.local/bin/reset-pipewire" ]; then
        LOG ""
        LOG "Recreating combined sink and applying configurations..."
        "$HOME/.local/bin/reset-pipewire"
        LOG ""
        LOG "=== Nuclear reset with sink recreation complete! ==="
    else
        LOG ""
        LOG "WARNING: reset-pipewire not found in ~/.local/bin/"
        LOG "Please run: reset-pipewire"
        LOG "to recreate your combined sink"
    fi
else
    LOG ""
    LOG "ERROR: PipeWire still not responding"
    LOG "You may need to reboot"
    exit 1
fi
