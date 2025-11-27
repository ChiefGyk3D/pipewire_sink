# RØDECaster Pro II Audio Fix - Quick Reference

## The Problem
Audio stops flowing to RØDECaster speakers even though PipeWire shows everything as "RUNNING".

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
