#!/usr/bin/env bash
# PipeWire Watchdog - Monitors audio devices and restarts if they disappear
set -euo pipefail

LOG() { logger -t pipewire-watchdog "$*"; }

CHECK_INTERVAL=30  # Check every 30 seconds
MIN_SINKS=2        # Minimum number of hardware sinks expected

check_audio_health() {
    # Check if pactl can connect at all
    if ! pactl info >/dev/null 2>&1; then
        LOG "ERROR: Cannot connect to PipeWire (pactl failed)"
        return 1
    fi
    
    # Count hardware audio sinks (excluding dummy/null devices)
    local hw_sinks
    hw_sinks=$(pactl list short sinks 2>/dev/null | grep "alsa_output" | grep -v "auto_null" | wc -l || echo "0")
    
    if [ "$hw_sinks" -lt "$MIN_SINKS" ]; then
        LOG "WARNING: Only $hw_sinks hardware sink(s) detected (expected $MIN_SINKS+)"
        return 1
    fi
    
    # Check if PipeWire/WirePlumber are running
    if ! pgrep -u "$USER" pipewire >/dev/null; then
        LOG "ERROR: PipeWire not running"
        return 1
    fi
    
    if ! pgrep -u "$USER" wireplumber >/dev/null; then
        LOG "ERROR: WirePlumber not running"
        return 1
    fi
    
    # Check for sinks in ERROR state or with device errors
    local error_sinks
    error_sinks=$(pactl list sinks 2>/dev/null | grep -c "State: ERROR" || true)
    if [ "$error_sinks" -gt 0 ]; then
        LOG "WARNING: $error_sinks sink(s) in ERROR state"
        return 1
    fi
    
    # Check if USB audio devices are responsive (try to read volume)
    # If pactl hangs or fails on USB devices, they're likely stuck
    local usb_sinks
    usb_sinks=$(pactl list short sinks 2>/dev/null | grep "usb-.*analog-stereo" | awk '{print $2}' || true)
    for sink in $usb_sinks; do
        if ! timeout 2 pactl get-sink-volume "$sink" >/dev/null 2>&1; then
            LOG "WARNING: USB sink $sink appears unresponsive (timeout or error)"
            return 1
        fi
    done
    
    # Check if default sink is valid
    local default_sink
    default_sink=$(pactl info 2>/dev/null | grep "Default Sink:" | awk '{print $3}')
    if [ -z "$default_sink" ] || [ "$default_sink" = "auto_null" ]; then
        LOG "WARNING: Invalid or missing default sink"
        return 1
    fi
    
    # Check for recent WirePlumber errors in journal
    if journalctl --user -u wireplumber --since "1 minute ago" 2>/dev/null | grep -qi "can't open control\|No such file"; then
        LOG "WARNING: WirePlumber hardware errors detected in logs"
        return 1
    fi
    
    return 0
}

main() {
    LOG "Starting audio watchdog (checking every ${CHECK_INTERVAL}s)"
    
    local failures=0
    local max_failures=3
    
    while true; do
        sleep "$CHECK_INTERVAL"
        
        if ! check_audio_health; then
            failures=$((failures + 1))
            LOG "Health check failed (failure $failures/$max_failures)"
            
            if [ "$failures" -ge "$max_failures" ]; then
                LOG "Maximum failures reached, triggering reset..."
                
                # Run the reset script
                if [ -x "$HOME/.local/bin/reset-pipewire" ]; then
                    # First try normal reset
                    "$HOME/.local/bin/reset-pipewire" 2>&1 | logger -t pipewire-watchdog
                    LOG "Reset completed, waiting for stabilization..."
                    sleep 10
                    
                    # Check if reset worked (USB reset now enabled by default)
                    if check_audio_health; then
                        LOG "Reset successful, resetting failure counter"
                        failures=0
                    else
                        LOG "WARNING: Reset didn't fully restore audio, trying nuclear option..."
                        # Try nuclear reset as last resort
                        if [ -x "$HOME/.local/bin/reset-pipewire-nuclear" ]; then
                            "$HOME/.local/bin/reset-pipewire-nuclear" 2>&1 | logger -t pipewire-watchdog
                            sleep 10
                            
                            if check_audio_health; then
                                LOG "Nuclear reset successful, resetting failure counter"
                                failures=0
                            else
                                LOG "WARNING: Nuclear reset didn't fully restore audio, will retry"
                                failures=0  # Reset counter to try again
                                sleep 30  # Wait longer before next attempt
                            fi
                        else
                            LOG "WARNING: Nuclear reset not available, will retry normal reset"
                            failures=0
                            sleep 30
                        fi
                    fi
                else
                    LOG "ERROR: reset-pipewire script not found or not executable"
                    exit 1
                fi
            fi
        else
            # Reset failure counter on successful check
            if [ "$failures" -gt 0 ]; then
                LOG "Health check passed, resetting failure counter (was $failures)"
                failures=0
            fi
        fi
    done
}

main "$@"
