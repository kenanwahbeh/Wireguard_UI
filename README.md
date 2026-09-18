# **Byte Balance Technology**

# Wireguard_UI

A self-contained, single-file WireGuard installer and manager. No external
database or config files — every server key and client (device) is stored
inside the script itself, so copying the one `.sh` file is enough to
reinstall or restore a full setup on a new machine.

## Features

- Interactive setup: installs WireGuard, auto-detects available network
  interfaces, and lets you pick which one faces the internet.
- Self-contained state: server keys and the full device list live inside
  the script (between `WG_STATE` markers) and are rewritten in place on
  every change — no `params` or `clients.db` files.
- Simple device management menu: add, remove, and list devices.
- View any device's config as plain text and as a QR code, picked from a
  numbered list.
- Tuned defaults: `PersistentKeepalive = 25`, `MTU = 1420` (better for
  slow/unstable links), VPN subnet `10.66.66.0/24`, port `22`.

## Usage

```bash
sudo bash wireguard-install.sh
```

Follow the prompts on first run to install the server. Every run after
that opens a management menu to add/remove devices or view their config.

> **Warning:** once installed, this file contains your server's and
> devices' private keys. Keep it root-only (the script sets `chmod 700`
> on itself automatically) and never share it publicly.

## License

MIT — see [LICENSE](LICENSE).
