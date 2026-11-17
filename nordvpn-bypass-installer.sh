#!/usr/bin/env bash
# Install per-application NordVPN bypass using nftables and systemd.
# Persistence is enabled by default; use --no-persistence to skip it.
set -Eeuo pipefail

readonly DEFAULT_GROUP="nordvpn-bypass"
readonly NFT_FAMILY="inet"
readonly NFT_TABLE="app_bypass"
readonly CONFIG_FILE="/etc/nordvpn-bypass.conf"
readonly RESTORE_DEST="/usr/local/sbin/nordvpn-bypass-nftables"
readonly SERVICE_FILE="/etc/systemd/system/nordvpn-bypass-nftables.service"
readonly SERVICE_NAME="nordvpn-bypass-nftables.service"

ENABLE_PERSISTENCE=1

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage:
  sudo ./nordvpn-bypass-installer.sh [--no-persistence]

Options:
  --no-persistence   Configure the live bypass rule but do not install or
                     enable the boot-time systemd restoration service.
  -h, --help         Show this help.

Persistence is enabled by default. See the README for details.
USAGE
}

while (($#)); do
    case "$1" in
        --no-persistence) ENABLE_PERSISTENCE=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "Run this installer with sudo or as root."

for cmd in awk cut getent grep install ip mktemp nft nordvpn runuser systemctl usermod groupadd; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

config_get() {
    local key="$1" file="$2"
    [[ -r "$file" ]] || return 0
    awk -F= -v key="$key" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            k=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k == key) {
                sub(/^[^=]*=/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                value=$0
            }
        }
        END { if (value != "") print value }
    ' "$file"
}

mark_present() {
    local expected="$1" rules="$2" token
    while IFS= read -r token; do
        [[ "$token" =~ ^0[xX][[:xdigit:]]+$ ]] || continue
        if (( token == expected )); then return 0; fi
    done < <(grep -Eo '0[xX][[:xdigit:]]+' <<<"$rules" || true)
    return 1
}

INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SOURCE="$INSTALLER_DIR/nordvpn-bypass"
RESTORE_SOURCE="$INSTALLER_DIR/nordvpn-bypass-nftables.sh"

if (( ENABLE_PERSISTENCE )) && [[ ! -f "$RESTORE_SOURCE" ]]; then
    die "Persistence is enabled by default, but companion script is missing: $RESTORE_SOURCE. Put nordvpn-bypass-nftables.sh beside the installer or rerun with --no-persistence."
fi

# Read existing values so rerunning the installer preserves the user's choices.
EXISTING_USER="$(config_get VPN_USER "$CONFIG_FILE")"
EXISTING_INTERFACE="$(config_get INTERFACE "$CONFIG_FILE")"
EXISTING_GROUP="$(config_get BYPASS_GROUP "$CONFIG_FILE")"
EXISTING_WRAPPER_PATH="$(config_get WRAPPER_PATH "$CONFIG_FILE")"
EXISTING_SERVICE="$(config_get NORDVPN_SERVICE "$CONFIG_FILE")"

DEFAULT_USER="${EXISTING_USER:-${SUDO_USER:-}}"
[[ "$DEFAULT_USER" == "root" ]] && DEFAULT_USER=""
if [[ -n "$DEFAULT_USER" ]]; then
    read -r -p "Linux user authorised to use NordVPN [$DEFAULT_USER]: " VPN_USER
    VPN_USER="${VPN_USER:-$DEFAULT_USER}"
else
    while :; do
        read -r -p "Linux user authorised to use NordVPN: " VPN_USER
        [[ -n "$VPN_USER" ]] && break
        echo "Please enter a username."
    done
fi

PASSWD_ENTRY="$(getent passwd "$VPN_USER" || true)"
[[ -n "$PASSWD_ENTRY" ]] || die "User '$VPN_USER' does not exist."
IFS=: read -r VPN_USER _ VPN_UID VPN_PRIMARY_GID _ VPN_HOME _ <<<"$PASSWD_ENTRY"
[[ "$VPN_UID" =~ ^[0-9]+$ && -d "$VPN_HOME" ]] || die "Could not determine a valid home directory and UID for '$VPN_USER'."

# Migrate defaults from the legacy per-user config when the shared system
# config does not yet contain these values. The installer writes only the
# shared /etc config from this point onward.
LEGACY_USER_CONFIG="$VPN_HOME/.config/nordvpn-bypass/config"
if [[ -z "$EXISTING_INTERFACE" ]]; then
    EXISTING_INTERFACE="$(config_get INTERFACE "$LEGACY_USER_CONFIG")"
fi
if [[ -z "$EXISTING_GROUP" ]]; then
    EXISTING_GROUP="$(config_get BYPASS_GROUP "$LEGACY_USER_CONFIG")"
fi

if [[ -n "$EXISTING_WRAPPER_PATH" ]]; then
    DEFAULT_WRAPPER_DIR="$(dirname -- "$EXISTING_WRAPPER_PATH")"
else
    DEFAULT_WRAPPER_DIR="$VPN_HOME/.local/bin"
fi
echo
read -r -p "Wrapper installation directory [$DEFAULT_WRAPPER_DIR]: " WRAPPER_DIR
WRAPPER_DIR="${WRAPPER_DIR:-$DEFAULT_WRAPPER_DIR}"
case "$WRAPPER_DIR" in
    "~") WRAPPER_DIR="$VPN_HOME" ;;
    "~/"*) WRAPPER_DIR="$VPN_HOME/${WRAPPER_DIR#\~/}" ;;
esac
[[ "$WRAPPER_DIR" == /* ]] || die "Please provide an absolute wrapper installation directory."
[[ "$WRAPPER_DIR" =~ ^/[a-zA-Z0-9_./+-]+$ ]] ||
    die "Wrapper installation directory may contain only letters, digits, '_', '.', '/', '+', and '-'."
WRAPPER_PATH="${WRAPPER_DIR%/}/nordvpn-bypass"

# If the existing config stores a wrapper path, preserve it as the prompt default.
# A user may still choose a new directory interactively.

echo
echo "Available network interfaces:"
ip -br link | awk '$1 != "lo" { print "  " $1 "  " $2 }'
DEFAULT_INTERFACE="$EXISTING_INTERFACE"
while :; do
    if [[ -n "$DEFAULT_INTERFACE" ]]; then
        read -r -p "Interface for bypass traffic [$DEFAULT_INTERFACE]: " INTERFACE
        INTERFACE="${INTERFACE:-$DEFAULT_INTERFACE}"
    else
        read -r -p "Interface for bypass traffic: " INTERFACE
    fi
    [[ -n "$INTERFACE" ]] || { echo "An interface name is required."; continue; }
    if ip link show dev "$INTERFACE" >/dev/null 2>&1; then break; fi
    echo "Interface '$INTERFACE' does not exist. Try again."
done

GROUP_DEFAULT="${EXISTING_GROUP:-$DEFAULT_GROUP}"
echo
read -r -p "Bypass group name [$GROUP_DEFAULT]: " BYPASS_GROUP
BYPASS_GROUP="${BYPASS_GROUP:-$GROUP_DEFAULT}"
[[ "$BYPASS_GROUP" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || die "Invalid group name. Use letters, digits, '_' or '-'."

NORDVPN_SERVICE="${EXISTING_SERVICE:-nordvpnd.service}"
if (( ENABLE_PERSISTENCE )); then
    echo
    read -r -p "NordVPN systemd service [$NORDVPN_SERVICE]: " SERVICE_INPUT
    NORDVPN_SERVICE="${SERVICE_INPUT:-$NORDVPN_SERVICE}"
    [[ "$NORDVPN_SERVICE" =~ ^[a-zA-Z0-9_.@:-]+$ ]] || die "Invalid systemd unit name: $NORDVPN_SERVICE"
    systemctl cat "$NORDVPN_SERVICE" >/dev/null 2>&1 || die "systemd unit '$NORDVPN_SERVICE' was not found."
fi

# Validate NordVPN settings while disconnected or connected. An active VPN
# tunnel and NordVPN's own nftables table are deliberately NOT prerequisites.
echo
echo "Checking NordVPN settings for '$VPN_USER'..."
SETTINGS="$(runuser -u "$VPN_USER" -- env HOME="$VPN_HOME" USER="$VPN_USER" LOGNAME="$VPN_USER" nordvpn settings 2>&1)" ||
    die "Could not run 'nordvpn settings' as '$VPN_USER': $SETTINGS"
grep -qE '^[[:space:]]*Firewall:[[:space:]]+enabled[[:space:]]*$' <<<"$SETTINGS" ||
    die "NordVPN Firewall is not enabled for '$VPN_USER'."
FIREWALL_MARK="$(awk -F': *' '/^[[:space:]]*Firewall Mark:/ {print $2; exit}' <<<"$SETTINGS")"
[[ "$FIREWALL_MARK" =~ ^0[xX][[:xdigit:]]+$ ]] || die "Could not determine a valid NordVPN firewall mark."

# If persistence is being disabled on an existing installation, remove the old
# service first. Its ExecStop removes only this project's app_bypass table.
if (( ! ENABLE_PERSISTENCE )); then
    if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl disable --now "$SERVICE_NAME" || true
    fi
    rm -f "$SERVICE_FILE" "$RESTORE_DEST"
    systemctl daemon-reload
fi

if ! getent group "$BYPASS_GROUP" >/dev/null; then
    groupadd "$BYPASS_GROUP"
    echo "Created group '$BYPASS_GROUP'."
else
    echo "Using existing group '$BYPASS_GROUP'."
fi
usermod -aG "$BYPASS_GROUP" "$VPN_USER"
BYPASS_GID="$(getent group "$BYPASS_GROUP" | cut -d: -f3)"
[[ "$BYPASS_GID" =~ ^[0-9]+$ ]] || die "Could not determine GID for '$BYPASS_GROUP'."

# One authoritative, root-owned configuration file is shared by all components.
CONFIG_TMP="$(mktemp /etc/nordvpn-bypass.conf.XXXXXX)"
cat >"$CONFIG_TMP" <<EOF_CONFIG
# NordVPN application bypass configuration; managed by the installer.
VPN_USER=$VPN_USER
INTERFACE=$INTERFACE
BYPASS_GROUP=$BYPASS_GROUP
NFT_FAMILY=$NFT_FAMILY
NFT_TABLE=$NFT_TABLE
WRAPPER_PATH=$WRAPPER_PATH
NORDVPN_SERVICE=$NORDVPN_SERVICE
EOF_CONFIG
chown root:root "$CONFIG_TMP"
chmod 644 "$CONFIG_TMP"
mv -f "$CONFIG_TMP" "$CONFIG_FILE"

# Install wrapper supplied alongside the installer, if present.
if [[ -f "$WRAPPER_SOURCE" ]]; then
    if [[ "$WRAPPER_DIR" == "$VPN_HOME"/* || "$WRAPPER_DIR" == "$VPN_HOME" ]]; then
        install -d -o "$VPN_UID" -g "$VPN_PRIMARY_GID" -m 755 "$WRAPPER_DIR"
    else
        install -d -m 755 "$WRAPPER_DIR"
    fi
    install -o "$VPN_UID" -g "$VPN_PRIMARY_GID" -m 755 "$WRAPPER_SOURCE" "$WRAPPER_PATH"
    echo "Installed wrapper: $WRAPPER_PATH"
else
    cat <<EOF_WRAPPER_MISSING

The wrapper was not found beside this installer:
  $WRAPPER_SOURCE

The group, shared configuration and firewall setup will continue, but the
application launcher has not been installed. Download the separate
'nordvpn-bypass' wrapper and install it manually:
  install -D -m 755 /path/to/nordvpn-bypass '$WRAPPER_PATH'
EOF_WRAPPER_MISSING
fi

# Apply the custom table independently of VPN connection state. The NordVPN
# CLI provides the configured mark even when the VPN is disconnected.
nft delete table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || true
nft -f - <<NFT_EOF
add table $NFT_FAMILY $NFT_TABLE
add chain $NFT_FAMILY $NFT_TABLE output { type route hook output priority mangle - 1; policy accept; }
add rule $NFT_FAMILY $NFT_TABLE output meta skgid $BYPASS_GID meta mark set $FIREWALL_MARK counter
NFT_EOF
LIVE_CHAIN="$(nft list chain "$NFT_FAMILY" "$NFT_TABLE" output)"
grep -Eq "meta skgid[[:space:]]+$BYPASS_GID([[:space:]]|$)" <<<"$LIVE_CHAIN" || die "Installed rule does not contain GID $BYPASS_GID."
mark_present "$FIREWALL_MARK" "$LIVE_CHAIN" || die "Installed rule does not contain firewall mark $FIREWALL_MARK."

if (( ENABLE_PERSISTENCE )); then
    echo
    echo "Installing systemd persistence..."
    install -o root -g root -m 755 "$RESTORE_SOURCE" "$RESTORE_DEST"
    cat >"$SERVICE_FILE" <<EOF_UNIT
[Unit]
Description=NordVPN per-application split-tunnelling firewall rules
Requires=$NORDVPN_SERVICE
After=$NORDVPN_SERVICE
PartOf=$NORDVPN_SERVICE

[Service]
Type=oneshot
ExecStart=$RESTORE_DEST
ExecStop=-$RESTORE_DEST --remove
RemainAfterExit=yes
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chown root:root "$SERVICE_FILE"
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" ||
        die "Persistence service did not become active. Inspect: journalctl -u $SERVICE_NAME -b"
else
    echo
    echo "Persistence was explicitly skipped. The rule is active for this boot only."
    echo 'For manual boot-time persistence instructions, see the README section "Optional systemd Persistence".'
fi

echo
echo "Installation completed successfully."
echo "  NordVPN user:   $VPN_USER"
echo "  Interface:      $INTERFACE"
echo "  Bypass group:   $BYPASS_GROUP (GID $BYPASS_GID)"
echo "  Firewall mark:  $FIREWALL_MARK"
echo "  nftables table: $NFT_FAMILY $NFT_TABLE"
echo "  System config:  $CONFIG_FILE"
echo "  Wrapper:        $WRAPPER_PATH"
if (( ENABLE_PERSISTENCE )); then
    echo "  Persistence:    enabled ($SERVICE_NAME)"
fi
echo
if ! id -nG "$VPN_USER" | tr ' ' '\n' | grep -Fxq "$BYPASS_GROUP"; then
    echo "Log out and back in for '$VPN_USER' to receive the new group membership."
else
    echo "If '$VPN_USER' was already logged in during installation, log out and back in to refresh the desktop session's group list."
fi
