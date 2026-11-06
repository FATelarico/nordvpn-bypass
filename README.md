# Per-application split tunnelling with NordVPN on Linux

<img src="https://github.com/FATelarico/nordvpn-bypass/blob/main/logo.png?raw=true" width="224px">

NordVPN's [Linux client](https://github.com/NordSecurity/nordvpn-linux) does not natively provide per-application split tunnelling.

This project provides an unofficial, opt-in workaround that allows selected applications to bypass NordVPN while other applications continue to use the VPN. It uses Linux user groups, `systemd`, packet marks in `nftables`, and NordVPN's own policy-routing rules.

Applications launched with `nordvpn-bypass` use a selected physical network interface, which may be the same interface used by the VPN.
Applications launched normally continue to follow NordVPN's routing policy.

**Tested configuration:** Debian 14, systemd 262 and NordVPN 6.0.1.

> [!WARNING]
> A split tunnel means that applications launched through `nordvpn-bypass` bypass the NordVPN tunnel and use the selected network interface directly. Their traffic therefore does not receive the protection of NordVPN's VPN tunnel. Use this wrapper only for applications you intentionally want to run outside the VPN. Application-level encryption, such as HTTPS, may still protect the contents of connections, but it does not route them through NordVPN.
>
> This project is not affiliated with, endorsed by, or supported by NordVPN.

## Contents

- [Requirements and compatibility](#requirements-and-compatibility)
- [1. Quick start](#1-quick-start)
- [2. Manual installation](#2-manual-installation)
  - [2.1 Set the three identifiers](#21-set-the-three-identifiers)
  - [2.2 Check the NordVPN configuration](#22-check-the-nordvpn-configuration)
  - [2.3 Identify the physical interface](#23-identify-the-physical-interface)
  - [2.4 Create the bypass group](#24-create-the-bypass-group)
  - [2.5 Create the `nftables` marking rule](#25-create-the-nftables-marking-rule)
  - [2.6 Configure the `nordvpn-bypass` launcher](#26-configure-the-nordvpn-bypass-launcher)
  - [2.7 Roll back the `nftables` changes](#27-roll-back-the-nftables-changes)
  - [2.8 Make the `nftables` changes persistent](#28-make-the-nftables-changes-persistent)
- [3. Test the configuration](#3-test-the-configuration)
- [4. Troubleshooting](#4-troubleshooting)
- [5. Uninstall](#5-uninstall)
- [6. Updating the mark or group ID](#6-updating-the-mark-or-group-id)
- [7. Limitations and safety notes](#7-limitations-and-safety-notes)

## Requirements and compatibility

The manual procedure assumes Debian 14 with systemd 262 and NordVPN 6.0.1, and an available physical network interface. Other combinations *should* work as long as systemd 260 or later and NordVPN 6.0 or later are installed.

For manual installation, the `nft`, `ip`, `systemd-run`, `runuser` and `sg` commands must be available. The NordVPN client must be installed and configured.

## 1. Quick start

Download `nordvpn-bypass.zip` from the [Releases](https://github.com/FATelarico/nordvpn-bypass/releases/latest) page and extract its contents to a directory.

For the assisted setup, make the installer executable and run it as the superuser:

```bash
chmod +x nordvpn-bypass-installer.sh
sudo ./nordvpn-bypass-installer.sh
```

Follow the instructions on screen. Manual installation is documented in section 2.

> [!NOTE]
> For a testing or temporary setup, run the installer with the `--no-persistence` flag:
>
> ```bash
> sudo ./nordvpn-bypass-installer.sh --no-persistence
> ```
>
> See sections 2.7 and 2.8 for information about temporary and persistent `nftables` rules.

The installer will prompt you for the following parameters:

1. **The user who will use split tunnelling.** The current user's name is shown in square brackets and is the appropriate choice for most setups.
2. **The installation location for the wrapper command.** The suggested location should be on `PATH` on Debian-based distributions and other compatible systemd-based systems.
3. **The network interface for split tunnelling.** Select the physical interface connected to your local network. Do not select the loopback interface, the NordLynx interface, or an unrelated virtual interface. An interface being marked `UP` is not, by itself, enough to identify the correct one.
4. **The bypass group name.** This identifies applications that should bypass NordVPN. In most cases, leave the default value, `nordvpn-bypass`.

## 2. Manual installation

The following procedure describes a configuration using a network interface named `wlp5s0`. Replace this with the name of the physical interface on your system.

### 2.1 Set the three identifiers

A manual installation requires three values:

| Value | Meaning | How to obtain it | Example |
|---|---|---|---|
| Bypass group name | Identifies applications that should bypass the VPN | Chosen by the user | `nordvpn-bypass` |
| Bypass group GID | The local numeric ID of the group; `nftables` matches this number | `getent group nordvpn-bypass` | `1001` |
| NordVPN firewall mark (`fwmark`) | The mark NordVPN uses in its policy-routing and firewall rules | `nordvpn settings` | `0xe1f1` |

Using the same bypass group name on different machines is preferable, although the numeric GID may differ. The NordVPN firewall mark may also differ between installations, so do not assume that it is the same on every machine. Retrieve it from the local NordVPN configuration:

```bash
MARK="$(nordvpn settings | awk -F': *' '/Firewall Mark:/ {print $2}')"
printf 'NordVPN firewall mark: %s\n' "$MARK"
```

If the mark is empty, stop and check the NordVPN configuration before proceeding. If a NordVPN update changes the mark, update the custom `nftables` rule as described in section 6.

### 2.2 Check the NordVPN configuration

Connect NordVPN and inspect its settings:

```bash
nordvpn settings
```

Confirm that:

- `Protocol` is `NordLynx` (the only protocol tested in this setup).
- `Firewall` is enabled.
- `Routing` is enabled.
- A `Firewall Mark` is shown.

Read the mark into a shell variable:

```bash
MARK="$(nordvpn settings | awk -F': *' '/Firewall Mark:/ {print $2}')"
printf 'NordVPN firewall mark: %s\n' "$MARK"
```

Check that NordVPN has a policy-routing rule using that mark:

```bash
ip rule
```

For the example mark `0xe1f1`, the NordVPN rules include a rule resembling:

```text
not from all fwmark 0xe1f1 lookup 205
```

The exact table number and rule ordering may differ. Do not copy the example mark or table number without checking your own system.

You can inspect NordVPN's `nftables` rules with:

```bash
sudo nft list table inet nordvpn
```

Do not edit or flush NordVPN's own `inet nordvpn` table as part of this setup.

### 2.3 Identify the physical interface

List network interfaces and their addresses:

```bash
ip -br link
ip -br addr
```

Choose the physical interface that bypassed traffic should use. In the example configuration it is `wlp5s0`. Do not select `lo`, the NordLynx interface, or an unrelated virtual interface.

Check that the selected interface has an address and a route:

```bash
ip route get 9.9.9.9 oif wlp5s0
```

Example output may show a route through the local router and a source address on the local Wi-Fi subnet:

```text
9.9.9.9 via 192.168.1.1 dev wlp5s0 src 192.168.1.241
```

Replace `wlp5s0` with the actual interface name on your system.

### 2.4 Create the bypass group

Create the group if it does not already exist:

```bash
getent group nordvpn-bypass >/dev/null || sudo groupadd --system nordvpn-bypass
```

Add the user who will run the wrapper to the group:

```bash
sudo usermod -aG nordvpn-bypass "$USER"
```

Log out of the desktop session and log back in so the new supplementary group membership is available to your session. Check it with:

```bash
id -nG
getent group nordvpn-bypass
```

Get the numeric GID dynamically:

```bash
GID="$(getent group nordvpn-bypass | cut -d: -f3)"
printf 'Bypass group GID: %s\n' "$GID"
```

The group name should be kept consistent, but the GID is machine-specific. Use the GID returned by this command in the `nftables` rule below.

### 2.5 Create the `nftables` marking rule

The custom rule marks packets created by sockets whose group ID is the bypass GID. It sets the packet mark to the mark NordVPN already recognises as its VPN-bypass or transport exception. In the tested configuration, the rule is placed immediately before NordVPN's output chain.

First obtain the current values:

```bash
GID="$(getent group nordvpn-bypass | cut -d: -f3)"
MARK="$(nordvpn settings | awk -F': *' '/Firewall Mark:/ {print $2}')"

printf 'GID=%s\nMARK=%s\n' "$GID" "$MARK"
```

Stop if either value is empty. Then create the custom table and chain if they do not already exist, and install the rule:

```bash
sudo nft list table inet app_bypass >/dev/null 2>&1 || \
  sudo nft add table inet app_bypass

sudo nft list chain inet app_bypass output >/dev/null 2>&1 || \
  sudo nft 'add chain inet app_bypass output { type route hook output priority mangle - 1; policy accept; }'

# Replace any previous rule in this custom chain, avoiding duplicates.
sudo nft flush chain inet app_bypass output

sudo nft add rule inet app_bypass output \
  meta skgid "$GID" meta mark set "$MARK" counter
```

> [!WARNING]
> `nft flush chain` removes every rule in the specified chain. The `inet app_bypass output` chain should be dedicated to this configuration; do not use it for unrelated rules.

Inspect the result:

```bash
sudo nft list chain inet app_bypass output
```

It should resemble:

```text
table inet app_bypass {
    chain output {
        type route hook output priority mangle - 1; policy accept;
        meta skgid 1001 meta mark set 0x0000e1f1 counter
    }
}
```

The GID and mark shown above are examples. Your output should contain the values discovered on your own machine.

The counter should increase when a bypass application creates network connections. It is cumulative, so compare it before and after a test if you need to attribute traffic to a particular application.

### 2.6 Configure the `nordvpn-bypass` launcher

The launcher uses a small user configuration file:

```text
~/.config/nordvpn-bypass/config
```

The file contains the values the launcher needs:

```ini
INTERFACE=wlp5s0
BYPASS_GROUP=nordvpn-bypass
```

The wrapper supports these commands:

```bash
nordvpn-bypass settings
nordvpn-bypass set interface wlp5s0
nordvpn-bypass set group nordvpn-bypass
```

- `settings` displays the active configuration and the local GID for the configured group.
- `set interface NAME` changes the interface used by the launcher.
- `set group NAME` changes the group used by the launcher.

The configuration file can also be edited directly with a text editor. For example:

```bash
nano ~/.config/nordvpn-bypass/config
```

> [!WARNING]
> Changing the wrapper's group setting does not automatically change the `nftables` rule. If the group changes, obtain its new GID and rebuild the custom rule using the commands in section 6. The same applies if the NordVPN firewall mark changes after an update.

The wrapper's application-launch command must use the system-wide systemd manager and the following execution sequence. This is the sequence verified in the example setup:

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

The installed wrapper substitutes the configured interface, group, and requested application and arguments into this sequence. In the example above, replace `wlp5s0` and `freetube` with the interface and application used on your system.

**Do not replace `--system` with `--user`, or change the order of `runuser`, `env`, and `sg` without re-testing.** In the tested setup, the system manager's `BindNetworkInterface` scope was necessary; the user manager did not produce the same result.

Run the wrapper as your normal desktop user, without prefixing it with `sudo`:

```bash
nordvpn-bypass freetube
```

Other examples:

```bash
nordvpn-bypass firefox
nordvpn-bypass chromium
nordvpn-bypass transmission-gtk
```

Applications launched normally, without `nordvpn-bypass`, continue to use the ordinary NordVPN routing policy.

### 2.7 Roll back the `nftables` changes

The `nft` commands above modify the live `nftables` ruleset. To remove the custom table, run:

```bash
sudo nft delete table inet app_bypass
```

Unless another mechanism separately restores it from a persistent configuration, the custom table will not survive a reboot. If you have configured the systemd persistence service in section 2.8, stop and disable that service to remove the table through its `ExecStop` command.

### 2.8 Make the `nftables` changes persistent

To reapply the custom rules when NordVPN starts, install the repository's persistence script and create a systemd service for it. The following names and paths are used in the example:

| Item | Purpose | Example |
|---|---|---|
| NordVPN service | The systemd service that starts NordVPN | `nordvpnd.service` |
| Installed script | The root-owned persistence script | `/usr/local/sbin/nordvpn-bypass-nftables` |
| Persistence service | The systemd unit that applies the custom rules | `nordvpn-bypass-nftables.service` |

Check the name of the NordVPN service on your system:

```bash
systemctl list-unit-files --type=service | grep -i nordvpn
```

The service is commonly named `nordvpnd.service`, but use the name shown on your system in the unit file below.

The script is named `nordvpn-bypass-nftables.sh` in the repository. From the repository directory, install it as `/usr/local/sbin/nordvpn-bypass-nftables` (without the `.sh` suffix), owned by `root` and executable:

```bash
sudo install -o root -g root -m 755 \
  nordvpn-bypass-nftables.sh \
  /usr/local/sbin/nordvpn-bypass-nftables
```

Create `/etc/systemd/system/nordvpn-bypass-nftables.service` with the following contents. The service filename can be changed, but if you do so, use the new name in the commands that follow. If your NordVPN service has a different name, update `Requires`, `After`, and `PartOf` accordingly.

```ini
[Unit]
Description=NordVPN application split-tunnelling firewall rules
Requires=nordvpnd.service
After=nordvpnd.service
PartOf=nordvpnd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nordvpn-bypass-nftables
ExecStop=-/usr/sbin/nft delete table inet app_bypass
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The `ExecStart` path must match the installed script path. The `Requires`, `After`, and `PartOf` entries must refer to the NordVPN systemd service on your machine.

Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nordvpn-bypass-nftables.service
```

Check that the service is active and that the relevant tables and chains can be listed:

```bash
systemctl is-active nordvpn-bypass-nftables.service
sudo nft list table inet app_bypass
sudo nft list chain inet nordvpn output
```

The service uses `Type=oneshot` with `RemainAfterExit=yes`, so `systemctl is-active` should report `active` after the rules have been applied.

## 3. Test the configuration

With NordVPN connected, the following commands should normally return different IPv4 public addresses: the first should use the direct connection, and the second should use NordVPN.

```bash
nordvpn-bypass curl -4 https://icanhazip.com  # Direct connection
curl -4 https://icanhazip.com                 # NordVPN connection
```

Close any existing instance of an application that should be split-tunnelled, then launch it through the wrapper (for example, `nordvpn-bypass firefox-esr`). Check that it can access the internet and the system resources it needs, such as audio playback.

For further diagnostics, inspect the configured policy-routing rules and the relevant `nftables` chains:

```bash
ip rule
sudo nft list chain inet app_bypass output
sudo nft list chain inet nordvpn output
```

These commands show the configured policy-routing rules and `nftables` chains; they do not trace the route taken by an individual packet. Actual packet routing can be investigated separately using suitable routing diagnostics or packet-capture tools.

When examining an actual bypassed connection, the source address observed on the physical interface should be the machine's Wi-Fi or LAN address (for example, `192.168.1.XXX`), not the NordLynx address (for example, `10.X.X.X`).

The public-IP test above checks IPv4 only. It does not establish how DNS or IPv6 traffic behaves on your system; test those separately if they are relevant to your setup.

## 4. Troubleshooting

| Symptom | Checks |
|---|---|
| `nordvpn-bypass` cannot be found | Check the installation location selected for the wrapper and whether that directory is on your `PATH`. Run `command -v nordvpn-bypass`. |
| A bypassed application cannot connect | Check that the selected physical interface is up, has an address and has a route. Check the user's group membership with `id -nG` and inspect the custom `nftables` chain and its counter. |
| The bypassed and ordinary commands show the same public IPv4 address | Confirm that NordVPN is connected. Check the firewall mark shown by `nordvpn settings`, the corresponding rule in `ip rule`, and whether the counter in `inet app_bypass output` increases when the bypassed command runs. |
| The persistence service does not start | Inspect `systemctl status nordvpn-bypass-nftables.service` and `journalctl -u nordvpn-bypass-nftables.service`. Check that `ExecStart` points to the installed script and that the NordVPN service name in the unit file is correct. |

These checks help identify configuration problems; they do not replace packet-level investigation where that is needed.

## 5. Uninstall

Before uninstalling, consider backing up the configuration, which is stored by default in `~/.config/nordvpn-bypass/config`. The exact path can be checked with:

```bash
nordvpn-bypass settings | grep -Po 'Config file:\K.*'
```

To back up the default configuration:

```bash
cp -- ~/.config/nordvpn-bypass/config ~/nordvpn-bypass-config.bak
```

If you installed the persistence service, first inspect its unit file and then disable and stop it. Stopping the service runs its `ExecStop` command, which removes the custom `inet app_bypass` table:

```bash
sudo systemctl cat nordvpn-bypass-nftables.service
sudo systemctl disable --now nordvpn-bypass-nftables.service
sudo rm -- /etc/systemd/system/nordvpn-bypass-nftables.service
sudo systemctl daemon-reload
sudo systemctl reset-failed
```

Remove the installed persistence script. Its default installed path is `/usr/local/sbin/nordvpn-bypass-nftables` (without the `.sh` suffix):

```bash
sudo rm -- /usr/local/sbin/nordvpn-bypass-nftables
```

If you did not install the persistence service, remove the live custom table manually, if it exists:

```bash
sudo nft delete table inet app_bypass
```

The wrapper can be removed by deleting the executable installed by the automatic installer. Its location can be checked with `command -v nordvpn-bypass`:

```bash
WRAPPER="$(command -v nordvpn-bypass)"
if [ -n "$WRAPPER" ]; then
  sudo rm -- "$WRAPPER"
else
  printf 'nordvpn-bypass was not found on PATH.\n'
fi
```

The uninstall steps above do not remove the user's configuration directory or the `nordvpn-bypass` group. If you no longer need them, and the group is not used by anything else, remove them separately:

```bash
rm -r -- ~/.config/nordvpn-bypass
sudo gpasswd -d "$USER" nordvpn-bypass
sudo groupdel nordvpn-bypass
```

## 6. Updating the mark or group ID

After a NordVPN update or configuration change, check:

```bash
nordvpn settings
ip rule
sudo nft list table inet nordvpn
sudo nft list chain inet app_bypass output
```

If the firewall mark or bypass group's GID changes, rebuild the custom rule. Use the group name configured in `~/.config/nordvpn-bypass/config`; the following example uses the default name, `nordvpn-bypass`:

```bash
BYPASS_GROUP="nordvpn-bypass"
GID="$(getent group "$BYPASS_GROUP" | cut -d: -f3)"
MARK="$(nordvpn settings | awk -F': *' '/Firewall Mark:/ {print $2}')"

printf 'GID=%s\nMARK=%s\n' "$GID" "$MARK"
```

If either value is empty, stop and check the group and NordVPN configuration before proceeding. Otherwise, replace the existing rule:

```bash
sudo nft flush chain inet app_bypass output
sudo nft add rule inet app_bypass output \
  meta skgid "$GID" meta mark set "$MARK" counter
```

If the group name changes, update the wrapper configuration as well as the rule. The group name can remain `nordvpn-bypass` across machines even when its numeric GID differs.

If NordVPN no longer has a policy-routing rule corresponding to its displayed firewall mark, stop and reassess the setup rather than guessing a replacement mark or routing-table number.

## 7. Limitations and safety notes

- This is an unofficial, system-specific workaround, not an officially supported NordVPN application split-tunnelling feature.
- The project relies on NordVPN's local firewall mark and policy-routing behaviour. These may change after a NordVPN update; recheck the mark and routing rules after updates.
- The bypass group name can be standardised across machines, while its numeric GID is discovered locally.
- `BindNetworkInterface` is applied by the system `systemd` manager in the tested setup. `systemd-run --user` was tested but did not work in that setup; `systemd-run --system --scope` was required.
- Applications launched through the wrapper use the selected network interface rather than the NordVPN tunnel. Application-level encryption, such as HTTPS, still applies where the application uses it.
- The IPv4 public-IP test in this README does not verify DNS or IPv6 behaviour. Those should be tested separately if they matter to your configuration.
