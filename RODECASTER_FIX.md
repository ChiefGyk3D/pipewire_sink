# RØDECaster Pro II Audio Fix - Quick Reference

## The Problem
Audio stops flowing to RØDECaster speakers even though PipeWire shows everything as "RUNNING".

Additionally, on Linux:
- **Default device resets to HDMI** after every reboot/replug (node name suffixes change)
- **Microphone input levels are lower than Windows** (missing ASIO gain normalization)

## Default Device Fix (NEW)

Install the auto-default WirePlumber scripts to permanently fix HDMI fallback:

```bash
# Via the installer (recommended)
./install.sh
# Select "Y" when prompted for RØDECaster configuration

# Or manually
cp examples/51-rodecaster-priority.conf ~/.config/wireplumber/wireplumber.conf.d/
cp examples/rodecaster-default.lua ~/.config/wireplumber/scripts/
cp examples/91-rodecaster-default.lua ~/.config/wireplumber/main.lua.d/
systemctl --user restart wireplumber
```

## Input Volume Boost

Compensate for lower Linux USB audio levels (125% matches Windows):

```bash
pactl set-source-volume "$(pactl list sources short | grep R__DE | grep -v monitor | awk '{print $2}')" 125%
```

WirePlumber persists this volume automatically.

## Root Cause
RØDECaster Pro II firmware (especially 1.6.8+) enters a stuck state where it requires **physical USB reconnection** to reset its internal audio routing. Software resets don't work.

## The Fix (In Order of Effectiveness)

### 1. Physical USB Replug (ALWAYS WORKS)
```bash
# Physically unplug USB cable from computer
# Wait 2-3 seconds
# Plug it back in
# Then run:
reset-pipewire
```

### 2. Try Software Reset First (Usually Doesn't Work, But Worth Trying)
```bash
reset-usb-audio  # Software USB reset
reset-pipewire   # Recreate combined sink
```

### 3. Nuclear Option (If Software Reset Fails)
```bash
reset-pipewire-nuclear  # Reload kernel modules
reset-pipewire          # Recreate combined sink
```

## Automatic Monitoring

The watchdog service monitors audio every 30 seconds:
- ✅ Attempts automatic recovery
- ✅ Sends desktop notification if manual replug needed
- ✅ Check system logs: `journalctl --user -u pipewire-watchdog -f`

**When you see the notification**: Physically unplug/replug the USB cable.

## Why Physical Replug is Required

The RØDECaster firmware needs actual electrical disconnection to reset its internal state. This is a hardware/firmware limitation, not a Linux/PipeWire bug.

Software methods tried (all unsuccessful):
- ❌ sysfs USB authorize/deauthorize
- ❌ Driver unbind/rebind
- ❌ ALSA kernel module reload
- ❌ Complete PipeWire/WirePlumber restart
- ✅ **Physical USB disconnect (ONLY solution)**

## Preventing the Issue

Unfortunately, this appears to be a firmware bug that occurs sporadically. Best practices:
- Keep watchdog service running for automatic detection
- When notification appears, replug USB immediately
- Consider reporting to RØDE as firmware bug

## Current Status
- Watchdog: Running and monitoring
- Will notify you when manual intervention needed
- All automatic recovery attempts will be tried first
