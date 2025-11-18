#!/usr/bin/env bash
set -euo pipefail

LOG() { printf '%s %s\n' "$(date +'%F %T')" "$*"; }

# ============================================================================
# Configuration: Set these to exact sink names from `pactl list short sinks`
# or leave empty for auto-detection.
#
# Common use cases:
# - PRIMARY_SINK: Your main audio device (USB DAC, speakers, etc.)
# - SECONDARY_SINK: Additional output (HDMI monitor, capture card, etc.)
#
# Examples:
#   PRIMARY_SINK="alsa_output.usb-Manufacturer_Device.analog-stereo"
#   SECONDARY_SINK="alsa_output.pci-0000_00_1f.3.hdmi-stereo"
#
# Environment variables:
# - CLEAN_STATE=1: Force clean WirePlumber state files (use if devices won't appear)
# - RESET_USB=1: Reset USB audio devices before restarting PipeWire (requires usbreset)
# ============================================================================
PRIMARY_SINK=""
SECONDARY_SINK=""

# Combined sink name and description (visible in audio settings)
COMBINED_SINK_NAME="combined_out"
COMBINED_SINK_DESCRIPTION="Combined Audio Output"

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}"
MODULE_ID_FILE="${HOME}/.local/state/reset_pipewire_combined_module_id"

# Services we try to restart (some may not exist on every system)
SERVICES=(pipewire.socket pipewire.service pipewire-pulse.service wireplumber.service)

check_sample_rate_config() {
    # Check if 48kHz sample rate config exists, offer to install if missing
    local config_dir="${HOME}/.config/pipewire/pipewire.conf.d"
    local config_file="${config_dir}/99-custom-rate.conf"
    
    # Check current sample rates
    local mismatched=0
    if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
        # Check if any sinks are not at 48000Hz
        if pactl list short sinks 2>/dev/null | grep -v "48000Hz" | grep -qE "[0-9]+Hz"; then
            mismatched=1
        fi
    fi
    
    # If config doesn't exist and we detected mismatched rates, create it
    if [ ! -f "$config_file" ] && [ $mismatched -eq 1 ]; then
        LOG "⚠️  Detected sample rate mismatch (not all devices at 48kHz)"
        LOG "   This can cause pitch shifting with HDMI capture cards!"
        LOG ""
        LOG "Creating 48kHz sample rate config at: $config_file"
        
        mkdir -p "$config_dir"
        cat > "$config_file" << 'EOF'
# Force 48kHz sample rate for all devices to prevent pitch shifting
# This is especially important for HDMI capture cards and mixed USB/PCI audio setups

context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 48000 ]
}
EOF
        LOG "✓ Sample rate config created (will apply after PipeWire restart)"
    elif [ ! -f "$config_file" ]; then
        LOG "ℹ️  Tip: For best results, ensure all devices run at 48kHz"
        LOG "   Sample rate config template available in examples/99-custom-rate.conf"
    fi
}

reset_usb_audio_devices() {
    # Try to reset USB audio devices that might be in a stuck state
    # This requires usbreset utility or manual unbind/bind
    
    if [ "${RESET_USB:-}" != "1" ]; then
        return 0
    fi
    
    LOG "Attempting to reset USB audio devices..."
    
    # Find USB audio devices
    local usb_audio_devices
    usb_audio_devices=$(lsusb | grep -iE 'audio|rode|behringer|focusrite|scarlett|presonus|m-audio' || true)
    
    if [ -z "$usb_audio_devices" ]; then
        LOG "No USB audio devices found to reset"
        return 0
    fi
    
    # Try using usbreset if available
    if command -v usbreset >/dev/null 2>&1; then
        echo "$usb_audio_devices" | while read -r line; do
            bus=$(echo "$line" | awk '{print $2}')
            device=$(echo "$line" | awk '{print $4}' | tr -d ':')
            device_name=$(echo "$line" | cut -d' ' -f7-)
            LOG "Resetting USB device: $device_name (Bus $bus Device $device)"
            sudo usbreset "/dev/bus/usb/$bus/$device" 2>&1 | head -5 || true
        done
        sleep 2
    else
        LOG "usbreset not available. To reset USB devices, install usbreset or use UNBIND_USB=1"
        LOG "Install with: sudo apt install usbutils (Debian/Ubuntu) or compile from source"
    fi
    
    return 0
}

restart_via_systemd() {
    local existing=()
    for s in "${SERVICES[@]}"; do
        if systemctl --user --quiet status "$s" >/dev/null 2>&1; then
            existing+=("$s")
        fi
    done

    if [ ${#existing[@]} -eq 0 ]; then
        LOG "No known PipeWire user services found to restart via systemd."
        return 1
    fi

    LOG "Restarting user services: ${existing[*]}"
    systemctl --user restart "${existing[@]}" || {
        LOG "systemd restart failed for: ${existing[*]}"
        return 1
    }

    LOG "systemd restart succeeded."
    return 0
}

fallback_kill_and_cleanup() {
    LOG "Falling back to kill + cleanup method."

    pkill -TERM -u "$USER" -x pipewire || true
    pkill -TERM -u "$USER" -x pipewire-pulse || true
    pkill -TERM -u "$USER" -x wireplumber || true
    sleep 1

    pkill -KILL -u "$USER" -x pipewire || true
    pkill -KILL -u "$USER" -x pipewire-pulse || true
    pkill -KILL -u "$USER" -x wireplumber || true

    LOG "Removing stale runtime sockets under ${STATE_DIR} (pipewire/pulse) ..."
    rm -rf "${STATE_DIR}"/pipewire* "${STATE_DIR}"/pulse* "${STATE_DIR}"/pw-* || true

    # Also clean WirePlumber state if requested or if state looks corrupted
    if [ "${CLEAN_STATE:-}" = "1" ] || [ ! -s "${HOME}/.local/state/wireplumber/default-nodes" ]; then
        LOG "Cleaning WirePlumber state files..."
        rm -f "${HOME}/.local/state/wireplumber/default-nodes" \
              "${HOME}/.local/state/wireplumber/default-routes" || true
    fi

    sleep 1

    LOG "Attempting to start services (if present) via systemd start."
    for s in "${SERVICES[@]}"; do
        if systemctl --user --quiet status "$s" >/dev/null 2>&1; then
            systemctl --user start "$s" || LOG "systemctl start $s failed (but continuing)."
        fi
    done
}

restore_analog_profiles() {
  LOG "Restoring analog profiles for USB audio devices..."
  
  # Wait for cards to be available
  sleep 1
  
  # Get all cards and set USB devices to analog-stereo profile
  while IFS= read -r card_line; do
    card_name=$(echo "$card_line" | awk '{print $2}')
    
    # Check if it's a USB card
    if echo "$card_name" | grep -q "usb-"; then
      # Check if analog-stereo profile is available
      if pactl list cards 2>/dev/null | grep -A 50 "Name: $card_name" | grep -q "output:analog-stereo:"; then
        LOG "  Setting $card_name to analog-stereo profile"
        pactl set-card-profile "$card_name" output:analog-stereo 2>/dev/null || \
          LOG "  Warning: Could not set profile for $card_name"
      else
        LOG "  $card_name does not have analog-stereo profile, skipping"
      fi
    fi
  done < <(pactl list short cards 2>/dev/null)
}

detect_sinks() {
  # Produce a list of sink names (second column), excluding dummy sinks
  sinks=( $(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -v "auto_null" | grep -v "dummy") )
  if [ ${#sinks[@]} -eq 0 ]; then
    LOG "No real sinks detected by pactl (excluding dummy/null sinks)."
    return 1
  fi

  if [ -z "${PRIMARY_SINK}" ]; then
    # Prefer USB audio devices first, then PCI
    for p in "usb" "pci"; do
      for s in "${sinks[@]}"; do
        if echo "$s" | grep -qi "$p"; then
          PRIMARY_SINK="$s"
          break 2
        fi
      done
    done
    # Fallback to first available sink
    if [ -z "${PRIMARY_SINK}" ]; then
      PRIMARY_SINK="${sinks[0]}"
    fi
  fi

  if [ -z "${SECONDARY_SINK}" ]; then
    # Prefer HDMI or PCI (non-USB) sinks for secondary
    for p in "hdmi" "pci" "analog"; do
      for s in "${sinks[@]}"; do
        if echo "$s" | grep -qi "$p" && [ "$s" != "$PRIMARY_SINK" ]; then
          SECONDARY_SINK="$s"
          break 2
        fi
      done
    done
    # Fallback to first sink that is not PRIMARY_SINK
    if [ -z "${SECONDARY_SINK}" ]; then
      for s in "${sinks[@]}"; do
        if [ "$s" != "$PRIMARY_SINK" ]; then
          SECONDARY_SINK="$s"
          break
        fi
      done
    fi
  fi

  LOG "Using PRIMARY_SINK=${PRIMARY_SINK}"
  LOG "Using SECONDARY_SINK=${SECONDARY_SINK}"
  return 0
}

unload_saved_module() {
  if [ -f "${MODULE_ID_FILE}" ]; then
    saved=$(<"${MODULE_ID_FILE}")
    if pactl list short modules | awk '{print $1}' | grep -qx -- "$saved"; then
      LOG "Unloading previous combine module id ${saved}..."
      pactl unload-module "$saved" || LOG "Failed to unload module $saved"
    fi
    rm -f "${MODULE_ID_FILE}"
  fi
}

load_combined() {
  if ! command -v pactl >/dev/null 2>&1; then
    LOG "pactl not found; skipping combined sink creation."
    return 0
  fi

  detect_sinks || return 1

  # verify sinks exist (skip empty sinks)
  for s in "$PRIMARY_SINK" "$SECONDARY_SINK"; do
    if [ -n "$s" ]; then
      if ! pactl list short sinks | awk '{print $2}' | grep -Fxq -- "$s"; then
        LOG "Sink $s not present; aborting combined sink creation."
        return 1
      fi
    fi
  done
  
  # Must have at least two sinks for a combined sink
  if [ -z "$SECONDARY_SINK" ]; then
    LOG "No secondary sink available; need at least 2 sinks for combined output."
    return 1
  fi

  unload_saved_module

  LOG "Loading module-combine-sink with slaves ${PRIMARY_SINK},${SECONDARY_SINK}..."
  set +e
  out=$(pactl load-module module-combine-sink \
    sink_name="${COMBINED_SINK_NAME}" \
    sink_properties=device.description="${COMBINED_SINK_DESCRIPTION}" \
    slaves="${PRIMARY_SINK},${SECONDARY_SINK}" \
    channels=2 \
    rate=48000 \
    adjust_time=10 resample_method=soxr-vhq 2>&1)
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    LOG "Failed to load combine module: ${out}"
    return 1
  fi

  mid=$(printf '%s' "$out" | awk '/^[0-9]+/ {print $1}') || true
  if [ -n "$mid" ]; then
    mkdir -p "$(dirname "${MODULE_ID_FILE}")"
    printf '%s' "$mid" > "${MODULE_ID_FILE}"
    LOG "Loaded combine module id=${mid} (saved to ${MODULE_ID_FILE})."
    
    # Set all slave sinks to 100% volume and unmute them
    LOG "Setting slave sink volumes to 100%..."
    pactl set-sink-volume "${PRIMARY_SINK}" 100% 2>/dev/null || LOG "  Warning: Could not set ${PRIMARY_SINK} volume"
    pactl set-sink-mute "${PRIMARY_SINK}" 0 2>/dev/null || true
    pactl set-sink-volume "${SECONDARY_SINK}" 100% 2>/dev/null || LOG "  Warning: Could not set ${SECONDARY_SINK} volume"
    pactl set-sink-mute "${SECONDARY_SINK}" 0 2>/dev/null || true
    
    # Set combined sink to 100% volume
    LOG "Setting combined sink volume to 100%..."
    pactl set-sink-volume "${COMBINED_SINK_NAME}" 100% 2>/dev/null || LOG "  Warning: Could not set combined sink volume"
    pactl set-sink-mute "${COMBINED_SINK_NAME}" 0 2>/dev/null || true
    
    # Activate the HDMI sink by playing a brief silent audio to wake it up
    LOG "Activating HDMI sink..."
    # Create a 0.1 second silent audio file and play it to the HDMI sink to activate it
    (paplay -d "${SECONDARY_SINK}" /dev/zero --rate=48000 --channels=2 --format=s16le --volume=0 2>/dev/null &
     sleep 0.2
     pkill -P $$ paplay 2>/dev/null || true) || true
    
    pactl set-default-sink "${COMBINED_SINK_NAME}" || LOG "Failed to set default sink (non-fatal)"
    LOG "Combined sink configured and set as default"
  else
    LOG "Loaded module returned unexpected output: $out"
  fi
}

main() {
  LOG "=== reset_pipewire: start ==="

  # Optionally reset USB audio devices if they're stuck
  reset_usb_audio_devices

  if restart_via_systemd; then
    LOG "systemd restart path completed."
  else
    LOG "systemd restart not available or failed; using fallback."
    fallback_kill_and_cleanup
  fi

  # Wait longer for sinks to appear after restart
  LOG "Waiting for audio sinks to become available..."
  sleep 3
  
  # Check and install sample rate config if needed (after restart so we can detect mismatches)
  check_sample_rate_config
  
  # Restore analog profiles for USB devices (they often default to digital)
  restore_analog_profiles

  # Retry sink detection a few times if needed
  local max_retries=10
  local i=1
  while [ $i -le $max_retries ]; do
    # Check for hardware sinks (alsa_output) excluding dummy/null
    hw_sinks=$(pactl list short sinks 2>/dev/null | grep "alsa_output" | grep -v "auto_null" | wc -l || echo "0")
    
    # If pactl fails completely, wait and retry
    if ! pactl info >/dev/null 2>&1; then
      LOG "Waiting for PipeWire to be ready (attempt $i/$max_retries)..."
      sleep 2
      i=$((i + 1))
      continue
    fi
    
    if [ "$hw_sinks" -ge 2 ]; then
      LOG "Hardware audio sinks detected ($hw_sinks devices)."
      break
    fi
    
    if [ $i -eq $max_retries ]; then
      LOG "WARNING: Only $hw_sinks hardware sink(s) found after $max_retries attempts."
      LOG "You may need to run with CLEAN_STATE=1 or check hardware connections."
      break
    fi
    
    LOG "Waiting for hardware audio sinks (attempt $i/$max_retries, found $hw_sinks)..."
    sleep 2
    i=$((i + 1))
  done

  load_combined || LOG "Combined sink creation failed (non-fatal)."

  # Show status summary
  LOG ""
  LOG "Audio devices status:"
  pactl list short sinks 2>/dev/null | while read -r id name driver format channels rate state; do
    device_short=$(echo "$name" | sed 's/alsa_output\.//' | cut -d'.' -f1 | head -c 40)
    LOG "  [$state] $device_short"
  done
  
  if pactl list short sinks 2>/dev/null | grep -q "SUSPENDED"; then
    LOG ""
    LOG "Note: SUSPENDED devices are ready to use (power-saving mode)."
    LOG "      They automatically wake when audio plays."
  fi
  
  # Try to reconnect common applications
  LOG ""
  LOG "Attempting to reconnect audio applications..."
  
  # Move all sink inputs to the new default sink to force reconnection
  if command -v pactl >/dev/null 2>&1; then
    default_sink=$(pactl info 2>/dev/null | grep "Default Sink:" | cut -d' ' -f3)
    if [ -n "$default_sink" ]; then
      pactl list short sink-inputs 2>/dev/null | while read -r input_id rest; do
        pactl move-sink-input "$input_id" "$default_sink" 2>/dev/null || true
      done
    fi
  fi
  
  # Find and send SIGUSR1 to Firefox (tells it to reconnect audio)
  pgrep -x firefox >/dev/null 2>&1 && pkill -SIGUSR1 firefox 2>/dev/null && LOG "  Signaled Firefox to reconnect audio" || true
  
  # Chrome/Chromium usually auto-reconnect, but we can try
  pgrep -x chrome >/dev/null 2>&1 && LOG "  Chrome detected (usually auto-reconnects)" || true
  pgrep -x chromium >/dev/null 2>&1 && LOG "  Chromium detected (usually auto-reconnects)" || true
  
  LOG ""
  LOG "If applications still have no audio, you may need to restart them manually."
  LOG ""
  LOG "=== reset_pipewire: done ==="
}

main "$@"


