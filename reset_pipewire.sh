
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

    sleep 1

    LOG "Attempting to start services (if present) via systemd start."
    for s in "${SERVICES[@]}"; do
        if systemctl --user --quiet status "$s" >/dev/null 2>&1; then
            systemctl --user start "$s" || LOG "systemctl start $s failed (but continuing)."
        fi
    done
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
    adjust_time=10 resample_method=copy 2>&1)
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
    pactl set-default-sink "${COMBINED_SINK_NAME}" || LOG "Failed to set default sink (non-fatal)"
  else
    LOG "Loaded module returned unexpected output: $out"
  fi
}

main() {
  LOG "=== reset_pipewire: start ==="

  if restart_via_systemd; then
    LOG "systemd restart path completed."
  else
    LOG "systemd restart not available or failed; using fallback."
    fallback_kill_and_cleanup
  fi

  # Wait longer for sinks to appear after restart
  LOG "Waiting for audio sinks to become available..."
  sleep 3

  # Retry sink detection a few times if needed
  for i in {1..5}; do
    if pactl list short sinks 2>/dev/null | grep -v "auto_null" | grep -q .; then
      LOG "Audio sinks detected."
      break
    fi
    LOG "Waiting for real audio sinks (attempt $i/5)..."
    sleep 2
  done

  load_combined || LOG "Combined sink creation failed (non-fatal)."

  LOG "=== reset_pipewire: done ==="
}

main "$@"


