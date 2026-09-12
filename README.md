# My Network for Omarchy

An enhanced, keyboard-first Omarchy network bar widget. It is a drop-in
replacement for the built-in `omarchy.network` widget and adds inline
**wired NIC IPv4 management**: switch a NetworkManager-managed Ethernet
adapter between DHCP and static IP, with immediate activation and clear
failure messages.

> Community plugin: not affiliated with, sponsored by, or endorsed by
> Omarchy, 37signals, or NetworkManager.

## Features

- Omarchy-native Wi-Fi scanning, connection, disconnection, forgotten
  networks, hidden networks, and QR sharing integration.
- Wired NIC list with carrier/state/profile status.
- Only real, attached hardware NICs are listed. Networks that were unplugged,
  interfaces with nothing behind them, and the Apple T2 chip's always-present
  bridge Ethernet are filtered out, so once the adapter is gone the whole wired
  section disappears instead of showing the last NIC that was seen.
- Switch a wired NIC between **Auto DHCP** and **Manual static IPv4** from
  the bar panel.
- The same choice for Wi-Fi, per network — macOS' "Configure IPv4: Using DHCP /
  Manually". A **WI-FI IPV4** section appears while a Wi-Fi network is in use
  and writes the static address, gateway and DNS into that network's
  NetworkManager profile, so it survives reconnects and reboots, and every
  network keeps its own settings.
- Apply a static IP or DHCP change immediately through NetworkManager — no
  reboot required.
- Cleanly reactivate only the selected NIC when switching between DHCP and
  static addressing, then verify the requested live IPv4 state before the UI
  reports success.
- Surface activation errors (for example a static IP already in use on the
  LAN) instead of reporting a false success.
- Avoids showing Tailscale/tailnet addresses during a DHCP/static transition:
  the status helpers prefer the physical NetworkManager NIC over the
  `tailscale0` route fallback.
- Supports multiple managed Ethernet adapters.

## Requirements

- Omarchy with the Quattro shell plugin system.
- NetworkManager (`nmcli`) managing the Ethernet adapters.
- `jq` for status/IP parsing.
- `wl-copy` for clipboard copy actions.
- `iw` is used only when Wi-Fi details are available.

The plugin does not bundle or modify NetworkManager.

## Installation

```bash
omarchy plugin add https://github.com/hehh2001/omarchy-network-plus.git --enable --yes
```

Then restart the shell if the widget is not visible yet:

```bash
omarchy restart shell
```

If the widget is not on the bar, add it:

```bash
omarchy plugin enable zzb.network --section right
```

### Notes

- The plugin id is `zzb.network`.
- Because the manifest declares `clonedFrom: omarchy.network`, Omarchy routes
  the built-in network shortcut (`SUPER + CTRL + W`) to this widget while it
  is enabled, just like a locally cloned built-in widget.

## Removal

```bash
omarchy plugin remove zzb.network --yes
```

## Configuration

No extra configuration is required. Like the built-in network widget, it can
be placed in any bar section via `omarchy bar` or by editing
`~/.config/omarchy/shell.json`.

## Testing

The helpers and the shared row logic ship with regression tests that stub
`nmcli` (and the kernel's network view), so they run anywhere, need no
privileges, and touch no real connection:

```bash
bash tests/wired-nic-detection-test.sh   # which devices may appear as wired NICs
bash tests/network-switch-test.sh        # wired DHCP <-> static transitions
bash tests/wifi-ipv4-test.sh             # Wi-Fi DHCP <-> static transitions
bash tests/model-ipv4-test.sh            # the wording/state both rows derive
```

## License

MIT. This plugin includes code derived from the Omarchy built-in network
widget, which is Copyright (c) David Heinemeier Hansson.
