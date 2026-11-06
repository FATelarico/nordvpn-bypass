#!/bin/bash
set -euo pipefail

GROUP="nordvpn-bypass"
TABLE="app_bypass"

# Check that NordVPN firewall is enabled.
# Discover the NordVPN-authorised user.
VPN_GROUP="nordvpn"

mapfile -t VPN_USERS < <(
    getent group "$VPN_GROUP" | awk -F: '{print $4}' | tr ',' '\n' | sed '/^$/d'
)

if [[ ${#VPN_USERS[@]} -ne 1 ]]; then
    echo "Expected exactly one user in the $VPN_GROUP group."
    echo "Found: ${VPN_USERS[*]:-none}"
    exit 1
fi

VPN_USER="${VPN_USERS[0]}"
VPN_HOME="$(getent passwd "$VPN_USER" | cut -d: -f6)"

if [[ -z "$VPN_HOME" || ! -d "$VPN_HOME" ]]; then
    echo "Could not determine home directory for $VPN_USER."
    exit 1
fi

SETTINGS="$(runuser -u "$VPN_USER" -- env \
    HOME="$VPN_HOME" \
    USER="$VPN_USER" \
    LOGNAME="$VPN_USER" \
    nordvpn settings)"

if ! grep -qE '^Firewall:[[:space:]]+enabled' <<< "$SETTINGS"; then
    echo "NordVPN firewall is not enabled."
    exit 1
fi

# Retrieve the current NordVPN firewall mark.
MARK="$(awk -F': *' \
    '/^[[:space:]]*Firewall Mark:/ {print $2; exit}' \
    <<< "$SETTINGS")"

if [[ ! "$MARK" =~ ^0x[[:xdigit:]]+$ ]]; then
    echo "Could not determine NordVPN firewall mark."
    exit 1
fi

# Retrieve the current numeric group ID.
GID="$(getent group "$GROUP" | cut -d: -f3)"

if [[ ! "$GID" =~ ^[0-9]+$ ]]; then
    echo "Could not determine GID for $GROUP."
    exit 1
fi

# Wait for NordVPN's firewall table to exist.
for ((i=0; i<60; i++)); do
    if nft list table inet nordvpn >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! nft list table inet nordvpn >/dev/null 2>&1; then
    echo "NordVPN firewall table was not initialised."
    exit 1
fi

# Recreate only our dedicated table.
nft delete table inet "$TABLE" 2>/dev/null || true

nft -f - <<EOF
add table inet $TABLE

add chain inet $TABLE output {
    type route hook output priority mangle - 1;
    policy accept;
}

add rule inet $TABLE output \
    meta skgid $GID \
    meta mark set $MARK \
    counter
EOF

echo "NordVPN application bypass configured."
echo "Group: $GROUP (GID $GID)"
echo "Firewall mark: $MARK"
