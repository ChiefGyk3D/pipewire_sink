#!/usr/bin/env bash
# PipeWire Watchdog v2 - monitors audio health and recovers automatically.
#
# Design notes (v2 rewrite):
#   - The unit no longer has Requires=pipewire.service, so restarting
#     PipeWire (by this script or by hand) does NOT kill the watchdog.
#     v1 was torn down by systemd every time its own remedy ran, wiping
#     its failure counter and going blind for 90+ seconds.
#   - Two failure tiers:
#       HARD: pactl/pw-cli cannot talk to the daemons (hung core, dead
#             socket). Confirmed once after 5s, then recovery runs
#             immediately - no more 90s of dead audio waiting for 3 strikes.
#       SOFT: devices missing, combined sink gone, USB sink unresponsive.
#             3 consecutive strikes before recovery (rides out replugs).
#   - Grace period after any pipewire restart (intentional restarts by
#     reset-pipewire or package upgrades are not treated as failures).
#   - The combined sink is declarative (60-combined-sink.conf), so recovery
#     is just a service restart + pipewire-ensure-defaults. No sink rebuild.
#
# Deliberately NOT `set -e`: a monitor loop must survive probe failures.
set -u

LOG() { logger -t pipewire-watchdog "$*"; }

NOTIFY() {
    if command -v notify-send >/dev/null 2>&1; then
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}" \
        notify-send -u critical -t 0 "PipeWire Audio Issue" "$*" 2>/dev/null || true
    fi
}

CHECK_INTERVAL=15        # seconds between health checks
SOFT_MAX_FAILURES=3      # consecutive soft failures before recovery
RECOVERY_COOLDOWN=90     # minimum seconds between recovery attempts
GRACE_SECS=20            # ignore failures this long after pipewire (re)starts
MIN_SINKS=2              # minimum hardware sinks expected

# Devices excluded from the sink count (same patterns as reset-pipewire)
EXCLUDE_PATTERNS=()

ENSURE_DEFAULTS="$HOME/.local/bin/pipewire-ensure-defaults"

is_excluded() {
    local name="$1" pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        [[ "$name" == *"$pattern"* ]] && return 0
    done
    return 1
}

# --- probes -----------------------------------------------------------------

core_ok() {
    # Native protocol straight to the pipewire core. Catches the "core alive
    # but main loop hung, socket backlog full" failure that pactl alone can
    # miss or misattribute.
    timeout 3 pw-cli info 0 >/dev/null 2>&1
}

pulse_ok() {
    # Pulse protocol via pipewire-pulse (what all desktop apps use).
    timeout 5 pactl info >/dev/null 2>&1
}

pipewire_main_pid() {
    systemctl --user show pipewire.service -p MainPID --value 2>/dev/null || echo 0
}

soft_check() {
    # Returns 0 = healthy. Logs the reason on failure.
    local sinks sink count=0

    if ! pgrep -u "$USER" -x pipewire >/dev/null; then
        LOG "SOFT: pipewire process not running"
        return 1
    fi
    if ! pgrep -u "$USER" -x wireplumber >/dev/null; then
        LOG "SOFT: wireplumber process not running"
        return 1
    fi

    sinks=$(timeout 5 pactl list short sinks 2>/dev/null | awk '{print $2}') || sinks=""

    while IFS= read -r sink; do
        [ -n "$sink" ] || continue
        case "$sink" in *auto_null*|*dummy*) continue ;; esac
        [[ "$sink" == alsa_output* ]] || continue
        is_excluded "$sink" && continue
        count=$((count + 1))
    done <<< "$sinks"

    if [ "$count" -lt "$MIN_SINKS" ]; then
        LOG "SOFT: only $count hardware sink(s) present (expected >= $MIN_SINKS)"
        return 1
    fi

    # Combined sink must exist if the declarative config is installed
    if [ -f "$HOME/.config/pipewire/pipewire.conf.d/60-combined-sink.conf" ]; then
        if ! grep -qx "combined_out" <<< "$sinks"; then
            LOG "SOFT: combined_out sink missing despite installed config"
            return 1
        fi
    fi

    # Default sink sanity
    local default_sink
    default_sink=$(timeout 5 pactl info 2>/dev/null | awk -F': ' '/Default Sink:/ {print $2}')
    if [ -z "$default_sink" ] || [ "$default_sink" = "auto_null" ]; then
        LOG "SOFT: default sink is '${default_sink:-none}'"
        return 1
    fi

    # USB sinks (RODECaster etc.) must answer volume queries; a hung
    # firmware state makes these time out while everything looks RUNNING.
    while IFS= read -r sink; do
        [ -n "$sink" ] || continue
        if ! timeout 3 pactl get-sink-volume "$sink" >/dev/null 2>&1; then
            LOG "SOFT: USB sink $sink unresponsive (possible firmware stall)"
            return 1
        fi
    done < <(grep -E "^alsa_output\.usb-.*" <<< "$sinks" || true)

    return 0
}

# --- recovery ---------------------------------------------------------------

wait_healthy() {
    local deadline=$((SECONDS + ${1:-30}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if core_ok && pulse_ok && soft_check; then
            return 0
        fi
        sleep 2
    done
    return 1
}

recover() {
    local reason="$1"
    LOG "RECOVERY start ($reason): restarting PipeWire services"

    # Tier 1: orderly restart. The combined sink comes back declaratively.
    systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service 2>&1 \
        | logger -t pipewire-watchdog || true

    if wait_healthy 30; then
        [ -x "$ENSURE_DEFAULTS" ] && "$ENSURE_DEFAULTS" 2>&1 | logger -t pipewire-watchdog
        LOG "RECOVERY successful (orderly restart)"
        return 0
    fi

    # Tier 2: processes may be hung beyond systemd's reach - force kill,
    # clear runtime sockets, start fresh.
    LOG "RECOVERY: orderly restart insufficient, force-killing hung processes"
    pkill -KILL -u "$USER" -x pipewire 2>/dev/null || true
    pkill -KILL -u "$USER" -x pipewire-pulse 2>/dev/null || true
    pkill -KILL -u "$USER" -x wireplumber 2>/dev/null || true
    sleep 2
    rm -rf "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/pipewire* \
           "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/pulse* \
           "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/pw-* 2>/dev/null || true
    systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null || true
    systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true

    if wait_healthy 30; then
        [ -x "$ENSURE_DEFAULTS" ] && "$ENSURE_DEFAULTS" 2>&1 | logger -t pipewire-watchdog
        LOG "RECOVERY successful (force restart)"
        return 0
    fi

    # Tier 3: out of software options - almost always the RODECaster
    # firmware stall that only a physical replug clears.
    LOG "CRITICAL: recovery failed - manual USB replug likely required"
    NOTIFY "Audio recovery failed.

Physically unplug and replug the USB audio device (RODECaster), then audio should return automatically."
    return 1
}

# --- main loop --------------------------------------------------------------

main() {
    LOG "Watchdog v2 starting (interval ${CHECK_INTERVAL}s, soft strikes ${SOFT_MAX_FAILURES})"

    # Startup: wait for the audio stack instead of a fixed blind sleep
    local waited=0
    until pulse_ok || [ "$waited" -ge 60 ]; do
        sleep 2; waited=$((waited + 2))
    done
    LOG "Audio stack answering after ${waited}s; monitoring"

    local soft_failures=0
    local last_recovery=-999999
    local last_pw_pid
    last_pw_pid=$(pipewire_main_pid)

    while true; do
        sleep "$CHECK_INTERVAL"

        # Grace after an intentional/external pipewire restart: new MainPID
        local pid
        pid=$(pipewire_main_pid)
        if [ "$pid" != "$last_pw_pid" ]; then
            last_pw_pid="$pid"
            soft_failures=0
            LOG "pipewire restarted externally (pid $pid); grace ${GRACE_SECS}s"
            sleep "$GRACE_SECS"
            continue
        fi

        # HARD tier: daemons unreachable
        local c=yes p=yes
        core_ok || c=no
        pulse_ok || p=no
        if [ "$c" = no ] || [ "$p" = no ]; then
            LOG "HARD: daemons unreachable (core=$c pulse=$p); confirming in 5s"
            sleep 5
            if ! core_ok || ! pulse_ok; then
                if [ $((SECONDS - last_recovery)) -ge "$RECOVERY_COOLDOWN" ]; then
                    recover "hard failure: pipewire/pipewire-pulse unreachable"
                    last_recovery=$SECONDS
                    last_pw_pid=$(pipewire_main_pid)
                    soft_failures=0
                else
                    LOG "HARD failure persists but within recovery cooldown; waiting"
                fi
            else
                LOG "HARD failure cleared on recheck (transient)"
            fi
            continue
        fi

        # SOFT tier
        if ! soft_check; then
            soft_failures=$((soft_failures + 1))
            LOG "Soft health check failed ($soft_failures/$SOFT_MAX_FAILURES)"
            if [ "$soft_failures" -ge "$SOFT_MAX_FAILURES" ]; then
                if [ $((SECONDS - last_recovery)) -ge "$RECOVERY_COOLDOWN" ]; then
                    recover "soft failures x$soft_failures"
                    last_recovery=$SECONDS
                    last_pw_pid=$(pipewire_main_pid)
                fi
                soft_failures=0
            fi
        elif [ "$soft_failures" -gt 0 ]; then
            LOG "Health restored (was $soft_failures soft failure(s))"
            soft_failures=0
        fi
    done
}

main "$@"
