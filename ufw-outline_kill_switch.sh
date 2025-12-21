#!/usr/bin/env bash
set -euo pipefail

: '
================================================
          Outline VPN UFW Kill Switch

Usage: sudo ./ufw-outline_kill_switch.sh [mode]
Modes: off | standard | hardened | portal
================================================
'

# Required; values set before launch
OUTLINE_IP=""
OUTLINE_PORT=""
BACKUP_DIR="/var/backups/ufw"

# Optional; values override auto-detect
TUN_IF=""
LAN_IF=""
GATEWAY_IP=""

usage() {
  cat <<'EOF'
Usage:
  sudo ./ufw-outline_kill_switch.sh [mode]

Modes:
  off
    Disables kill switch rules, restores baseline (or most recent, if unavailable) UFW rules.

  standard
    Route-authoritative. 
    General purpose, simple, compatible.

  hardened
    Interface-authoritative. 
    High assurance, strict, inconvenient. 
    Prevents leaks via routing changes, app-interface binding, DNS, and IPv6. Breaks LAN services, captive portals, etc.
    
  portal
    Temporary captive-portal mode for hardened users.
    Intentionally "less strict", but still tries to minimize leaks.
    
    NOTE: This WILL NOT work on every captive portal.

EOF
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0 [mode]"
    exit 1
  fi
}

# Auto-detect variables; works for most systems
get_default_gateway_ip() {
  ip route | awk '/default/ {print $3; exit}'
}

detect_tun_interface() {
  local candidate
  candidate="$(ip -o link show | awk -F': ' '$2 ~ /^outline-tun[0-9]+$/ {print $2; exit}')"
  if [[ -z "$candidate" ]]; then
    candidate="$(ip -o link show | awk -F': ' '$2 ~ /^(tun|tap|wg)[0-9]*$/ {print $2; exit}')"
  fi
  echo "$candidate"
}

detect_lan_interface() {
  ip route | awk '/default/ {print $5; exit}'
}

auto_detect_interfaces() {
  if [[ -z "$TUN_IF" ]]; then
    TUN_IF="$(detect_tun_interface || true)"
  fi

  if [[ -z "$LAN_IF" ]]; then
    LAN_IF="$(detect_lan_interface || true)"
  fi

  if [[ -z "$GATEWAY_IP" ]]; then
    GATEWAY_IP="$(get_default_gateway_ip || true)"
  fi
}

require_tun_interface() {
  if [[ -z "$TUN_IF" ]]; then
    echo "[!] Can't determine tunnel interface (TUN_IF). Set manually."
    exit 1
  fi
}

require_lan_interface() {
  if [[ -z "$LAN_IF" ]]; then
    echo "[!] Can't determine LAN interface (LAN_IF). Set manually."
    exit 1
  fi
}

backup_ufw() {
  echo "[*] Backing up UFW rules to $BACKUP_DIR..."
  mkdir -p "$BACKUP_DIR"
  local timestamp baseline_user baseline_user6 baseline_state
  timestamp="$(date +%Y%m%d-%H%M%S)"
  baseline_user="$BACKUP_DIR/baseline-user.rules"
  baseline_user6="$BACKUP_DIR/baseline-user6.rules"
  baseline_state="$BACKUP_DIR/baseline-status.state"

  if [[ ! -f "$baseline_user" ]]; then
    cp /etc/ufw/user.rules "$baseline_user"
    if [[ -f /etc/ufw/user6.rules ]]; then
      cp /etc/ufw/user6.rules "$baseline_user6"
    fi
    ufw status | awk 'NR==1 {print $2}' > "$baseline_state"
  fi

  cp /etc/ufw/user.rules "$BACKUP_DIR/user.rules.$timestamp"
  cp /etc/ufw/user.rules "$BACKUP_DIR/latest-user.rules"

  if [[ -f /etc/ufw/user6.rules ]]; then
    cp /etc/ufw/user6.rules "$BACKUP_DIR/user6.rules.$timestamp"
    cp /etc/ufw/user6.rules "$BACKUP_DIR/latest-user6.rules"
  fi

  ufw status numbered > "$BACKUP_DIR/kill_switch-${timestamp}.txt"
  ufw status | awk 'NR==1 {print $2}' > "$BACKUP_DIR/latest-status.state"
}

ufw_prepend() {
  ufw insert 1 "$@"
}

restore_baseline_rules_only() {
  local baseline_user="$BACKUP_DIR/baseline-user.rules"
  local baseline_user6="$BACKUP_DIR/baseline-user6.rules"
  local latest_user="$BACKUP_DIR/latest-user.rules"
  local latest_user6="$BACKUP_DIR/latest-user6.rules"

  local user_rules_source=""
  if [[ -f "$baseline_user" ]]; then
    user_rules_source="$baseline_user"
  elif [[ -f "$latest_user" ]]; then
    user_rules_source="$latest_user"
  else
    return 1
  fi

  cp "$user_rules_source" /etc/ufw/user.rules

  if [[ -f "$baseline_user6" ]]; then
    cp "$baseline_user6" /etc/ufw/user6.rules
  elif [[ -f "$latest_user6" ]]; then
    cp "$latest_user6" /etc/ufw/user6.rules
  fi

  if ufw status | grep -qi "Status: active"; then
    ufw reload >/dev/null || true
  fi

  return 0
}

ensure_ufw_enabled() {
  if ufw status | grep -qi "Status: inactive"; then
    ufw --force enable
  fi
}

restore_ufw() {
  echo "[*] Restoring previous UFW rules..."

  local baseline_user="$BACKUP_DIR/baseline-user.rules"
  local baseline_user6="$BACKUP_DIR/baseline-user6.rules"
  local baseline_state="$BACKUP_DIR/baseline-status.state"
  local latest_user="$BACKUP_DIR/latest-user.rules"
  local latest_user6="$BACKUP_DIR/latest-user6.rules"
  local latest_state="$BACKUP_DIR/latest-status.state"

  local user_rules_source=""
  if [[ -f "$baseline_user" ]]; then
    user_rules_source="$baseline_user"
  elif [[ -f "$latest_user" ]]; then
    user_rules_source="$latest_user"
  else
    echo "[!] No previous UFW rules found in $BACKUP_DIR"
    return 1
  fi

  cp "$user_rules_source" /etc/ufw/user.rules

  if [[ -f "$baseline_user6" ]]; then
    cp "$baseline_user6" /etc/ufw/user6.rules
  elif [[ -f "$latest_user6" ]]; then
    cp "$latest_user6" /etc/ufw/user6.rules
  fi

  local previous_state="active"
  if [[ -f "$baseline_state" ]]; then
    previous_state="$(cat "$baseline_state")"
  elif [[ -f "$latest_state" ]]; then
    previous_state="$(cat "$latest_state")"
  fi

  if [[ "$previous_state" == "inactive" ]]; then
    ufw disable
  else
    ufw reload
  fi

  return 0
}

allow_base() {
  ufw_prepend allow in on lo
  ufw_prepend allow out on lo
}

allow_outline_handshake() {
  ufw_prepend allow out to "$OUTLINE_IP" port "$OUTLINE_PORT" proto tcp
  ufw_prepend allow out to "$OUTLINE_IP" port "$OUTLINE_PORT" proto udp
}

prepare_kill_switch_mode() {
  backup_ufw
  if restore_baseline_rules_only; then
    echo "[*] Baseline UFW rules applied."
  fi
  ensure_ufw_enabled
}

apply_standard_rules() {
  require_tun_interface

  ufw_prepend deny out from any to any
  ufw_prepend deny in from any to any

  ufw_prepend allow in on "$TUN_IF"
  ufw_prepend allow out on "$TUN_IF"
  allow_outline_handshake
  allow_base
}

apply_hardened_rules() {
  require_tun_interface

  ufw_prepend deny out 53
  ufw_prepend deny out from any to any
  ufw_prepend deny in from any to any

  ufw_prepend allow out on "$TUN_IF" from any to any
  ufw_prepend allow in on "$TUN_IF"
  allow_outline_handshake
  allow_base
}

apply_portal_rules() {
  require_lan_interface

  local gateway_ip="$1"

  ufw_prepend deny out from any to any
  ufw_prepend deny in from any to any
  allow_base

  ufw_prepend allow out on "$LAN_IF" proto udp to 255.255.255.255 port 67
  ufw_prepend allow out on "$LAN_IF" proto udp to "$gateway_ip" port 67
  ufw_prepend allow out on "$LAN_IF" proto udp to "$gateway_ip" port 68

  ufw_prepend allow out on "$LAN_IF" to "$gateway_ip" port 53 proto udp
  ufw_prepend allow out on "$LAN_IF" to "$gateway_ip" port 53 proto tcp

  ufw_prepend allow out on "$LAN_IF" to "$gateway_ip" port 80 proto tcp
  ufw_prepend allow out on "$LAN_IF" to "$gateway_ip" port 443 proto tcp
}

: '
================================================
                      Main
================================================
' 

MODE="$1"

require_root
auto_detect_interfaces

case "$MODE" in
  off)
    if restore_ufw; then
      ufw status verbose
      echo "[✓] Previous UFW rules restored."
    else
      echo "[!] No backup found, unable to restore UFW rules."
      exit 1
    fi
    ;;

  standard)
    echo "[*] Enabling STANDARD kill switch..."
    prepare_kill_switch_mode
    apply_standard_rules
    ensure_ufw_enabled
    ufw status verbose
    ;;

  hardened)
    echo "[*] Enabling HARDENED kill switch..."
    prepare_kill_switch_mode
    apply_hardened_rules
    ensure_ufw_enabled
    ufw status verbose
    ;;

  portal)
    prepare_kill_switch_mode

    portal_gateway="$GATEWAY_IP"
    if [[ -z "$portal_gateway" ]]; then
      portal_gateway="$(get_default_gateway_ip || true)"
      GATEWAY_IP="$portal_gateway"
    fi

    if [[ -z "$portal_gateway" ]]; then
      echo "[!] Can't determine default gateway. Connect to Wi-Fi first or set GATEWAY_IP manually."
      exit 1
    fi

    require_lan_interface
    echo "[*] Applying PORTAL mode on $LAN_IF (gateway=$portal_gateway)"
    apply_portal_rules "$portal_gateway"
    ensure_ufw_enabled
    ufw status verbose
    echo "
    Remember to switch back to hardened mode after connecting.
    If the portal doesn't load, try temporarily turning off the kill switch."
    ;;

  *)
    usage
    exit 1
    ;;
esac

echo "[✓] Done."
