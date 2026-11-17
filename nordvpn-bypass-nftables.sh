#!/usr/bin/env bash
# Apply or remove this project's nftables rule using the shared system config.
set -Eeuo pipefail

readonly CONFIG_FILE="/etc/nordvpn-bypass.conf"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -r "$CONFIG_FILE" ]] || die "Configuration file not found: $CONFIG_FILE"

# Parse the simple KEY=value file rather than sourcing it as shell code.
VPN_USER=""
BYPASS_GROUP=""
NFT_FAMILY="inet"
NFT_TABLE="app_bypass"
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] ||
        die "Invalid configuration line in $CONFIG_FILE: $line"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
        VPN_USER) VPN_USER="$value" ;;
        BYPASS_GROUP) BYPASS_GROUP="$value" ;;
        NFT_FAMILY) NFT_FAMILY="$value" ;;
        NFT_TABLE) NFT_TABLE="$value" ;;
        INTERFACE|WRAPPER_PATH|NORDVPN_SERVICE) : ;; # Not needed by this script.
        *) die "Unknown setting '$key' in $CONFIG_FILE" ;;
    esac
done < "$CONFIG_FILE"

: "${VPN_USER:?VPN_USER is missing from $CONFIG_FILE}"
: "${BYPASS_GROUP:?BYPASS_GROUP is missing from $CONFIG_FILE}"

[[ "$VPN_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || die "Invalid VPN_USER in $CONFIG_FILE"
[[ "$BYPASS_GROUP" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || die "Invalid BYPASS_GROUP in $CONFIG_FILE"
[[ "$NFT_FAMILY" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid NFT_FAMILY in $CONFIG_FILE"
[[ "$NFT_TABLE" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid NFT_TABLE in $CONFIG_FILE"

if [[ "${1:-}" == "--remove" ]]; then
    (($# == 1)) || die "Usage: $0 [--remove]"
    nft delete table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || true
    log "Removed $NFT_FAMILY $NFT_TABLE (if it existed)."
    exit 0
elif (($# != 0)); then
    die "Usage: $0 [--remove]"
fi

PASSWD_ENTRY="$(getent passwd "$VPN_USER" || true)"
[[ -n "$PASSWD_ENTRY" ]] || die "NordVPN user '$VPN_USER' does not exist."
IFS=: read -r _ _ _ _ _ VPN_HOME _ <<<"$PASSWD_ENTRY"
[[ -d "$VPN_HOME" ]] || die "Home directory for '$VPN_USER' does not exist: $VPN_HOME"

# Wait for the NordVPN CLI to be usable, not for a VPN connection or NordVPN
# nftables/routing tables. NordVPN reports its configured firewall mark while
# disconnected too; app_bypass can therefore be installed before VPN connect.
SETTINGS=""
for ((attempt=1; attempt<=60; attempt++)); do
    if SETTINGS="$(runuser -u "$VPN_USER" -- env \
        HOME="$VPN_HOME" USER="$VPN_USER" LOGNAME="$VPN_USER" \
        nordvpn settings 2>/dev/null)"; then
        break
    fi
    sleep 1
done
[[ -n "$SETTINGS" ]] || die "NordVPN CLI did not become available for '$VPN_USER' after 60 seconds."

grep -qE '^[[:space:]]*Firewall:[[:space:]]+enabled[[:space:]]*$' <<<"$SETTINGS" ||
    die "NordVPN Firewall is not enabled for '$VPN_USER'."
FIREWALL_MARK="$(awk -F': *' '/^[[:space:]]*Firewall Mark:/ {print $2; exit}' <<<"$SETTINGS")"
[[ "$FIREWALL_MARK" =~ ^0[xX][[:xdigit:]]+$ ]] ||
    die "Could not determine a valid NordVPN firewall mark from 'nordvpn settings'."

GROUP_ENTRY="$(getent group "$BYPASS_GROUP" || true)"
[[ -n "$GROUP_ENTRY" ]] || die "Bypass group '$BYPASS_GROUP' does not exist."
IFS=: read -r _ _ BYPASS_GID _ <<<"$GROUP_ENTRY"
[[ "$BYPASS_GID" =~ ^[0-9]+$ ]] || die "Could not determine GID for group '$BYPASS_GROUP'."

# Preserve the existing table and packet counter if the intended rule is
# already present. Recreate only this project's dedicated table if it differs.
CURRENT_CHAIN="$(nft list chain "$NFT_FAMILY" "$NFT_TABLE" output 2>/dev/null || true)"
RULE_HAS_GROUP=0
RULE_HAS_MARK=0
grep -Eq "meta skgid[[:space:]]+$BYPASS_GID([[:space:]]|$)" <<<"$CURRENT_CHAIN" && RULE_HAS_GROUP=1
while IFS= read -r token; do
    [[ "$token" =~ ^0[xX][[:xdigit:]]+$ ]] || continue
    if (( token == FIREWALL_MARK )); then
        RULE_HAS_MARK=1
        break
    fi
done < <(grep -Eo '0[xX][[:xdigit:]]+' <<<"$CURRENT_CHAIN" || true)

if (( RULE_HAS_GROUP && RULE_HAS_MARK )); then
    log "$NFT_FAMILY $NFT_TABLE already has the required rule (GID=$BYPASS_GID, mark=$FIREWALL_MARK); leaving it unchanged."
    exit 0
fi

nft delete table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || true
nft -f - <<NFT_EOF
add table $NFT_FAMILY $NFT_TABLE
add chain $NFT_FAMILY $NFT_TABLE output { type route hook output priority mangle - 1; policy accept; }
add rule $NFT_FAMILY $NFT_TABLE output meta skgid $BYPASS_GID meta mark set $FIREWALL_MARK counter
NFT_EOF

log "Configured $NFT_FAMILY $NFT_TABLE."
log "Group: $BYPASS_GROUP (GID $BYPASS_GID)"
log "NordVPN firewall mark: $FIREWALL_MARK"
