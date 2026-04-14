#!/usr/bin/env bash
# PipeWire Combined Sink Installer
# Interactive setup for PipeWire audio management

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config"
SYSTEMD_USER_DIR="${CONFIG_DIR}/systemd/user"
PIPEWIRE_CONF_DIR="${CONFIG_DIR}/pipewire/pipewire.conf.d"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warning() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }

print_header() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  PipeWire Combined Sink Installer"
    echo "════════════════════════════════════════════════════════"
    echo ""
}

check_dependencies() {
    info "Checking dependencies..."
    
    local missing=()
    
    if ! command -v pactl >/dev/null 2>&1; then
        missing+=("pipewire-pulse or pulseaudio-utils")
    fi
    
    if ! systemctl --user status pipewire.service >/dev/null 2>&1; then
        warning "PipeWire service not found or not running"
        warning "Install PipeWire and enable user services"
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  Ubuntu/Debian: sudo apt install pipewire pipewire-pulse wireplumber"
        echo "  Fedora: sudo dnf install pipewire pipewire-pulseaudio wireplumber"
        echo "  Arch: sudo pacman -S pipewire pipewire-pulse wireplumber"
        exit 1
    fi
    
    success "All dependencies found"
}

detect_audio_devices() {
    info "Detecting audio devices..."
    echo ""
    
    if ! pactl info >/dev/null 2>&1; then
        error "Cannot connect to PipeWire/PulseAudio"
        return 1
    fi
    
    echo "Available audio sinks:"
    echo "─────────────────────────────────────────────────────"
    pactl list short sinks | grep "alsa_output" | nl -w2 -s". "
    echo ""
}

prompt_device_selection() {
    local prompt="$1"
    local default="$2"
    
    # Send prompts to stderr so they're not captured by $()
    echo "$prompt" >&2
    echo "Options:" >&2
    echo "  - Enter sink name (e.g., alsa_output.usb-Device.analog-stereo)" >&2
    echo "  - Enter number from list above" >&2
    echo "  - Press Enter for auto-detection" >&2
    echo -n "Selection [auto]: " >&2
    
    read -r selection </dev/tty
    
    if [ -z "$selection" ]; then
        echo "auto"
        return
    fi
    
    # Check if it's a number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        # Get the nth sink from the list
        local sink
        sink=$(pactl list short sinks | grep "alsa_output" | sed -n "${selection}p" | awk '{print $2}')
        if [ -n "$sink" ]; then
            echo "$sink"
        else
            echo "Invalid selection: $selection" >&2
            echo "auto"
        fi
    else
        # Assume it's a sink name
        echo "$selection"
    fi
}

configure_sinks() {
    echo ""
    info "Configure Audio Devices"
    echo "════════════════════════════════════════════════════════"
    echo ""
    
    detect_audio_devices
    
    echo ""
    PRIMARY_SINK=$(prompt_device_selection "Select PRIMARY sink (main output, usually USB/speakers):" "")
    echo ""
    SECONDARY_SINK=$(prompt_device_selection "Select SECONDARY sink (usually HDMI/capture card):" "")
    
    echo ""
    info "Configuration:"
    echo "  Primary sink:   ${PRIMARY_SINK:-auto-detect}"
    echo "  Secondary sink: ${SECONDARY_SINK:-auto-detect}"
}

install_scripts() {
    info "Installing scripts to ${INSTALL_DIR}..."
    
    mkdir -p "$INSTALL_DIR"
    
    # Main reset script
    cp "$SCRIPT_DIR/reset_pipewire.sh" "$INSTALL_DIR/reset-pipewire"
    chmod +x "$INSTALL_DIR/reset-pipewire"
    success "Installed reset-pipewire"
    
    # Helper scripts
    if [ -f "$SCRIPT_DIR/examples/audio-status.sh" ]; then
        cp "$SCRIPT_DIR/examples/audio-status.sh" "$INSTALL_DIR/audio-status"
        chmod +x "$INSTALL_DIR/audio-status"
        success "Installed audio-status"
    fi
    
    if [ -f "$SCRIPT_DIR/examples/reset-usb-audio.sh" ]; then
        cp "$SCRIPT_DIR/examples/reset-usb-audio.sh" "$INSTALL_DIR/reset-usb-audio"
        chmod +x "$INSTALL_DIR/reset-usb-audio"
        success "Installed reset-usb-audio"
    fi
    
    if [ -f "$SCRIPT_DIR/examples/pipewire-watchdog.sh" ]; then
        cp "$SCRIPT_DIR/examples/pipewire-watchdog.sh" "$INSTALL_DIR/pipewire-watchdog"
        chmod +x "$INSTALL_DIR/pipewire-watchdog"
        success "Installed pipewire-watchdog"
    fi
    
    if [ -f "$SCRIPT_DIR/examples/reset-pipewire-nuclear.sh" ]; then
        cp "$SCRIPT_DIR/examples/reset-pipewire-nuclear.sh" "$INSTALL_DIR/reset-pipewire-nuclear"
        chmod +x "$INSTALL_DIR/reset-pipewire-nuclear"
        success "Installed reset-pipewire-nuclear"
    fi
}

install_sample_rate_config() {
    info "Installing sample rate configuration..."
    
    mkdir -p "$PIPEWIRE_CONF_DIR"
    
    if [ -f "$SCRIPT_DIR/examples/99-custom-rate.conf" ]; then
        cp "$SCRIPT_DIR/examples/99-custom-rate.conf" "$PIPEWIRE_CONF_DIR/"
        success "Installed 48kHz sample rate config"
        info "PipeWire will use 48kHz after next restart"
    else
        warning "Sample rate config not found, skipping"
    fi
}

install_no_suspend_config() {
    info "Installing audio power-save disable configuration..."
    
    local WIREPLUMBER_CONF_DIR="${CONFIG_DIR}/wireplumber/wireplumber.conf.d"
    mkdir -p "$WIREPLUMBER_CONF_DIR"
    
    if [ -f "$SCRIPT_DIR/examples/50-no-suspend.conf" ]; then
        cp "$SCRIPT_DIR/examples/50-no-suspend.conf" "$WIREPLUMBER_CONF_DIR/"
        success "Installed no-suspend config (prevents audio popping)"
        info "Audio devices will stay active instead of entering power-save mode"
    else
        warning "No-suspend config not found, skipping"
    fi
}

configure_rodecaster_default() {
    echo ""
    info "RØDECaster Pro II Default Device Configuration"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "The RØDECaster Pro II has two known issues on Linux:"
    echo ""
    echo "  1. Default device resets to HDMI after every reboot/replug"
    echo "     because PipeWire node name suffixes change each time."
    echo ""
    echo "  2. Microphone input levels are lower than on Windows"
    echo "     because Linux uses the generic USB audio driver instead"
    echo "     of RØDE's ASIO driver which applies gain normalization."
    echo ""

    # Detect if a RodeCaster is present
    local rode_detected=false
    if pactl list short sinks 2>/dev/null | grep -q "R__DE_R__DECaster_Pro_II"; then
        rode_detected=true
        success "RØDECaster Pro II detected!"
    else
        info "RØDECaster Pro II not currently connected"
    fi

    echo ""
    echo -n "Install RØDECaster auto-default and priority fix? [Y/n]: "
    read -r install_rode
    if [[ "$install_rode" =~ ^[Nn] ]]; then
        info "Skipping RØDECaster configuration"
        RODE_INSTALLED=false
        return
    fi

    local WIREPLUMBER_CONF_DIR="${CONFIG_DIR}/wireplumber/wireplumber.conf.d"
    local WIREPLUMBER_SCRIPTS_DIR="${CONFIG_DIR}/wireplumber/scripts"
    local WIREPLUMBER_LUA_DIR="${CONFIG_DIR}/wireplumber/main.lua.d"

    mkdir -p "$WIREPLUMBER_CONF_DIR" "$WIREPLUMBER_SCRIPTS_DIR" "$WIREPLUMBER_LUA_DIR"

    # Install priority boost config
    if [ -f "$SCRIPT_DIR/examples/51-rodecaster-priority.conf" ]; then
        cp "$SCRIPT_DIR/examples/51-rodecaster-priority.conf" "$WIREPLUMBER_CONF_DIR/"
        success "Installed RØDECaster priority boost config"
    fi

    # Install auto-default Lua script
    if [ -f "$SCRIPT_DIR/examples/rodecaster-default.lua" ]; then
        cp "$SCRIPT_DIR/examples/rodecaster-default.lua" "$WIREPLUMBER_SCRIPTS_DIR/"
        success "Installed RØDECaster auto-default script"
    fi

    # Install Lua loader
    if [ -f "$SCRIPT_DIR/examples/91-rodecaster-default.lua" ]; then
        cp "$SCRIPT_DIR/examples/91-rodecaster-default.lua" "$WIREPLUMBER_LUA_DIR/"
        success "Installed WirePlumber script loader"
    fi

    RODE_INSTALLED=true

    # Configure input volume boost
    echo ""
    echo "Microphone Input Volume Boost"
    echo "─────────────────────────────────────────────────────"
    echo "Linux USB audio levels are typically lower than Windows."
    echo "A 125% boost compensates for the missing ASIO gain normalization."
    echo ""
    echo -n "Apply 125% input volume boost? [Y/n]: "
    read -r boost_vol
    if [[ ! "$boost_vol" =~ ^[Nn] ]]; then
        if $rode_detected; then
            # Apply to whichever input is currently active
            local rode_src
            rode_src=$(pactl list sources short 2>/dev/null | grep "R__DE" | grep -v monitor | awk '{print $2}')
            if [ -n "$rode_src" ]; then
                pactl set-source-volume "$rode_src" 125%
                success "Set input volume to 125% on: $rode_src"
            fi
        else
            info "Volume boost will apply when the RØDECaster is connected"
            info "Run: pactl set-source-volume \$(pactl list sources short | grep R__DE | grep -v monitor | awk '{print \$2}') 125%"
        fi
    fi

    echo ""
    success "RØDECaster default device fix installed!"
    info "WirePlumber restart required to activate (will happen on next reboot or run: systemctl --user restart wireplumber)"
}

configure_systemd_services() {
    echo ""
    info "Systemd Service Configuration"
    echo "════════════════════════════════════════════════════════"
    echo ""
    
    mkdir -p "$SYSTEMD_USER_DIR"
    
    # Auto-start on login
    echo -n "Enable auto-start on login? [Y/n]: "
    read -r enable_login
    if [[ ! "$enable_login" =~ ^[Nn] ]]; then
        if [ -f "$SCRIPT_DIR/examples/pipewire-combined.service" ]; then
            cp "$SCRIPT_DIR/examples/pipewire-combined.service" "$SYSTEMD_USER_DIR/"
            systemctl --user daemon-reload
            systemctl --user enable pipewire-combined.service
            success "Enabled auto-start on login"
        fi
    fi
    
    # Watchdog service
    echo -n "Enable automatic watchdog monitoring? [Y/n]: "
    read -r enable_watchdog
    if [[ ! "$enable_watchdog" =~ ^[Nn] ]]; then
        if [ -f "$SCRIPT_DIR/examples/pipewire-watchdog.service" ]; then
            cp "$SCRIPT_DIR/examples/pipewire-watchdog.service" "$SYSTEMD_USER_DIR/"
            systemctl --user daemon-reload
            systemctl --user enable --now pipewire-watchdog.service
            success "Enabled and started watchdog service"
        fi
    fi
}

configure_reset_behavior() {
    echo ""
    info "Reset Behavior Configuration"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "USB Device Reset: Some devices (like RØDECaster Pro II) require"
    echo "a USB-level reset to properly reinitialize audio routing."
    echo ""
    echo "Options:"
    echo "  1) Always reset USB devices (Recommended - works like physical unplug/replug)"
    echo "  2) Never reset USB devices (Use if you have issues with USB reset)"
    echo "  3) Manual control via RESET_USB=1 environment variable"
    echo ""
    echo -n "Choose [1]: "
    read -r usb_reset_choice
    
    case "${usb_reset_choice:-1}" in
        1)
            USB_RESET_DEFAULT="1"
            success "USB reset enabled by default (recommended)"
            ;;
        2)
            USB_RESET_DEFAULT="0"
            warning "USB reset disabled by default"
            echo "  You can manually run: reset-usb-audio"
            ;;
        3)
            USB_RESET_DEFAULT="manual"
            info "USB reset requires RESET_USB=1 environment variable"
            echo "  Example: RESET_USB=1 reset-pipewire"
            ;;
        *)
            USB_RESET_DEFAULT="1"
            info "Using default: USB reset enabled"
            ;;
    esac
}

update_reset_script_config() {
    if [ -f "$INSTALL_DIR/reset-pipewire" ]; then
        info "Updating configuration in reset-pipewire..."
        
        # Update PRIMARY_SINK if specified
        if [ -n "$PRIMARY_SINK" ] && [ "$PRIMARY_SINK" != "auto" ]; then
            sed -i "s|^PRIMARY_SINK=.*|PRIMARY_SINK=\"$PRIMARY_SINK\"|" "$INSTALL_DIR/reset-pipewire"
        fi
        
        # Update SECONDARY_SINK if specified
        if [ -n "$SECONDARY_SINK" ] && [ "$SECONDARY_SINK" != "auto" ]; then
            sed -i "s|^SECONDARY_SINK=.*|SECONDARY_SINK=\"$SECONDARY_SINK\"|" "$INSTALL_DIR/reset-pipewire"
        fi
        
        # Update USB reset behavior
        if [ -n "$USB_RESET_DEFAULT" ]; then
            case "$USB_RESET_DEFAULT" in
                1)
                    # Set default to enabled: ${RESET_USB:-1}
                    sed -i 's/if \[ "${RESET_USB:-[^}]*}" != "1" \];/if [ "${RESET_USB:-1}" != "1" ];/' "$INSTALL_DIR/reset-pipewire"
                    ;;
                0)
                    # Set default to disabled: ${RESET_USB:-0}
                    sed -i 's/if \[ "${RESET_USB:-[^}]*}" != "1" \];/if [ "${RESET_USB:-0}" != "1" ];/' "$INSTALL_DIR/reset-pipewire"
                    ;;
                manual)
                    # Require explicit RESET_USB=1: ${RESET_USB:-}
                    sed -i 's/if \[ "${RESET_USB:-[^}]*}" != "1" \];/if [ "${RESET_USB:-}" != "1" ];/' "$INSTALL_DIR/reset-pipewire"
                    ;;
            esac
        fi
        
        # Update exclusion patterns if configured
        if [ -n "$EXCLUDE_PATTERNS_STR" ]; then
            sed -i "s|^EXCLUDE_PATTERNS=.*|EXCLUDE_PATTERNS=($EXCLUDE_PATTERNS_STR)|" "$INSTALL_DIR/reset-pipewire"
            
            # Also update nuclear reset and watchdog
            if [ -f "$INSTALL_DIR/reset-pipewire-nuclear" ]; then
                sed -i "s|^EXCLUDE_PATTERNS=.*|EXCLUDE_PATTERNS=($EXCLUDE_PATTERNS_STR)|" "$INSTALL_DIR/reset-pipewire-nuclear"
            fi
            if [ -f "$INSTALL_DIR/pipewire-watchdog" ]; then
                sed -i "s|^EXCLUDE_PATTERNS=.*|EXCLUDE_PATTERNS=($EXCLUDE_PATTERNS_STR)|" "$INSTALL_DIR/pipewire-watchdog"
            fi
        fi
        
        success "Configured reset-pipewire"
    fi
}

configure_device_exclusions() {
    echo ""
    info "Device Exclusion Configuration"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "You can exclude specific audio devices from the combined sink."
    echo "Excluded devices will be completely disabled (profile set to 'off')."
    echo "This is useful for USB devices you don't want audio going to,"
    echo "like USB clocks with speakers, USB hubs with audio, etc."
    echo ""
    
    # Show available devices
    echo "Current audio devices:"
    echo "─────────────────────────────────────────────────────"
    pactl list short sinks 2>/dev/null | grep "alsa_output" | nl -w2 -s". " || true
    echo ""
    
    echo -n "Do you want to exclude any devices? [y/N]: "
    read -r exclude_devices
    
    EXCLUDE_PATTERNS_STR=""
    
    if [[ "$exclude_devices" =~ ^[Yy] ]]; then
        echo ""
        echo "Enter device patterns to exclude (partial names work)."
        echo "Common examples:"
        echo "  - Jieli_Technology  (USB clock speakers)"
        echo "  - USB_Speaker       (generic USB speakers)"
        echo ""
        echo "Enter patterns one per line. Press Enter on empty line when done:"
        
        local patterns=()
        while true; do
            echo -n "Pattern: "
            read -r pattern </dev/tty
            if [ -z "$pattern" ]; then
                break
            fi
            patterns+=("\"$pattern\"")
            info "Added exclusion: $pattern"
        done
        
        if [ ${#patterns[@]} -gt 0 ]; then
            EXCLUDE_PATTERNS_STR=$(IFS=" "; echo "${patterns[*]}")
            success "Configured ${#patterns[@]} exclusion pattern(s)"
        fi
    else
        info "No device exclusions configured"
    fi
}

configure_nvidia_integration() {
    echo ""
    info "NVIDIA Capture Card Integration (Optional)"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "If you use an HDMI capture card with the NVIDIA X11 Multi-Monitor"
    echo "Toolkit, the combined audio sink can be created automatically"
    echo "whenever the capture card is detected (at boot and on hotplug)."
    echo ""
    echo "  https://github.com/ChiefGyk3D/nvidia-display-layout"
    echo ""
    
    if [ -x "$HOME/.screenlayout/apply-layout.sh" ]; then
        if grep -q "RESET_PIPEWIRE_BIN" "$HOME/.screenlayout/apply-layout.sh" 2>/dev/null; then
            success "NVIDIA display layout with audio integration already installed"
            echo "  reset-pipewire will be called automatically when a capture card is detected."
            return
        else
            warning "NVIDIA display layout found but without audio integration"
            echo "  Re-run the NVIDIA setup wizard to enable PipeWire integration:"
            echo "  cd nvidia-display-layout && ./setup-wizard.sh"
            echo ""
            
            read -p "Patch existing apply-layout.sh to add audio integration? [Y/n]: " patch_layout
            if [[ ! "$patch_layout" =~ ^[Nn] ]]; then
                # Check if there's a capture card branch in the script
                if grep -q "nvidia-capture.sh" "$HOME/.screenlayout/apply-layout.sh" 2>/dev/null; then
                    # Detect the NVIDIA audio card
                    local nvidia_audio_card
                    nvidia_audio_card=$(pactl list short cards 2>/dev/null | grep -i "pci.*nvidia\|nvidia.*pci\|pci.*hdmi" | head -1 | awk '{print $2}')
                    nvidia_audio_card="${nvidia_audio_card:-alsa_card.pci-0000_08_00.1}"
                    
                    # Add the integration block after nvidia-capture.sh call
                    if ! grep -q "RESET_PIPEWIRE_BIN" "$HOME/.screenlayout/apply-layout.sh" 2>/dev/null; then
                        sed -i '/^export XAUTHORITY/a\
\
NVIDIA_AUDIO_CARD="'"$nvidia_audio_card"'"\
HDMI_PROFILE="output:hdmi-stereo"\
\
# Optional: Path to reset-pipewire script (installed by pipewire_sink project)\
# Set to empty string or "none" to disable audio integration\
RESET_PIPEWIRE_BIN="${RESET_PIPEWIRE_BIN:-$HOME/.local/bin/reset-pipewire}"' "$HOME/.screenlayout/apply-layout.sh"
                        
                        # Add HDMI handshake fix and PipeWire reset after the capture.sh call
                        sed -i '/nvidia-capture.sh/a\
\
    # Wait for HDMI audio handshake after MetaMode change\
    sleep 2\
\
    # Force NVIDIA HDMI audio profile active\
    if command -v pactl \&>/dev/null; then\
        pactl set-card-profile "$NVIDIA_AUDIO_CARD" "$HDMI_PROFILE" 2>/dev/null\
    fi\
\
    # Reset PipeWire and create combined audio sink\
    if [ -n "$RESET_PIPEWIRE_BIN" ] \&\& [ "$RESET_PIPEWIRE_BIN" != "none" ] \&\& [ -x "$RESET_PIPEWIRE_BIN" ]; then\
        echo "$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"') - Capture card detected, resetting PipeWire combined sink..."\
        sleep 3\
        "$RESET_PIPEWIRE_BIN" 2>\&1 | while IFS= read -r line; do\
            echo "$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"') - [pipewire] $line"\
        done\
    fi' "$HOME/.screenlayout/apply-layout.sh"
                        
                        success "Patched apply-layout.sh with audio integration"
                    fi
                else
                    warning "No capture card detected in apply-layout.sh — skipping patch"
                    echo "  Re-run the NVIDIA setup wizard with capture card enabled:"
                    echo "  cd nvidia-display-layout && ./setup-wizard.sh"
                fi
            fi
        fi
    else
        echo -n "Do you use an NVIDIA capture card for streaming? [y/N]: "
        read -r has_nvidia
        if [[ "$has_nvidia" =~ ^[Yy] ]]; then
            echo ""
            read -p "Install NVIDIA display layout toolkit now? [Y/n]: " install_nvidia
            if [[ ! "$install_nvidia" =~ ^[Nn] ]]; then
                local nvidia_tmp
                nvidia_tmp=$(mktemp -d)
                echo ""
                echo -e "${BLUE}ℹ${NC} Cloning nvidia-display-layout..."
                if git clone https://github.com/ChiefGyk3D/nvidia-display-layout.git "$nvidia_tmp" 2>/dev/null; then
                    echo -e "${GREEN}✓${NC} Cloned nvidia-display-layout"
                    echo ""
                    echo "Launching NVIDIA setup wizard..."
                    echo "The wizard will configure your displays and capture card."
                    echo "Audio integration will be enabled automatically since reset-pipewire is installed."
                    echo ""
                    (cd "$nvidia_tmp" && ./setup-wizard.sh)
                    rm -rf "$nvidia_tmp"
                    
                    if [ -x "$HOME/.screenlayout/apply-layout.sh" ] && grep -q "RESET_PIPEWIRE_BIN" "$HOME/.screenlayout/apply-layout.sh" 2>/dev/null; then
                        echo ""
                        echo -e "${GREEN}✓${NC} NVIDIA + PipeWire integration is now active"
                    fi
                else
                    echo -e "${RED}✗${NC} Failed to clone nvidia-display-layout"
                    echo "  Install it manually later:"
                    echo "  git clone https://github.com/ChiefGyk3D/nvidia-display-layout.git"
                    echo "  cd nvidia-display-layout && ./setup-wizard.sh"
                    rm -rf "$nvidia_tmp"
                fi
            else
                echo ""
                echo "Install it manually later:"
                echo "  git clone https://github.com/ChiefGyk3D/nvidia-display-layout.git"
                echo "  cd nvidia-display-layout && ./setup-wizard.sh"
                echo ""
                info "The NVIDIA setup wizard will detect reset-pipewire and enable"
                info "automatic combined sink creation on capture card detection."
            fi
        else
            info "Skipped NVIDIA integration"
        fi
    fi
}

test_installation() {
    echo ""
    info "Testing installation..."
    
    if [ -x "$INSTALL_DIR/reset-pipewire" ]; then
        echo ""
        echo -n "Run reset-pipewire now to test? [Y/n]: "
        read -r run_test
        if [[ ! "$run_test" =~ ^[Nn] ]]; then
            "$INSTALL_DIR/reset-pipewire"
        fi
    fi
}

print_summary() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  Installation Complete!"
    echo "════════════════════════════════════════════════════════"
    echo ""
    success "Installed scripts to: $INSTALL_DIR"
    success "Installed configs to: $CONFIG_DIR"
    success "Audio power-save disabled (no more audio pop on playback start)"
    if [ "${RODE_INSTALLED:-false}" = true ]; then
        success "RØDECaster Pro II: auto-default + priority boost installed"
    fi
    echo ""
    info "Available commands:"
    echo "  reset-pipewire          - Reset PipeWire and create combined sink"
    echo "  audio-status            - Show audio system status"
    echo "  reset-usb-audio         - Reset USB audio devices"
    echo "  reset-pipewire-nuclear  - Aggressive reset for severe failures"
    echo ""
    info "Environment options:"
    if [ "$USB_RESET_DEFAULT" = "0" ]; then
        echo "  RESET_USB=1 reset-pipewire       - Enable USB device reset"
    elif [ "$USB_RESET_DEFAULT" = "manual" ]; then
        echo "  RESET_USB=1 reset-pipewire       - Enable USB device reset (required)"
    else
        echo "  RESET_USB=0 reset-pipewire       - Disable USB device reset"
    fi
    echo "  CLEAN_STATE=1 reset-pipewire     - Clean WirePlumber state"
    echo ""
    if [ -n "$EXCLUDE_PATTERNS_STR" ]; then
        info "Device exclusions configured: $EXCLUDE_PATTERNS_STR"
        echo ""
    fi
    info "For help and troubleshooting, see:"
    echo "  ${SCRIPT_DIR}/README.md"
    echo ""
    
    if systemctl --user is-enabled pipewire-watchdog.service >/dev/null 2>&1; then
        success "Watchdog will automatically monitor and fix audio issues"
    fi
    
    if [ -x "$HOME/.screenlayout/apply-layout.sh" ] && grep -q "RESET_PIPEWIRE_BIN" "$HOME/.screenlayout/apply-layout.sh" 2>/dev/null; then
        success "NVIDIA capture card integration active (auto-creates combined sink on hotplug)"
    fi
    
    echo ""
}

main() {
    print_header
    check_dependencies
    
    echo ""
    echo -n "Proceed with installation? [Y/n]: "
    read -r proceed
    if [[ "$proceed" =~ ^[Nn] ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    
    echo ""
    echo -n "Configure audio devices now? (You can use auto-detection) [Y/n]: "
    read -r config_devices
    if [[ ! "$config_devices" =~ ^[Nn] ]]; then
        configure_sinks
    else
        PRIMARY_SINK=""
        SECONDARY_SINK=""
    fi
    
    echo ""
    install_scripts
    install_sample_rate_config
    install_no_suspend_config
    configure_rodecaster_default
    configure_reset_behavior
    configure_device_exclusions
    update_reset_script_config
    configure_systemd_services
    configure_nvidia_integration
    test_installation
    print_summary
}

main "$@"
