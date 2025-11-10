#!/usr/bin/env bash
# Quick audio system status check

echo "=== PipeWire Status ==="
systemctl --user is-active pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null | \
    paste <(echo -e "pipewire\npipewire-pulse\nwireplumber") - | column -t

echo ""
echo "=== Audio Sinks ==="
has_suspended=false
pactl list short sinks | while read -r id name driver format channels rate state; do
    printf "%-3s %-60s %s\n" "$id" "$name" "$state"
    if [ "$state" = "SUSPENDED" ]; then
        has_suspended=true
    fi
done

# Check if any sinks are suspended and explain
if pactl list short sinks | grep -q "SUSPENDED"; then
    echo ""
    echo "ℹ️  SUSPENDED = Device ready but powered down (normal when not playing audio)"
    echo "   Devices automatically wake when audio plays"
fi

echo ""
echo "=== Default Sink ==="
pactl info | grep "Default Sink"

echo ""
echo "=== Watchdog Status ==="
if systemctl --user is-active pipewire-watchdog.service >/dev/null 2>&1; then
    echo "✓ Watchdog is running"
    echo "  Last check: $(journalctl --user -u pipewire-watchdog -n 1 --no-pager -o cat 2>/dev/null || echo 'N/A')"
else
    echo "✗ Watchdog is NOT running"
fi

echo ""
echo "=== Combined Sink Module ==="
if [ -f ~/.local/state/reset_pipewire_combined_module_id ]; then
    mod_id=$(cat ~/.local/state/reset_pipewire_combined_module_id)
    if pactl list short modules | grep -q "^$mod_id"; then
        echo "✓ Combined sink module loaded (ID: $mod_id)"
    else
        echo "✗ Combined sink module ID stored but not loaded"
    fi
else
    echo "✗ No combined sink module ID found"
fi

echo ""
echo "=== USB Audio Devices ==="
lsusb | grep -iE 'audio|rode|behringer|focusrite|scarlett|presonus|m-audio' || echo "No USB audio devices found"
