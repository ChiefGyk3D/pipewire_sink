#!/usr/bin/env bash
# pipewire-ensure-defaults - light, non-disruptive audio defaults enforcement.
#
# Waits for the native combined sink to appear, then makes sure:
#   - combined_out is the default sink
#   - the USB input (mic) is the default source
#   - hardware sinks/sources are unmuted at 100% (excluded devices muted)
#
# Unlike reset-pipewire this NEVER restarts services or unloads modules,
# so it is safe to run at login, from display-hotplug scripts, and from the
# watchdog after a recovery. Existing app streams are untouched.

set -u

LOG() { printf '%s %s\n' "$(date +'%F %T')" "$*"; }

COMBINED_SINK_NAME="combined_out"
WAIT_SECS=20

# Same patterns as reset-pipewire; devices matching these get muted.
EXCLUDE_PATTERNS=()

is_excluded() {
    local name="$1" pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        [[ "$name" == *"$pattern"* ]] && return 0
    done
    return 1
}

# Wait for pipewire-pulse to answer at all
for _ in $(seq 1 "$WAIT_SECS"); do
    timeout 3 pactl info >/dev/null 2>&1 && break
    sleep 1
done
if ! timeout 3 pactl info >/dev/null 2>&1; then
    LOG "ERROR: PipeWire not answering; nothing to do"
    exit 1
fi

# Wait for the combined sink (created declaratively by the core)
found=0
for _ in $(seq 1 "$WAIT_SECS"); do
    if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$COMBINED_SINK_NAME"; then
        found=1
        break
    fi
    sleep 1
done

if [ "$found" -eq 1 ]; then
    pactl set-default-sink "$COMBINED_SINK_NAME" 2>/dev/null &&
        LOG "Default sink: $COMBINED_SINK_NAME" ||
        LOG "WARNING: could not set default sink"
    pactl set-sink-mute "$COMBINED_SINK_NAME" 0 2>/dev/null || true
    pactl set-sink-volume "$COMBINED_SINK_NAME" 100% 2>/dev/null || true
else
    LOG "WARNING: $COMBINED_SINK_NAME not present after ${WAIT_SECS}s"
    LOG "  Is ~/.config/pipewire/pipewire.conf.d/60-combined-sink.conf installed?"
fi

# Default source: prefer USB analog input (mic/mixer), accept digital
usb_source=$(pactl list short sources 2>/dev/null |
    awk '{print $2}' | grep "^alsa_input" |
    grep -E "usb-.*(analog-stereo|iec958-stereo)" | head -1) || true
if [ -n "${usb_source:-}" ]; then
    pactl set-default-source "$usb_source" 2>/dev/null &&
        LOG "Default source: $usb_source" ||
        LOG "WARNING: could not set default source"
fi

# Hardware sinks to 100% unmuted, excluded devices muted. Only touches a sink
# whose volume/mute is off, so it is cheap to run repeatedly.
fix_sink_volumes() {
    local sink vol mute
    while IFS= read -r sink; do
        [ -n "$sink" ] || continue
        if is_excluded "$sink"; then
            pactl set-sink-mute "$sink" 1 2>/dev/null || true
            pactl set-sink-volume "$sink" 0% 2>/dev/null || true
            continue
        fi
        vol=$(pactl get-sink-volume "$sink" 2>/dev/null | grep -o '[0-9]*%' | tr -d '%' | sort -n | head -1)
        mute=$(pactl get-sink-mute "$sink" 2>/dev/null | awk '{print $2}')
        if [ "${vol:-0}" -ne 100 ] || [ "$mute" != "no" ]; then
            LOG "Fixing $sink (volume ${vol:-?}%, mute ${mute:-?})"
            pactl set-sink-volume "$sink" 100% 2>/dev/null || true
            pactl set-sink-mute "$sink" 0 2>/dev/null || true
        fi
    done < <(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -v "auto_null\|dummy")
}

# --watch: stay running and re-fix volumes whenever a NEW sink appears.
# WirePlumber restores a saved per-device route volume (often ~30%) after the
# sink shows up, so wait for that, then fix. Volume changes you make by hand
# are left alone: only "new sink" events trigger a fix.
if [ "${1:-}" = "--watch" ]; then
    LOG "Watching for new sinks"
    pactl subscribe 2>/dev/null | grep --line-buffered "'new' on sink " | while read -r _; do
        sleep 3
        fix_sink_volumes
    done
    exit 0
fi

fix_sink_volumes

# Input sources to 100% unmuted (skip monitors)
while IFS= read -r source; do
    [ -n "$source" ] || continue
    [[ "$source" =~ \.monitor$ ]] && continue
    pactl set-source-volume "$source" 100% 2>/dev/null || true
    pactl set-source-mute "$source" 0 2>/dev/null || true
done < <(pactl list short sources 2>/dev/null | awk '{print $2}' | grep "^alsa_input")

# Late sinks and WirePlumber's route-volume restore land after the first pass;
# --settle waits ~30 s and re-checks (no-op when nothing is off). The watchdog
# calls this synchronously, so it is opt-in.
if [ "${1:-}" = "--settle" ]; then
    for _ in 1 2 3 4 5 6; do
        sleep 5
        fix_sink_volumes
    done
fi

LOG "Defaults ensured (no services were restarted)"
