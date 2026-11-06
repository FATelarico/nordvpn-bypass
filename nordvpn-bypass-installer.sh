#!/usr/bin/env bash
# NordVPN per-application split-tunnelling setup for Debian.
#
# Default: configure the bypass group, live nftables rule, wrapper, and
# boot-time systemd persistence.
#
# To skip persistence:
#   sudo ./install-nordvpn-bypass.sh --no-persistence
#
set -Eeuo pipefail

readonly DEFAULT_GROUP="nordvpn-bypass"
readonly NFT_FAMILY="inet"
readonly NFT_TABLE="app_bypass"
readonly RESTORE_SCRIPT="/usr/local/sbin/nordvpn-bypass-nftables"
readonly PERSISTENCE_CONFIG="/etc/nordvpn-bypass.conf"
readonly SERVICE_FILE="/etc/systemd/system/nordvpn-bypass-nftables.service"

ENABLE_PERSISTENCE=1

usage() {
    cat <<'EOF'
Usage:
  sudo ./install-nordvpn-bypass.sh [--no-persistence]

Options:
  --no-persistence     Do not install or enable the systemd boot-time
                       restoration service. The nftables rule will apply
                       only until reboot or a NordVPN firewall reset.
  -h, --help           Show this help.

By default, the installer configures boot-time persistence.
For manual persistence instructions, see the README section
"Optional systemd Persistence".
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# Compare nftables hexadecimal marks numerically. nft may print a 32-bit
# mark zero-padded (e.g. 0x0000e1f1), while `nordvpn settings` prints 0xe1f1.
mark_present() {
    local expected="$1"
    local rules="$2"
    local token

    while IFS= read -r token; do
        [[ "$token" =~ ^0[xX][[:xdigit:]]+$ ]] || continue
        if (( token == expected )); then
            return 0
        fi
    done < <(grep -Eo '0[xX][[:xdigit:]]+' <<<"$rules" || true)

    return 1
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

for cmd in getent ip nft nordvpn runuser usermod groupadd awk grep sed systemctl install; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# Select the Linux account whose NordVPN CLI configuration is used.
DEFAULT_USER="${SUDO_USER:-}"
[[ "$DEFAULT_USER" == "root" ]] && DEFAULT_USER=""

if [[ -n "$DEFAULT_USER" ]]; then
    read -r -p "Linux user for NordVPN [$DEFAULT_USER]: " VPN_USER
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
[[ "$VPN_UID" =~ ^[0-9]+$ && -d "$VPN_HOME" ]] ||
    die "Could not determine a valid home directory and UID for '$VPN_USER'."

# Ask where to install the wrapper. The default is the selected user's
# ~/.local/bin, a conventional per-user executable directory on systemd distros.
DEFAULT_WRAPPER_DIR="$VPN_HOME/.local/bin"
echo
read -r -p "Wrapper installation directory [$DEFAULT_WRAPPER_DIR]: " WRAPPER_DEST
WRAPPER_DEST="${WRAPPER_DEST:-$DEFAULT_WRAPPER_DIR}"

case "$WRAPPER_DEST" in
    "~") WRAPPER_DEST="$VPN_HOME" ;;
    "~/"*) WRAPPER_DEST="$VPN_HOME/${WRAPPER_DEST#~/}" ;;
esac

[[ "$WRAPPER_DEST" == /* ]] ||
    die "Please provide an absolute wrapper installation directory."

# The prompt asks for a directory. Also accept a full executable path for
# convenience, e.g. /usr/local/bin/nordvpn-bypass.
if [[ "$WRAPPER_DEST" == */nordvpn-bypass ]]; then
    :
else
    WRAPPER_DEST="${WRAPPER_DEST%/}/nordvpn-bypass"
fi

# The wrapper is expected in the same directory as this installer.
INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SOURCE="$INSTALLER_DIR/nordvpn-bypass"
RESTORE_SOURCE="$INSTALLER_DIR/nordvpn-bypass-nftables.sh"

if (( ENABLE_PERSISTENCE )) && [[ ! -f "$RESTORE_SOURCE" ]]; then
    die "Persistence is enabled by default, but the companion restoration script was not found: $RESTORE_SOURCE. Place nordvpn-bypass-nftables.sh beside this installer, or rerun with --no-persistence."
fi

echo
echo "Available network interfaces:"
ip -br link | awk '$1 != "lo" { print "  " $1 "  " $2 }'

while :; do
    read -r -p "Interface for bypass traffic: " INTERFACE
    [[ -n "$INTERFACE" ]] || { echo "An interface name is required."; continue; }
    if ip link show dev "$INTERFACE" >/dev/null 2>&1; then
        break
    fi
    echo "Interface '$INTERFACE' does not exist. Try again."
done

echo
read -r -p "Bypass group name [$DEFAULT_GROUP]: " BYPASS_GROUP
BYPASS_GROUP="${BYPASS_GROUP:-$DEFAULT_GROUP}"
[[ "$BYPASS_GROUP" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] ||
    die "Invalid group name. Use letters, digits, '_' or '-'."

echo
echo "Checking NordVPN settings for '$VPN_USER'..."
SETTINGS="$(
    runuser -u "$VPN_USER" -- env \
        HOME="$VPN_HOME" USER="$VPN_USER" LOGNAME="$VPN_USER" \
        nordvpn settings 2>&1
)" || die "Could not run 'nordvpn settings' as '$VPN_USER': $SETTINGS"

grep -qE '^[[:space:]]*Firewall:[[:space:]]+enabled[[:space:]]*$' <<<"$SETTINGS" ||
    die "NordVPN Firewall is not enabled. Enable it before installing the bypass."

FIREWALL_MARK="$(
    awk -F': *' '/^[[:space:]]*Firewall Mark:/ { print $2; exit }' <<<"$SETTINGS"
)"
[[ "$FIREWALL_MARK" =~ ^0x[[:xdigit:]]+$ ]] ||
    die "Could not determine a valid NordVPN firewall mark."

nft list table inet nordvpn >/dev/null 2>&1 ||
    die "NordVPN nftables table 'inet nordvpn' was not found. Is its firewall initialised?"

NORDVPN_OUTPUT="$(nft list chain inet nordvpn output 2>/dev/null)" ||
    die "Could not inspect NordVPN's output chain."
mark_present "$FIREWALL_MARK" "$NORDVPN_OUTPUT" ||
    die "NordVPN's output chain does not contain the reported mark $FIREWALL_MARK (numeric comparison)."

# Create/reuse the group and add the selected user.
if ! getent group "$BYPASS_GROUP" >/dev/null; then
    groupadd "$BYPASS_GROUP"
    echo "Created group '$BYPASS_GROUP'."
else
    echo "Using existing group '$BYPASS_GROUP'."
fi
usermod -aG "$BYPASS_GROUP" "$VPN_USER"

BYPASS_GID="$(getent group "$BYPASS_GROUP" | cut -d: -f3)"
[[ "$BYPASS_GID" =~ ^[0-9]+$ ]] || die "Could not determine GID for '$BYPASS_GROUP'."

# Write/update the wrapper configuration while preserving unrelated settings.
USER_CONFIG_DIR="$VPN_HOME/.config/nordvpn-bypass"
USER_CONFIG_FILE="$USER_CONFIG_DIR/config"
install -d -m 700 -o "$VPN_UID" -g "$VPN_PRIMARY_GID" "$USER_CONFIG_DIR"

TMP_CONFIG="$(mktemp "$USER_CONFIG_DIR/config.XXXXXX")"
if [[ -f "$USER_CONFIG_FILE" ]]; then
    awk -v iface="$INTERFACE" -v group="$BYPASS_GROUP" '
        BEGIN { seen_iface=0; seen_group=0 }
        /^[[:space:]]*INTERFACE[[:space:]]*=/ {
            if (!seen_iface++) print "INTERFACE=" iface
            next
        }
        /^[[:space:]]*BYPASS_GROUP[[:space:]]*=/ {
            if (!seen_group++) print "BYPASS_GROUP=" group
            next
        }
        { print }
        END {
            if (!seen_iface) print "INTERFACE=" iface
            if (!seen_group) print "BYPASS_GROUP=" group
        }
    ' "$USER_CONFIG_FILE" >"$TMP_CONFIG"
else
    {
        echo "# NordVPN bypass configuration"
        printf 'INTERFACE=%s\n' "$INTERFACE"
        printf 'BYPASS_GROUP=%s\n' "$BYPASS_GROUP"
    } >"$TMP_CONFIG"
fi
chmod 600 "$TMP_CONFIG"
chown "$VPN_UID:$VPN_PRIMARY_GID" "$TMP_CONFIG"
mv -f "$TMP_CONFIG" "$USER_CONFIG_FILE"

# Install the wrapper supplied alongside this installer, if present.
if [[ -f "$WRAPPER_SOURCE" ]]; then
    WRAPPER_DIR="$(dirname -- "$WRAPPER_DEST")"
    install -d -m 755 -o "$VPN_UID" -g "$VPN_PRIMARY_GID" "$WRAPPER_DIR"
    install -m 755 -o "$VPN_UID" -g "$VPN_PRIMARY_GID" \
        "$WRAPPER_SOURCE" "$WRAPPER_DEST"
    echo "Installed wrapper: $WRAPPER_DEST"
else
    cat <<EOF

The wrapper was not found beside this installer:
  $WRAPPER_SOURCE

The group, configuration and firewall setup will continue, but the
application launcher has not been installed.

Download the separate 'nordvpn-bypass' wrapper and install it manually:
  install -D -m 755 /path/to/nordvpn-bypass "$WRAPPER_DEST"

The wrapper configuration has already been created at:
  $USER_CONFIG_FILE
EOF
fi

# Apply only our own table; do not alter NordVPN's nftables table.
nft delete table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || true
nft -f - <<EOF
add table $NFT_FAMILY $NFT_TABLE
add chain $NFT_FAMILY $NFT_TABLE output { type route hook output priority mangle - 1; policy accept; }
add rule $NFT_FAMILY $NFT_TABLE output meta skgid $BYPASS_GID meta mark set $FIREWALL_MARK counter
EOF

LIVE_RULE="$(nft list chain "$NFT_FAMILY" "$NFT_TABLE" output 2>/dev/null)" ||
    die "The custom nftables chain was not created."
grep -q "meta skgid $BYPASS_GID" <<<"$LIVE_RULE" ||
    die "The installed rule does not contain the expected group GID."
mark_present "$FIREWALL_MARK" "$LIVE_RULE" ||
    die "The installed rule does not contain the expected firewall mark."

echo
echo "Initial configuration completed successfully."
echo "  NordVPN user:   $VPN_USER"
echo "  Interface:      $INTERFACE"
echo "  Bypass group:   $BYPASS_GROUP"
echo "  Group GID:      $BYPASS_GID"
echo "  Firewall mark:  $FIREWALL_MARK"
echo "  nftables table: $NFT_FAMILY $NFT_TABLE"
echo "  User config:    $USER_CONFIG_FILE"
if [[ -f "$WRAPPER_SOURCE" ]]; then
    echo "  Wrapper:        $WRAPPER_DEST"
else
    echo "  Wrapper:        NOT INSTALLED (manual installation required)"
fi

if (( ENABLE_PERSISTENCE )); then
    echo
    echo "Installing optional systemd persistence..."

    # The account is discovered interactively during installation and stored
    # in a root-owned config file for the boot-time restoration script.
    {
        printf 'VPN_USER=%q\n' "$VPN_USER"
        printf 'BYPASS_GROUP=%q\n' "$BYPASS_GROUP"
        printf 'NFT_FAMILY=%q\n' "$NFT_FAMILY"
        printf 'NFT_TABLE=%q\n' "$NFT_TABLE"
    } >"$PERSISTENCE_CONFIG"
    chown root:root "$PERSISTENCE_CONFIG"
    chmod 600 "$PERSISTENCE_CONFIG"

    # Install the companion restoration script supplied beside this installer.
    # Keep the source script as the single source of truth.
    install -o root -g root -m 755 "$RESTORE_SOURCE" "$RESTORE_SCRIPT"

    NFT_BIN="$(command -v nft)"
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=NordVPN per-application split-tunnelling firewall rules
Requires=nordvpnd.service
After=nordvpnd.service
PartOf=nordvpnd.service

[Service]
Type=oneshot
ExecStart=$RESTORE_SCRIPT
ExecStop=-$NFT_BIN delete table $NFT_FAMILY $NFT_TABLE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chown root:root "$SERVICE_FILE"
    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable --now nordvpn-bypass-nftables.service
    systemctl is-active --quiet nordvpn-bypass-nftables.service ||
        die "Persistence service failed. Inspect journalctl -u nordvpn-bypass-nftables.service -b."

    echo "Persistence enabled: nordvpn-bypass-nftables.service"
else
    cat <<'EOF'

Persistence was explicitly skipped.
The firewall rule is active for the current boot only.

For manual boot-time persistence instructions, see the README
section: "Optional systemd Persistence".
EOF
fi

echo
echo "If '$VPN_USER' was newly added to '$BYPASS_GROUP', log out and back in"
echo "before using the launcher, so the new group membership is available."
