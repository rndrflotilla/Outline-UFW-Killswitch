# Outline UFW Kill Switch

This is a script to force all internet traffic through the Outline VPN tunnel via UFW rules. It backs up your current UFW rules and applies a user-defined ruleset based on use case (such as preventing leaks while acessing the internet via captive portals).

## Requirements

- Linux with `ufw` installed and enabled (`sudo apt install ufw` on Debian/Ubuntu).
- Run commands with `sudo`.
- Your Outline server IP and port (set `OUTLINE_IP` and `OUTLINE_PORT` in the script or as env vars).

## Usage

```bash
sudo ./ufw-outline_kill_switch.sh [mode]
# modes: off | standard | hardened | portal
```

- `off` — Disables kill switch rules, restores baseline (or most recent, if unavailable) UFW rules.

- `standard` — Route-authoritative.
  General purpose, simple, compatible.

- `hardened` — Interface-authoritative.
  High assurance, strict, inconvenient.
  Prevents leaks via routing changes, app-interface binding, DNS, and IPv6. Breaks LAN services, captive portals, etc.

- `portal` — Temporary captive-portal mode for hardened users.
  Intentionally "less strict", but still tries to minimize leaks.

  NOTE: This WILL NOT work on every captive portal.

## What it does

- Auto-detects the Outline tunnel interface and LAN interface.
- Backs up UFW rules to `/var/backups/ufw` before applying changes and remembers prior UFW state.
- Prepends deny rules, then allows loopback and the Outline handshake (TCP/UDP to `OUTLINE_IP:OUTLINE_PORT`).
- Shows the resulting UFW status after applying a mode.

## Notes

- If auto-detection fails, set variables at the top of the script or via env vars: `TUN_IF`, `LAN_IF`, `GATEWAY_IP`.
- After using `portal`, switch back to `hardened` once authenticated.

## License

GPL-3.0 (see `LICENSE`).
