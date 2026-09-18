#!/usr/bin/env bash
#
# WireGuard all-in-one, self-contained installer & manager. GENERIC/PUBLIC
# template — no personal IP/interface/subnet baked in. Safe to copy and run
# on any fresh server.
#
# Network:  10.66.66.0/24  (server = 10.66.66.1) — change SUBNET_PREFIX below
#           if you want a different VPN subnet.
# Port:     22 by default (often left open on firewalls; change at install
#           time if you prefer the conventional 51820).
# Keepalive: 25s | MTU: 1420 by default (asked at install time — lower it
#           further, e.g. 1280, on very unstable/slow links).
#
# This script stores ALL its state (server keys, public IP/iface/port, and
# every client's keys) INSIDE ITSELF, between the WG_STATE markers below.
# No external data files (no params/clients.db). Every time you add/remove
# a client or (re)install, the script rewrites its own state block on disk.
#
# To move your setup to another machine or restore after a reinstall, just
# copy THIS FILE (it already contains everything) and run it there.
#
# WARNING: once installed, private keys live inside this file — keep it
# root-only (the script enforces chmod 700 on itself automatically) and
# never share it after it has real keys in the state block below.

# >>> WG_STATE_START >>>
WG_PUB_IFACE=""
WG_PUB_IP=""
WG_PORT=""
WG_MTU=""
WG_SERVER_PRIV=""
WG_SERVER_PUB=""
WG_CLIENTS=""
# <<< WG_STATE_END <<<

set -uo pipefail

WG_DIR="/etc/wireguard"
IFACE="wg0"
WG_CONF="${WG_DIR}/${IFACE}.conf"
CLIENTS_DIR="${WG_DIR}/clients"

SUBNET_PREFIX="10.66.66"
SERVER_IP="${SUBNET_PREFIX}.1"
KEEPALIVE=25
DEFAULT_MTU=1420

STATE_START="# >>> WG_STATE_START >>>"
STATE_END="# <<< WG_STATE_END <<<"
SCRIPT_PATH="$(readlink -f "$0")"

# Color scheme: green = success/info, yellow = warning, red = error,
# cyan = user input prompts, bold magenta = menu title/options.
C_INFO='\033[32m'
C_WARN='\033[33m'
C_ERR='\033[31m'
C_PROMPT='\033[36m'
C_TITLE='\033[1;35m'
C_RESET='\033[0m'

msg() { echo -e "${C_INFO}[*]${C_RESET} $*"; }
warn() { echo -e "${C_WARN}[!]${C_RESET} $*"; }
err() { echo -e "${C_ERR}[x]${C_RESET} $*" >&2; }

# Prompts the user with a cyan-colored question and stores the answer in
# the variable named by $1 (used instead of plain `read -rp` everywhere).
ask() {
  local __varname="$1" __text="$2" __input
  read -rp "$(printf '%b' "${C_PROMPT}${__text}${C_RESET}")" __input
  printf -v "$__varname" '%s' "$__input"
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Run this script as root: sudo bash $0"
    exit 1
  fi
}

# Rewrites the WG_STATE block inside THIS script file with the current
# in-memory values of WG_PUB_IFACE / WG_PUB_IP / WG_PORT / WG_SERVER_PRIV /
# WG_SERVER_PUB / WG_CLIENTS. Everything else in the file is left untouched.
save_state() {
  local start_line end_line tmp
  start_line=$(grep -nF "$STATE_START" "$SCRIPT_PATH" | head -1 | cut -d: -f1)
  end_line=$(grep -nF "$STATE_END" "$SCRIPT_PATH" | head -1 | cut -d: -f1)

  if [[ -z "$start_line" || -z "$end_line" ]]; then
    err "Could not find the state block inside the script — unable to save."
    return 1
  fi

  tmp="${SCRIPT_PATH}.tmp.$$"
  {
    head -n "$start_line" "$SCRIPT_PATH"
    cat <<EOF
WG_PUB_IFACE="${WG_PUB_IFACE}"
WG_PUB_IP="${WG_PUB_IP}"
WG_PORT="${WG_PORT}"
WG_MTU="${WG_MTU}"
WG_SERVER_PRIV="${WG_SERVER_PRIV}"
WG_SERVER_PUB="${WG_SERVER_PUB}"
WG_CLIENTS="${WG_CLIENTS}"
EOF
    tail -n "+${end_line}" "$SCRIPT_PATH"
  } >"$tmp"

  mv "$tmp" "$SCRIPT_PATH"
  chmod 700 "$SCRIPT_PATH"
}

detect_pkg_mgr() {
  if command -v apt-get &>/dev/null; then
    echo apt
  elif command -v dnf &>/dev/null; then
    echo dnf
  elif command -v yum &>/dev/null; then
    echo yum
  elif command -v pacman &>/dev/null; then
    echo pacman
  else
    echo unknown
  fi
}

install_packages() {
  local mgr
  mgr=$(detect_pkg_mgr)
  case "$mgr" in
    apt)
      apt-get update -y
      apt-get install -y wireguard wireguard-tools qrencode iptables curl
      ;;
    dnf)
      dnf install -y wireguard-tools qrencode iptables curl
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y wireguard-tools qrencode iptables curl
      ;;
    pacman)
      pacman -Sy --noconfirm wireguard-tools qrencode iptables curl
      ;;
    *)
      err "Could not detect the package manager. Install manually: wireguard-tools, qrencode, iptables, curl"
      exit 1
      ;;
  esac

  if ! command -v wg &>/dev/null; then
    err "Failed to install wireguard-tools."
    exit 1
  fi
}

get_public_ip() {
  local ip
  ip=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -s --max-time 5 https://icanhazip.com || true)
  [[ -z "$ip" ]] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  echo "$ip"
}

# Searches for active network interfaces (excluding loopback) and prints a
# numbered list. Stores the chosen interface name in the variable named by
# $1 (empty if none found or the user picks invalid).
select_pub_iface() {
  local __outvar="$1"
  printf -v "$__outvar" '%s' ""

  local -a __ifaces=()
  local __raw __ifname __ip4 __count=0
  while read -r __raw; do
    __ifname=$(echo "$__raw" | awk -F': ' '{print $2}' | cut -d'@' -f1)
    [[ -z "$__ifname" || "$__ifname" == "lo" ]] && continue
    __count=$((__count + 1))
    __ifaces+=("$__ifname")
    __ip4=$(ip -4 -o addr show "$__ifname" 2>/dev/null | awk '{print $4}' | head -1)
    printf "%2d) %-12s %s\n" "$__count" "$__ifname" "${__ip4:-no IPv4}"
  done < <(ip -o link show up)

  if ((__count == 0)); then
    err "No active network interfaces found."
    return 1
  fi

  local __choice
  ask __choice "Choose the internet-facing interface number: "
  if ! [[ "$__choice" =~ ^[0-9]+$ ]] || ((__choice < 1 || __choice > __count)); then
    err "Invalid selection."
    return 1
  fi

  printf -v "$__outvar" '%s' "${__ifaces[$((__choice - 1))]}"
}

write_server_conf() {
  mkdir -p "$WG_DIR" "$CLIENTS_DIR"
  chmod 700 "$WG_DIR"
  {
    echo "[Interface]"
    echo "Address = ${SERVER_IP}/24"
    echo "ListenPort = ${WG_PORT}"
    echo "PrivateKey = ${WG_SERVER_PRIV}"
    echo "MTU = ${WG_MTU}"
    echo "PostUp = iptables -A FORWARD -i ${IFACE} -j ACCEPT; iptables -A FORWARD -o ${IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WG_PUB_IFACE} -j MASQUERADE"
    echo "PostDown = iptables -D FORWARD -i ${IFACE} -j ACCEPT; iptables -D FORWARD -o ${IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WG_PUB_IFACE} -j MASQUERADE"
    echo

    if [[ -n "$WG_CLIENTS" ]]; then
      local name ip priv pub psk
      while IFS=';' read -r name ip priv pub psk; do
        [[ -z "$name" ]] && continue
        echo "[Peer]"
        echo "# ${name}"
        echo "PublicKey = ${pub}"
        echo "PresharedKey = ${psk}"
        echo "AllowedIPs = ${ip}/32"
        echo "PersistentKeepalive = ${KEEPALIVE}"
        echo
      done <<<"$WG_CLIENTS"
    fi
  } >"$WG_CONF"
  chmod 600 "$WG_CONF"

  write_client_files
}

# Regenerates every client .conf file under CLIENTS_DIR from the keys stored
# in WG_CLIENTS. Safe to call any time (e.g. after restoring on a fresh OS)
# since it always reflects exactly what's embedded in this script right now.
write_client_files() {
  mkdir -p "$CLIENTS_DIR"
  [[ -z "$WG_CLIENTS" ]] && return

  local name ip priv pub psk
  while IFS=';' read -r name ip priv pub psk; do
    [[ -z "$name" ]] && continue
    local client_file="${CLIENTS_DIR}/${name}.conf"
    cat >"$client_file" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
DNS = 1.1.1.1, 8.8.8.8
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_SERVER_PUB}
PresharedKey = ${psk}
Endpoint = ${WG_PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = ${KEEPALIVE}
EOF
    chmod 600 "$client_file"
  done <<<"$WG_CLIENTS"
}

apply_conf() {
  if ip link show "$IFACE" &>/dev/null; then
    wg syncconf "$IFACE" <(wg-quick strip "$IFACE")
  else
    systemctl restart "wg-quick@${IFACE}"
  fi
}

enable_forwarding() {
  echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-wireguard.conf
  sysctl --system >/dev/null
}

install_server() {
  install_packages

  local input detected_iface detected_ip

  msg "Searching for available network interfaces..."
  select_pub_iface detected_iface
  if [[ -n "$detected_iface" ]]; then
    WG_PUB_IFACE="$detected_iface"
  else
    ask input "Internet-facing network interface: "
    WG_PUB_IFACE="$input"
  fi
  if [[ -z "$WG_PUB_IFACE" ]]; then
    err "A network interface is required."
    exit 1
  fi

  detected_ip=$(get_public_ip)
  ask input "Server public IPv4 address${detected_ip:+ [${detected_ip}]}: "
  WG_PUB_IP="${input:-$detected_ip}"
  if [[ -z "$WG_PUB_IP" ]]; then
    err "A public IPv4 address is required."
    exit 1
  fi

  ask input "WireGuard port [22]: "
  WG_PORT="${input:-22}"

  ask input "MTU [${DEFAULT_MTU}]: "
  WG_MTU="${input:-$DEFAULT_MTU}"

  WG_SERVER_PRIV=$(wg genkey)
  WG_SERVER_PUB=$(echo "$WG_SERVER_PRIV" | wg pubkey)

  save_state

  write_server_conf
  enable_forwarding

  systemctl enable --now "wg-quick@${IFACE}"
  msg "WireGuard server installed successfully on network ${SUBNET_PREFIX}.0/24."
  warn "All configuration data (including keys) is now stored inside this file itself: ${SCRIPT_PATH}"
  warn "Keep it protected (chmod 700 is set automatically) and never share it with anyone."
}

next_free_ip() {
  local used i
  used=$(echo "$WG_CLIENTS" | cut -d';' -f2 | sed "s/^${SUBNET_PREFIX}\.//")
  for i in $(seq 2 254); do
    if ! grep -qx "$i" <<<"$used"; then
      echo "${SUBNET_PREFIX}.${i}"
      return
    fi
  done
  err "No available addresses left in ${SUBNET_PREFIX}.0/24"
  exit 1
}

client_exists() {
  local name="$1"
  grep -qF "${name};" <<<"$WG_CLIENTS"
}

add_client() {
  local name="$1"

  if [[ -z "$name" ]]; then
    ask name "New device name (no spaces): "
  fi
  name=$(echo "$name" | tr -cd 'A-Za-z0-9_-')
  if [[ -z "$name" ]]; then
    err "Invalid name."
    return
  fi
  if client_exists "$name"; then
    err "Name '${name}' already exists, choose another one."
    return
  fi

  local ip priv pub psk client_file new_line
  ip=$(next_free_ip)
  priv=$(wg genkey)
  pub=$(echo "$priv" | wg pubkey)
  psk=$(wg genpsk)

  new_line="${name};${ip};${priv};${pub};${psk}"
  if [[ -z "$WG_CLIENTS" ]]; then
    WG_CLIENTS="$new_line"
  else
    WG_CLIENTS="${WG_CLIENTS}
${new_line}"
  fi

  save_state
  write_server_conf
  apply_conf

  client_file="${CLIENTS_DIR}/${name}.conf"
  msg "Device '${name}' added with address ${ip}"
  echo "Config file: ${client_file}"
  if command -v qrencode &>/dev/null; then
    qrencode -t ansiutf8 <"$client_file"
  fi
}

remove_client() {
  local name="$1"
  if [[ -z "$name" ]]; then
    list_clients
    ask name "Device name to remove: "
  fi
  if ! client_exists "$name"; then
    err "Device '${name}' not found."
    return
  fi

  WG_CLIENTS=$(grep -vF "${name};" <<<"$WG_CLIENTS")

  save_state
  rm -f "${CLIENTS_DIR}/${name}.conf" "${CLIENTS_DIR}/${name}.png"
  write_server_conf
  apply_conf
  msg "Device '${name}' removed."
}

list_clients() {
  if [[ -z "$WG_CLIENTS" ]]; then
    warn "No devices added yet."
    return
  fi
  printf "%-20s %s\n" "Name" "Address"
  printf "%-20s %s\n" "----" "-------"
  local name ip
  while IFS=';' read -r name ip _ _ _; do
    [[ -z "$name" ]] && continue
    printf "%-20s %s\n" "$name" "$ip"
  done <<<"$WG_CLIENTS"
}

# Prints a numbered list of devices and stores the chosen device's name in
# the variable named by $1 (empty if the user cancels or picks invalid).
select_client() {
  local __outvar="$1"
  printf -v "$__outvar" '%s' ""

  if [[ -z "$WG_CLIENTS" ]]; then
    warn "No devices added yet."
    return 1
  fi

  local -a __names=()
  local __cn __cip __count=0
  while IFS=';' read -r __cn __cip _ _ _; do
    [[ -z "$__cn" ]] && continue
    __count=$((__count + 1))
    __names+=("$__cn")
    printf "%2d) %-20s %s\n" "$__count" "$__cn" "$__cip"
  done <<<"$WG_CLIENTS"

  local __choice
  ask __choice "Choose a device number: "
  if ! [[ "$__choice" =~ ^[0-9]+$ ]] || ((__choice < 1 || __choice > __count)); then
    err "Invalid selection."
    return 1
  fi

  printf -v "$__outvar" '%s' "${__names[$((__choice - 1))]}"
}

# Shows a device's full .conf file as plain text, then its QR code.
show_client_details() {
  local dev_name f
  select_client dev_name || return
  [[ -z "$dev_name" ]] && return

  f="${CLIENTS_DIR}/${dev_name}.conf"
  if [[ ! -f "$f" ]]; then
    err "No config file found for this device."
    return
  fi

  echo -e "${C_TITLE}---- ${dev_name}.conf ----${C_RESET}"
  cat "$f"
  echo -e "${C_TITLE}--------------------------${C_RESET}"

  if command -v qrencode &>/dev/null; then
    qrencode -t ansiutf8 <"$f"
  else
    warn "qrencode is not installed — only the text config is shown above."
  fi
}

uninstall_server() {
  local c c2 mgr
  ask c "Are you sure you want to remove WireGuard completely? [y/N]: "
  [[ "$c" =~ ^[Yy]$ ]] || return

  systemctl disable --now "wg-quick@${IFACE}" 2>/dev/null || true

  mgr=$(detect_pkg_mgr)
  case "$mgr" in
    apt) apt-get remove -y wireguard wireguard-tools ;;
    dnf) dnf remove -y wireguard-tools ;;
    yum) yum remove -y wireguard-tools ;;
    pacman) pacman -Rns --noconfirm wireguard-tools ;;
  esac

  ask c2 "Do you also want to wipe the data stored inside this file (keys and device list)? [y/N]: "
  if [[ "$c2" =~ ^[Yy]$ ]]; then
    WG_PUB_IFACE=""
    WG_PUB_IP=""
    WG_PORT=""
    WG_MTU=""
    WG_SERVER_PRIV=""
    WG_SERVER_PUB=""
    WG_CLIENTS=""
    save_state
    rm -rf "$WG_DIR"
    msg "Script data wiped and ${WG_DIR} removed."
  else
    msg "Data kept inside the script so you can reinstall later with the same devices."
  fi
  msg "Uninstall complete."
}

show_menu() {
  echo
  echo -e "${C_TITLE}==== WireGuard Manager (${SUBNET_PREFIX}.0/24) ====${C_RESET}"
  echo -e "${C_TITLE}1) Add a new device${C_RESET}"
  echo -e "${C_TITLE}2) Remove a device${C_RESET}"
  echo -e "${C_TITLE}3) List devices${C_RESET}"
  echo -e "${C_TITLE}4) Show device config / QR code${C_RESET}"
  echo -e "${C_TITLE}5) Uninstall WireGuard completely${C_RESET}"
  echo -e "${C_TITLE}6) Exit${C_RESET}"
  local choice
  ask choice "Choose an option: "
  case "$choice" in
    1) add_client "" ;;
    2) remove_client "" ;;
    3) list_clients ;;
    4) show_client_details ;;
    5) uninstall_server ;;
    6) exit 0 ;;
    *) warn "Invalid option." ;;
  esac
}

print_banner() {
  local line="════════════════════════════════════════"
  echo -e "\033[1m${line}\033[0m"
  echo -e "\033[1m          Byte Balance Technology          \033[0m"
  echo -e "\033[1m${line}\033[0m"
}

main() {
  print_banner
  require_root
  chmod 700 "$SCRIPT_PATH" 2>/dev/null || true

  if [[ -z "$WG_SERVER_PRIV" ]]; then
    msg "No previous installation found inside this script, installing now..."
    install_server
    local ans
    ask ans "Do you want to add the first device now? [Y/n]: "
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      add_client ""
    fi
  elif [[ ! -f "$WG_CONF" ]]; then
    msg "Server and device data are present inside this file but wg0.conf is missing — regenerating it and restoring all devices..."
    install_packages
    write_server_conf
    enable_forwarding
    systemctl enable --now "wg-quick@${IFACE}"
    msg "Restore completed successfully."
    list_clients
  fi

  while true; do
    show_menu
  done
}

main "$@"
