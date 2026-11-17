# Per-application split tunnelling with NordVPN on Linux

<img height="700" src="https://github.com/user-attachments/assets/55834de8-584e-4d49-b46d-29d28b09fdf8" />

This project provides an unofficial Linux workaround for launching selected applications outside the NordVPN tunnel while other applications continue to use NordVPN. It combines Linux groups, `nftables` packet marks, policy routing, and systemd's `BindNetworkInterface` property.

**Tested configuration:** Debian 14, systemd 262, NordVPN 6.0.1, NordLynx. Other combinations may work but have not been verified by this project.

> [!WARNING]
> Applications launched through `nordvpn-bypass` use the configured physical interface directly, not the NordVPN tunnel. Their traffic therefore does not receive the protection of the VPN tunnel. This project does not provide a VPN kill switch for bypassed applications. Do not use the bypass for traffic that must remain inside the VPN.
>
> This is an unofficial workaround. It is not affiliated with, endorsed by, or supported by NordVPN.

## Contents

- [Requirements](#requirements)
- [1. Installation](#1-installation)
- [2. Configuration and usage](#2-configuration-and-usage)
- [3. Shared configuration](#3-shared-configuration)
- [4. How the firewall rule works](#4-how-the-firewall-rule-works)
- [5. Persistence](#5-persistence)
- [6. Testing](#6-testing)
- [7. Troubleshooting](#7-troubleshooting)
- [8. Updating settings](#8-updating-settings)
- [9. Uninstallation](#9-uninstallation)
- [10. Limitations and safety notes](#10-limitations-and-safety-notes)

## Requirements

- A Linux distribution using systemd 260 or later (the tested setup uses systemd 262).
- NordVPN's Linux client installed and configured.
- NordVPN Firewall enabled and a firewall mark shown by `nordvpn settings`.
- `nftables`, `iproute2`, `runuser`, `sg`, and `sudo` available.
- A physical network interface with a usable address and route.
- The user running the wrapper must be authorised to use NordVPN.

The tested configuration uses NordLynx. The approach depends on NordVPN's local firewall mark and policy-routing behaviour; other NordVPN protocols and client versions have not been verified.

## 1. Installation

Keep these three scripts in the same directory:

```text
nordvpn-bypass/
├── nordvpn-bypass-installer.sh
├── nordvpn-bypass
└── nordvpn-bypass-nftables.sh
```

Make the installer executable and run it as root:

```bash
chmod +x nordvpn-bypass-installer.sh
sudo ./nordvpn-bypass-installer.sh
```

Persistence is enabled by default. To configure the live group and firewall rule without installing the systemd persistence service, use:

```bash
sudo ./nordvpn-bypass-installer.sh --no-persistence
```

The installer interactively asks for:

1. **NordVPN user:** the Linux account whose NordVPN settings are queried. When invoked with `sudo`, the invoking user is suggested by default.
2. **Wrapper installation directory:** defaults to the selected user's `~/.local/bin`. The installer copies the companion `nordvpn-bypass` wrapper there. A different absolute directory can be entered. Check that the chosen directory is on the user's `PATH` (`command -v nordvpn-bypass`); add `~/.local/bin` to `PATH` in the shell startup file if the distribution or shell has not already done so.
3. **Network interface:** select the physical interface used for bypass traffic, for example `wlp5s0`. Do not select `lo` or the NordLynx interface.
4. **Bypass group:** defaults to `nordvpn-bypass`. The installer creates it if necessary and adds the selected user to it.
5. **NordVPN systemd service:** asked when persistence is enabled; defaults to `nordvpnd.service`.

The installer reads the firewall mark from `nordvpn settings`. It does not require NordVPN to be connected, and it does not require NordVPN's own `inet nordvpn` nftables table or routing table 205 to exist. The configured mark is available while NordVPN is disconnected on the tested client.

The installer expects `nordvpn-bypass` and, when persistence is enabled, `nordvpn-bypass-nftables.sh` to be in the same directory as the installer. If the wrapper is missing, the installer continues with the group and firewall setup and prints instructions to download and install the wrapper manually. If persistence is enabled and the restoration script is missing, the installer stops before making changes.

After installation, log out and back in if the user was newly added to the bypass group. This refreshes the supplementary group list inherited by the desktop session.

## 2. Configuration and usage

Run the wrapper as the normal desktop user, without `sudo`:

```bash
nordvpn-bypass freetube
nordvpn-bypass firefox
nordvpn-bypass chromium
```

The wrapper launches the application in a system-level systemd scope, binds its sockets to the configured interface, then switches to the configured bypass group. The execution order is deliberate and reflects the working test on the reference system:

```bash
U="$(id -un)"
H="$(getent passwd "$U" | cut -d: -f6)"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

sudo systemd-run --system --scope \
  -p BindNetworkInterface=wlp5s0 \
  -- runuser -u "$U" -- \
  env HOME="$H" USER="$U" LOGNAME="$U" \
      XDG_RUNTIME_DIR="$RUNTIME" \
  sg nordvpn-bypass -c 'exec freetube'
```

Do not replace `--system` with `--user`, or change the order of `runuser`, `env`, and `sg` without re-testing. In the tested configuration, the system systemd manager is required for `BindNetworkInterface=` to work.

The wrapper supports:

```bash
nordvpn-bypass settings
nordvpn-bypass set interface wlp5s0
nordvpn-bypass set group nordvpn-bypass
```

- `settings` displays the shared configuration and the currently discovered group GID and NordVPN firewall mark.
- `set interface NAME` validates the interface and updates the shared system configuration. It affects subsequent launches; it does not need to rebuild the nftables rule.
- `set group NAME` requires the group to exist, adds the configured user to it, updates the shared configuration, and refreshes the live nftables rule using the new GID and current NordVPN mark. Log out and back in to refresh the desktop session's group list.

Applications launched normally, without the wrapper, continue to use the normal NordVPN routing policy.

## 3. Shared configuration

All components use one authoritative configuration file:

```text
/etc/nordvpn-bypass.conf
```

Example:

```ini
VPN_USER=ashtar
INTERFACE=wlp5s0
BYPASS_GROUP=nordvpn-bypass
NFT_FAMILY=inet
NFT_TABLE=app_bypass
WRAPPER_PATH=/home/ashtar/.local/bin/nordvpn-bypass
NORDVPN_SERVICE=nordvpnd.service
```

The installer creates this file as `root:root`, mode `0644`. It contains configuration, not credentials. The wrapper, installer and restoration script all read this file; there is no separate per-user configuration file. This avoids having the interface or group name duplicated in multiple locations. When upgrading from an earlier release, the installer uses the old `~/.config/nordvpn-bypass/config` values as defaults if the shared configuration does not yet contain them. The old per-user file is not used after migration.

The following values are discovered dynamically and are **not** stored as fixed assumptions:

- The numeric GID for `BYPASS_GROUP`, using `getent group`.
- The NordVPN firewall mark, using `nordvpn settings` as `VPN_USER`.

The group name should normally be kept consistent across installations (the default is `nordvpn-bypass`), but its numeric GID can differ between machines. The firewall mark can also differ between installations or change after a client update. The scripts retrieve both values locally.

You may edit `/etc/nordvpn-bypass.conf` by hand. Keep it as plain `KEY=value` lines without shell expressions or quotes. After manually changing `BYPASS_GROUP`, restart the persistence service or run the restoration script so the live rule is rebuilt. The wrapper's `set` commands update this shared file for you.

## 4. How the firewall rule works

The project creates its own nftables table and does not modify NordVPN's table:

```text
inet app_bypass
```

The output chain is a route chain at priority `mangle - 1`. It marks packets from sockets whose socket group ID matches the configured bypass group's current numeric GID. The mark is set to the value reported by `nordvpn settings`.

The effective rule resembles:

```nft
meta skgid 1001 meta mark set 0x0000e1f1 counter
```

The values above are examples. nftables may display a zero-padded hexadecimal mark even though NordVPN reports the same mark without padding (for example, `0xe1f1`). These are numerically identical.

NordVPN's own policy-routing rules exclude packets carrying its firewall mark from the VPN route. `BindNetworkInterface=` then binds the bypassed application's sockets to the selected physical interface. Both parts matter: packet marking alone does not reliably select the correct source address.

The custom table can be created while NordVPN is disconnected. On the tested client, `nordvpn settings` reports the configured firewall mark while disconnected, even though NordVPN's own nftables table and routing table 205 are absent. The restoration script therefore does not wait for an active VPN tunnel or for `inet nordvpn` to exist.

## 5. Persistence

The installer enables persistence by default. It copies the companion restoration script to:

```text
/usr/local/sbin/nordvpn-bypass-nftables
```

and creates:

```text
/etc/systemd/system/nordvpn-bypass-nftables.service
```

The service is ordered after the configured NordVPN daemon service. It does **not** require NordVPN to have an active VPN connection. The restoration script waits for the NordVPN CLI to become available, reads the configured firewall mark, discovers the current bypass-group GID, and creates or verifies only the project's `app_bypass` table.

The service is also associated with the NordVPN daemon using `PartOf=`. A systemd restart of the NordVPN daemon stops and restarts the bypass service; its `ExecStop` removes only the custom table, and its subsequent start recreates it. A normal VPN connect/disconnect operation does not necessarily restart the daemon, and the custom table can remain in place throughout.

The restoration script is idempotent: if the expected group/mark rule already exists, it leaves the table untouched and preserves its packet counter. It recreates the table only when it is absent or the rule no longer matches the current configuration.

Inspect the service:

```bash
systemctl status nordvpn-bypass-nftables.service
sudo journalctl -u nordvpn-bypass-nftables.service -b --no-pager
```

Inspect the custom rule:

```bash
sudo nft list table inet app_bypass
```

To skip persistence during installation, use `--no-persistence`. In that mode the live rule is created, but it will not be restored after reboot or a NordVPN daemon restart. The installer removes a previously installed copy of this project's persistence service and restoration script when `--no-persistence` is selected.

### Optional systemd Persistence (manual installation)

If you performed the manual setup or want to configure persistence separately, place `nordvpn-bypass-nftables.sh` at `/usr/local/sbin/nordvpn-bypass-nftables` as `root:root`, mode `0755`:

```bash
sudo install -o root -g root -m 755 \
  nordvpn-bypass-nftables.sh \
  /usr/local/sbin/nordvpn-bypass-nftables
```

Create `/etc/systemd/system/nordvpn-bypass-nftables.service`:

```ini
[Unit]
Description=NordVPN per-application split-tunnelling firewall rules
Requires=nordvpnd.service
After=nordvpnd.service
PartOf=nordvpnd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nordvpn-bypass-nftables
ExecStop=-/usr/local/sbin/nordvpn-bypass-nftables --remove
RemainAfterExit=yes
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
```

If your NordVPN daemon unit has a different name, replace `nordvpnd.service` with the correct unit name. The service assumes the shared configuration exists at `/etc/nordvpn-bypass.conf`.

Enable and start it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable nordvpn-bypass-nftables.service
sudo systemctl restart nordvpn-bypass-nftables.service
```

A successful oneshot service with `RemainAfterExit=yes` reports `active (exited)`.

## 6. Testing

With NordVPN connected, compare the direct and VPN public IPv4 addresses:

```bash
nordvpn-bypass curl -4 https://icanhazip.com  # Direct physical connection
curl -4 https://icanhazip.com                 # Normal NordVPN connection
```

The addresses should normally differ. The first should be the public address of the physical connection; the second should be the VPN exit address.

Also test the actual application, not only `curl`:

```bash
nordvpn-bypass freetube
```

Close any existing instance before testing, because Electron applications may reuse an already-running process that was launched outside the bypass scope.

Check the nftables packet counter before and after a test:

```bash
sudo nft list chain inet app_bypass output
```

The counter is cumulative. It should increase when sockets belonging to the bypass group generate traffic.

To inspect the expected source address on the physical interface, use a packet capture while making a test connection:

```bash
sudo tcpdump -ni wlp5s0 'tcp port 443'
```

Replace `wlp5s0` with the configured interface. The source address should be the physical interface's local address (for example, `192.168.1.x`), not the NordLynx address (for example, `10.x.x.x`).

The public-IP test checks IPv4 only. DNS and IPv6 behaviour should be tested separately if they are relevant to your setup.

## 7. Troubleshooting

| Symptom | Checks |
|---|---|
| `nordvpn-bypass` cannot be found | Run `command -v nordvpn-bypass`. Check the directory selected during installation and whether it is on your `PATH`. |
| Wrapper reports missing `/etc/nordvpn-bypass.conf` | Run the installer again, or restore the shared configuration file. |
| Bypassed app cannot connect but bypassed `curl` works | Close all existing app processes and relaunch through the wrapper. Check whether the application reuses an existing Electron/browser process. Capture traffic on the selected physical interface. |
| No `inet nordvpn` table while NordVPN is disconnected | This is expected on the tested client. The custom `inet app_bypass` table does not require NordVPN's table to exist. |
| Persistence service remains activating or fails | Run `sudo journalctl -u nordvpn-bypass-nftables.service -b --no-pager`. Check that `nordvpn settings` works as the configured `VPN_USER` while disconnected and that Firewall is enabled. |
| `mark_present` or firewall-mark mismatch | Ensure the installed restoration script is the companion `nordvpn-bypass-nftables.sh` from the same release as the installer. Current scripts compare hexadecimal marks numerically, so zero-padding is not significant. |
| Bypass and ordinary public IPs are identical | Confirm NordVPN is connected for the ordinary test. Check the current mark with `nordvpn settings`, the `app_bypass` counter, and the physical-interface packet capture. |
| Group change does not take effect in desktop apps | Check `getent group GROUPNAME` and `id -nG`. Log out and back in after changing group membership. |

Useful diagnostics:

```bash
nordvpn status
nordvpn settings
ip rule
ip route show table 205
sudo nft list tables
sudo nft list table inet app_bypass
systemctl status nordvpn-bypass-nftables.service
```

When NordVPN is disconnected, its own policy-routing table and nftables table may be absent. That alone is not a failure of this project's custom table.

## 8. Updating settings

### Change the interface

Use:

```bash
nordvpn-bypass set interface wlp5s0
```

The wrapper validates that the interface exists and updates `INTERFACE` in `/etc/nordvpn-bypass.conf`. Subsequent launches use the new interface.

### Change the bypass group

The group must already exist:

```bash
sudo groupadd my-bypass-group
nordvpn-bypass set group my-bypass-group
```

The wrapper adds the configured user to the new group, updates `BYPASS_GROUP` in the shared configuration, discovers the group's current GID, retrieves the current NordVPN firewall mark, and refreshes the live nftables rule. Log out and back in to refresh the desktop session's group list.

The old group is not automatically deleted or removed from the user's memberships.

### NordVPN mark or GID changes

The scripts discover the mark and GID whenever the installer or restoration script runs. If a NordVPN update changes its mark, restart the persistence service to refresh the custom rule:

```bash
sudo systemctl restart nordvpn-bypass-nftables.service
```

If the group GID changes, the restoration script discovers the new value from `getent group` the next time it runs. Restart the persistence service after manually changing group membership or its GID. The group name is the stable configuration identifier; the numeric GID is local to each machine.

## 9. Uninstallation

If persistence is installed, disable and stop the service first. Its `ExecStop` removes only the custom `app_bypass` table:

```bash
sudo systemctl disable --now nordvpn-bypass-nftables.service
sudo rm -f /etc/systemd/system/nordvpn-bypass-nftables.service
sudo systemctl daemon-reload
sudo systemctl reset-failed
```

Remove the installed restoration script and shared configuration:

```bash
sudo rm -f /usr/local/sbin/nordvpn-bypass-nftables
sudo rm -f /etc/nordvpn-bypass.conf
```

If persistence was not installed, remove the live table directly:

```bash
sudo nft delete table inet app_bypass
```

Remove the wrapper from the path selected during installation. The path is shown by:

```bash
nordvpn-bypass settings
```

Then remove the group only if it is no longer used by anything else:

```bash
sudo gpasswd -d "$USER" nordvpn-bypass
sudo groupdel nordvpn-bypass
```

Do not remove NordVPN itself or modify its own firewall table as part of this project's uninstallation.

## 10. Limitations and safety notes

- This is an unofficial workaround, not a native NordVPN application split-tunnelling feature.
- The method depends on NordVPN's firewall mark and policy-routing behaviour. Recheck these after NordVPN client updates.
- The bypass group name should be consistent across installations, but its numeric GID is machine-specific and is discovered dynamically.
- The firewall mark is discovered dynamically from `nordvpn settings`; do not hardcode the example value `0xe1f1`.
- `BindNetworkInterface=` is applied by the system systemd manager in the tested setup. `systemd-run --user` did not work equivalently on that setup.
- Bypassed applications use the physical interface and are outside the VPN tunnel. When NordVPN is disconnected, the bypassed applications still use the physical route; this project does not provide a kill switch for them.
- This README does not claim to verify DNS or IPv6 leak behaviour. Test those separately for your environment.
