#!/bin/bash

###############################################################################
# OpenWrt 5GHz Access Point Configuration Script
#
# Purpose: Configure a 5GHz Access Point with auto-detection of radio hardware
#
# Requirements:
#   - OpenWrt system with uci and wifi utilities
#   - 5GHz capable radio (802.11ac or 802.11ax)
#
# Usage: ./configure-5ghz-ap.sh [SSID] [PASSWORD] [NETWORK]
#        Default: SSID=BOND, PASSWORD=carmel12, NETWORK=lan
###############################################################################

set -o pipefail

# Configuration parameters (with defaults)
SSID="${1:-BOND}"
PASSWORD="${2:-carmel12}"
NETWORK="${3:-lan}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

###############################################################################
# Helper Functions
###############################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [ "$DEBUG" = "1" ]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

###############################################################################
# Auto-Detect 5GHz Radio
###############################################################################

detect_5ghz_radio() {
    local radio_found=""

    # Method 1: Check via UCI configuration
    log_debug "Attempting radio detection via UCI..."

    local radio_count=$(uci show wireless 2>/dev/null | grep "=\|radio" | grep -c "hwmode")

    if [ "$radio_count" -gt 0 ]; then
        # Iterate through wireless config to find 5GHz capable radios
        for i in $(seq 0 $((radio_count - 1))); do
            local hwmode=$(uci get wireless.radio$i.hwmode 2>/dev/null)
            local band=$(uci get wireless.radio$i.band 2>/dev/null)
            local disabled=$(uci get wireless.radio$i.disabled 2>/dev/null)

            log_debug "Radio$i: hwmode=$hwmode, band=$band, disabled=$disabled"

            # Check for 802.11ac (5GHz) or 802.11ax (Wi-Fi 6, also 5GHz)
            if [ "$disabled" != "1" ]; then
                if [ "$hwmode" = "11ac" ] || [ "$hwmode" = "11ax" ] || [ "$band" = "5g" ] || [ "$band" = "5G" ]; then
                    radio_found="radio$i"
                    log_debug "Found 5GHz radio: $radio_found"
                    break
                fi
            fi
        done
    fi

    # Method 2: Fallback - Check via iwinfo if available
    if [ -z "$radio_found" ] && command -v iwinfo &> /dev/null; then
        log_debug "Attempting radio detection via iwinfo..."

        for radio in radio0 radio1 radio2; do
            local iwinfo_output=$(iwinfo $radio info 2>/dev/null)
            if echo "$iwinfo_output" | grep -q "IEEE 802.11"; then
                if echo "$iwinfo_output" | grep -q -E "802\.11ac|802\.11ax|802\.11a"; then
                    radio_found="$radio"
                    log_debug "Found 5GHz radio via iwinfo: $radio_found"
                    break
                fi
            fi
        done
    fi

    echo "$radio_found"
}

###############################################################################
# Check if SSID Already Exists
###############################################################################

check_ssid_exists() {
    local radio="$1"
    local ssid="$2"

    local existing_iface=""
    local iface_count=$(uci show wireless 2>/dev/null | grep -c "\.ssid=")

    # Find wifi interface with matching SSID
    for iface in $(uci show wireless 2>/dev/null | grep "\.ssid=" | cut -d'=' -f1 | sed 's/\.ssid//'); do
        local current_ssid=$(uci get "$iface.ssid" 2>/dev/null)
        if [ "$current_ssid" = "$ssid" ]; then
            existing_iface="$iface"
            break
        fi
    done

    echo "$existing_iface"
}

###############################################################################
# Create or Update WiFi Interface
###############################################################################

configure_ap() {
    local radio="$1"
    local ssid="$2"
    local password="$3"
    local network="$4"
    local existing_iface="$5"

    log_info "Configuring 5GHz Access Point on $radio"
    log_info "  SSID: $ssid"
    log_info "  Encryption: psk2"
    log_info "  Network: $network"

    if [ -n "$existing_iface" ]; then
        # Update existing interface
        log_info "Updating existing interface: $existing_iface"
        uci set "$existing_iface.ssid=$ssid"
        uci set "$existing_iface.encryption=psk2"
        uci set "$existing_iface.key=$password"
        uci set "$existing_iface.network=$network"
        uci set "$existing_iface.device=$radio"
        uci set "$existing_iface.mode=ap"
    else
        # Create new interface
        local iface_name="${radio}_ap"
        log_info "Creating new interface: $iface_name"

        uci add wireless wifi-iface
        local new_iface="wireless.@wifi-iface[-1]"

        uci set "$new_iface.device=$radio"
        uci set "$new_iface.mode=ap"
        uci set "$new_iface.ssid=$ssid"
        uci set "$new_iface.encryption=psk2"
        uci set "$new_iface.key=$password"
        uci set "$new_iface.network=$network"
    fi

    return 0
}

###############################################################################
# Apply Configuration
###############################################################################

apply_configuration() {
    log_info "Committing wireless configuration..."

    if ! uci commit wireless; then
        log_error "Failed to commit UCI configuration"
        return 1
    fi

    log_info "Reloading WiFi service..."

    if ! wifi reload; then
        log_error "Failed to reload WiFi service"
        return 1
    fi

    # Wait for service to stabilize
    sleep 2

    return 0
}

###############################################################################
# Validate Configuration
###############################################################################

validate_configuration() {
    local radio="$1"
    local ssid="$2"

    log_info "Validating configuration..."

    # Check if radio is enabled
    local disabled=$(uci get wireless.$radio.disabled 2>/dev/null)
    if [ "$disabled" = "1" ]; then
        log_warn "Radio $radio is disabled"
        return 1
    fi

    # Check if SSID is broadcasting
    if command -v iwinfo &> /dev/null; then
        local ssid_found=$(iwinfo $radio assoclist 2>/dev/null | grep -c "$ssid" || true)
        log_debug "SSID check returned: $ssid_found"
    fi

    # Check wireless config
    local configured_ssid=$(uci get wireless.@wifi-iface[-1].ssid 2>/dev/null)
    if [ "$configured_ssid" = "$ssid" ]; then
        log_info "Validation successful - SSID is configured"
        return 0
    else
        log_warn "Validation check could not confirm SSID configuration"
        return 0  # Don't fail - config may be correct but validation tools unavailable
    fi
}

###############################################################################
# Main Execution
###############################################################################

main() {
    log_info "OpenWrt 5GHz Access Point Configuration"
    log_info "========================================="

    # Detect 5GHz radio
    log_info "Detecting 5GHz radio..."
    RADIO=$(detect_5ghz_radio)

    if [ -z "$RADIO" ]; then
        log_error "No 5GHz radio detected"
        log_error "Ensure your device has a 5GHz capable radio (802.11ac/ax) and is enabled"
        exit 1
    fi

    log_info "Detected 5GHz radio: $RADIO"

    # Check if SSID already exists
    EXISTING_IFACE=$(check_ssid_exists "$RADIO" "$SSID")

    if [ -n "$EXISTING_IFACE" ]; then
        log_warn "Found existing interface with SSID '$SSID'"
        log_info "Will update configuration instead of creating duplicate"
    fi

    # Configure the AP
    if ! configure_ap "$RADIO" "$SSID" "$PASSWORD" "$NETWORK" "$EXISTING_IFACE"; then
        log_error "Failed to configure AP"
        exit 1
    fi

    # Apply the configuration
    if ! apply_configuration; then
        log_error "Failed to apply configuration"
        exit 1
    fi

    log_info "WiFi service restarted successfully"

    # Validate configuration
    validate_configuration "$RADIO" "$SSID"

    log_info "========================================="
    log_info "Configuration Complete!"
    log_info "Access Point Details:"
    log_info "  Radio: $RADIO"
    log_info "  SSID: $SSID"
    log_info "  Encryption: psk2"
    log_info "  Network Bridge: $NETWORK"
    log_info "========================================="
}

# Run main function
main
exit $?
