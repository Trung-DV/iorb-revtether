#!/bin/bash
set -euo pipefail

GW=172.20.10.1
SUBNET=172.20.10.0/28
VERBOSE="${VERBOSE:-0}"

log() { echo "[ios-shared] $*" >&2; }

run_bg() {
  local prefix=$1; shift
  "$@" 2>&1 | while IFS= read -r line; do echo "${prefix}${line}" >&2; done &
}

find_phone_iface() {
  local d driver iface
  for d in /sys/class/net/*; do
    iface=$(basename "$d")
    [[ "$iface" == lo ]] && continue
    [[ -e "$d/device/driver" ]] || continue
    driver=$(basename "$(readlink -f "$d/device/driver")")
    [[ "$driver" == cdc_ncm ]] && { echo "$iface"; return 0; }
  done
  return 1
}

wait_phone_iface() {
  local i iface
  for ((i = 1; i <= 60; i++)); do
    iface=$(find_phone_iface) && { echo "$iface"; return 0; }
    [[ "$VERBOSE" == "1" && $((i % 3)) -eq 0 ]] && log "waiting for cdc_ncm ($((i * 2))s)..."
    sleep 2
  done
  return 1
}

start_verbose() {
  local phone=$1 uplink=$2
  (
    while true; do
      sleep 30
      log "--- stats ---"
      ip -br link show "$phone" "$uplink" 2>/dev/null || true
      awk -v p="${phone}:" -v u="${uplink}:" '
        $1 == p { printf "[net] %s rx=%s tx=%s\n", substr($1,1,length($1)-1), $2, $10 }
        $1 == u { printf "[net] %s rx=%s tx=%s\n", substr($1,1,length($1)-1), $2, $10 }
      ' /proc/net/dev
      iptables -t nat -L POSTROUTING -v -n 2>/dev/null | grep MASQUERADE || true
    done
  ) &
  command -v tcpdump >/dev/null && run_bg "[pcap] " \
    tcpdump -i "$phone" -l -n 'udp port 53 or port 67 or port 68 or icmp or arp'
}

main() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  modprobe cdc_ncm 2>/dev/null || true

  lsusb -d 05ac:12a8 >/dev/null || { log "no iPhone — plug in, Trust, orb usb attach"; exit 1; }
  python3 /usb_setup.py

  PHONE=$(wait_phone_iface) || { log "no cdc_ncm interface"; exit 1; }
  UPLINK=$(ip route show default | awk '/default/ {print $5; exit}')

  log "Phone: $PHONE  Uplink: $UPLINK"

  ip link set "$PHONE" up
  ip addr flush dev "$PHONE" 2>/dev/null || true
  ip addr add "${GW}/28" dev "$PHONE"

  iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE
  iptables -C FORWARD -i "$PHONE" -o "$UPLINK" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$PHONE" -o "$UPLINK" -j ACCEPT
  iptables -C FORWARD -i "$UPLINK" -o "$PHONE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$UPLINK" -o "$PHONE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  for proto in udp tcp; do
    iptables -t nat -C PREROUTING -i "$PHONE" -s "$SUBNET" -p "$proto" --dport 53 \
      -j DNAT --to-destination "${GW}:53" 2>/dev/null \
      || iptables -t nat -A PREROUTING -i "$PHONE" -s "$SUBNET" -p "$proto" --dport 53 \
        -j DNAT --to-destination "${GW}:53"
  done

  iptables -t mangle -C POSTROUTING -o "$PHONE" -j CHECKSUM --checksum-fill 2>/dev/null \
    || iptables -t mangle -A POSTROUTING -o "$PHONE" -j CHECKSUM --checksum-fill
  ethtool -K "$PHONE" tx off rx off gso off gro off tso off ufo off 2>/dev/null || true

  local dns_extra=""
  [[ "$VERBOSE" == "1" ]] && dns_extra=$'\nlog-facility=-\nlog-dhcp\nlog-queries'

  cat >/etc/dnsmasq.conf <<EOF
interface=${PHONE}
bind-interfaces
dhcp-range=172.20.10.2,172.20.10.14,255.255.255.240,12h
dhcp-option=option:router,${GW}
dhcp-option=option:dns-server,${GW}
server=8.8.8.8
server=1.1.1.1${dns_extra}
EOF
  if [[ "$VERBOSE" == "1" ]]; then
    run_bg "[dnsmasq] " dnsmasq --keep-in-foreground
  else
    dnsmasq --keep-in-foreground &
  fi

  [[ "$VERBOSE" == "1" ]] && start_verbose "$PHONE" "$UPLINK"

  log "Router ready — Wi-Fi/cellular off, replug USB if needed"
  wait
}

main "$@"
