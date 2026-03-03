#!/usr/bin/env bash
# Outputs only the machine code (SHA256 of MAC + public IP). No other output.

get_machine_code() {
    local OS_TYPE
    OS_TYPE=$(uname | tr '[:upper:]' '[:lower:]')
    local MAC_ADDR=""
    local PUBLIC_IP=""

    # 1. Get MAC Address (First non-loopback, non-virtual interface)
    if [[ "$OS_TYPE" == "linux" ]]; then
        INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
        if [ -n "$INTERFACE" ]; then
            MAC_ADDR=$(cat /sys/class/net/$INTERFACE/address 2>/dev/null || ip link show "$INTERFACE" | awk '/ether/ {print $2}')
        fi
    elif [[ "$OS_TYPE" == "darwin" ]]; then
        MAC_ADDR=$(networksetup -listallhardwareports | awk '/Hardware Port: (Wi-Fi|Ethernet)/{getline; getline; print $3; exit}' 2>/dev/null || ifconfig | awk '/ether / {print $2; exit}')
    else
        echo "❌ Unsupported OS: $OS_TYPE" >&2
        exit 1
    fi
    MAC_ADDR=$(echo "$MAC_ADDR" | tr -d '[:space:]')

    # 2. Get Public IP Address
    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "0.0.0.0")
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '\r\n')

    # 3. Combine and Hash
    COMBINED_STRING="${MAC_ADDR}_${PUBLIC_IP}"
    local HASH_RESULT

    if command -v shasum >/dev/null 2>&1; then
        HASH_RESULT=$(printf "%s" "$COMBINED_STRING" | shasum -a 256 | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
        HASH_RESULT=$(printf "%s" "$COMBINED_STRING" | sha256sum | awk '{print $1}')
    else
        echo "❌ Hash utility (shasum or sha256sum) not found." >&2
        exit 1
    fi

    echo "$HASH_RESULT"
}

get_machine_code
