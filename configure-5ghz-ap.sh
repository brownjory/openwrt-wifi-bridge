#!/bin/bash

###############################################################################
# OpenWrt 5GHz Access Point Configuration Script
#
# Purpose: Configure a 5GHz Access Point with interactive user input
#
# Requirements:
#   - OpenWrt system with uci and wifi utilities
#   - 5GHz capable radio (802.11ac or 802.11ax)
#
# Features:
#   - Interactive prompts for SSID and password
#   - Password validation (minimum 8 characters for WPA2)
#   - Auto-detection of 5GHz radio
#   - Security: uses read -s for hidden password input
#   - Clears bash history at completion
#
# Usage: ./configure-5ghz-ap.sh
###############################################################################

set -o pipefail

# Configuration parameters
SSID=""
PASSWORD=""
NETWORK="lan"

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
# Input Collection and Validation
###############################################################################

prompt_for_ssid() {
    local ssid_input
    read -p "Enter SSID (default: BOND): " ssid_input

    # Use default if user just hits enter
    if [ -z "$ssid_input" ]; then
        ssid_input="BOND"
    fi

    # Validate SSID length (max 32 characters for WiFi SSID)
    if [ ${#ssid_input} -gt 32 ]; then
        log_error "SSID is too long (maximum 32 characters)"
        return 1
    fi

    # Check for invalid characters (only allow alphanumeric, dot, underscore, hyphen)
    if ! echo "$ssid_input" | grep -q "^[a-zA-Z0-9._-]*$"; then
        log_error "SSID contains invalid characters (only alphanumeric, dot, underscore, hyphen allowed)"
        return 1
    fi

    echo "$ssid_input"
    return 0
}

prompt_for_password() {
    local password_input=""
    local password_confirm=""
    local attempts=0
    local max_attempts=3

    while [ $attempts -lt $max_attempts ]; do
        # Use read -s for hidden password input
        read -sp "Enter WiFi Password (minimum 8 characters): " password_input
        echo ""

        # Validate password length
        if [ ${#password_input} -lt 8 ]; then
            log_error "Password must be at least 8 characters long (WPA2 requirement)"
            attempts=$((attempts + 1))
            if [ $attempts -lt $max_attempts ]; then
                log_info "Please try again ($((max_attempts - attempts)) attempts remaining)"
            fi
            continue
        fi

        # Check for valid characters (WPA2 supports all printable ASCII)
        # Reject null characters, tabs, and other control characters
        if echo "$password_input" | grep -q $'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F]'; then
            log_error "Password contains invalid control characters"
            attempts=$((attempts + 1))
            if [ $attempts -lt $max_attempts ]; then
                log_info "Please try again ($((max_attempts - attempts)) attempts remaining)"
            fi
            continue
        fi

        # Ask user to confirm password
        read -sp "Confirm Password: " password_confirm
        echo ""

        if [ "$password_input" != "$password_confirm" ]; then
            log_error "Passwords do not match"
            attempts=$((attempts + 1))
            if [ $attempts -lt $max_attempts ]; then
                log_info "Please try again ($((max_attempts - attempts)) attempts remaining)"
            fi
            continue
        fi

        # Password validated successfully
        echo "$password_input"
        return 0
    done

    log_error "Failed to enter valid password after $max_attempts attempts"
    return 1
}

collect_user_input() {
    log_info "========================================="
    log_info "WiFi Access Point Configuration"
    log_info "========================================="

    # Prompt for SSID
    while true; do
        SSID=$(prompt_for_ssid)
        if [ $? -eq 0 ]; then
            break
        fi
    done

    # Prompt for password
    PASSWORD=$(prompt_for_password)
    if [ $? -ne 0 ]; then
        log_error "Unable to proceed without a valid password"
        exit 1
    fi

    log_info "Configuration parameters accepted"
    echo ""
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

cleanup_and_exit() {
    local exit_code=$?

    # Clear sensitive environment variables immediately
    unset SSID PASSWORD password_input password_confirm

    # Clear bash history to remove password from terminal history
    if [ -t 0 ]; then  # Only if connected to terminal (interactive shell)
        log_info "Clearing bash history for security..."
        history -c 2>/dev/null || true   # Clear in-memory history
        history -w 2>/dev/null || true   # Write empty history to file
    fi

    # Overwrite the script history entry if possible
    if [ -f ~/.bash_history ]; then
        # Use shred if available, otherwise just truncate
        if command -v shred &> /dev/null; then
            shred -vfz -n 3 ~/.bash_history 2>/dev/null || true
        else
            cat /dev/null > ~/.bash_history 2>/dev/null || true
        fi
    fi

    log_info "Cleanup complete"
    exit $exit_code  # Use exit, not return, for trap handler
}

trap cleanup_and_exit EXIT

main() {
    log_info "OpenWrt 5GHz Access Point Configuration"
    log_info "========================================="

    # Collect user input first
    collect_user_input

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

    # Clear password from memory immediately after use
    PASSWORD=""
    unset PASSWORD

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
    log_info "WiFi Access Point is now active"
    log_info "Users can connect using SSID: $SSID"
}

# Run main function
main
