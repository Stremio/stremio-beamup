#!/usr/bin/env bash

set -euo pipefail

INSTALL_BOOT_SERVICE=1
if [ "${1:-}" = "--no-service-install" ]; then
  INSTALL_BOOT_SERVICE=0
  shift
fi

if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--no-service-install]" >&2
  exit 1
fi

SCRIPT_PATH="$(readlink -f "$0")"
BOOT_SERVICE_NAME="beamup-local-dns-init.service"
BOOT_SERVICE_PATH="/etc/systemd/system/${BOOT_SERVICE_NAME}"

if [ -z "${LOCAL_BEAMUP_DOMAIN:-}" ] && [ -t 0 ]; then
  read -r -p "Local Beamup domain [beamup.test]: " LOCAL_BEAMUP_DOMAIN
fi
LOCAL_BEAMUP_DOMAIN="${LOCAL_BEAMUP_DOMAIN:-beamup.test}"
if [ -z "${BEAMUP_DNS_MODE:-}" ] && [ -t 0 ]; then
  echo "Routing mode:" >&2
  echo "  1) proxy  - DNS resolves to this host, iptables DNATs 80/443/22 to deployer/swarm" >&2
  echo "  2) direct - DNS points clients straight at the deployer and swarm VM IPs" >&2
  read -r -p "Choose [1]: " _mode_choice
  case "${_mode_choice,,}" in
    2|direct) BEAMUP_DNS_MODE=direct ;;
    *)        BEAMUP_DNS_MODE=proxy ;;
  esac
fi
BEAMUP_DNS_MODE="${BEAMUP_DNS_MODE:-proxy}"
case "${BEAMUP_DNS_MODE}" in
  proxy|direct) ;;
  *) echo "Invalid BEAMUP_DNS_MODE: '${BEAMUP_DNS_MODE}' (expected 'proxy' or 'direct')" >&2; exit 1 ;;
esac
DNS_UPSTREAM="${DNS_UPSTREAM:-1.1.1.1}"
HOST_LAN_IFACE="${HOST_LAN_IFACE:-$(ip route show default | awk 'NR==1 {print $5}')}"
HOST_LAN_IP="${HOST_LAN_IP:-$(ip -4 -o addr show dev "${HOST_LAN_IFACE}" | awk '{print $4}' | cut -d/ -f1 | head -n1)}"
if [[ "${HOST_LAN_IP}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  OCT1="${BASH_REMATCH[1]}"
  OCT2="${BASH_REMATCH[2]}"
  OCT3="${BASH_REMATCH[3]}"
  OCT4="${BASH_REMATCH[4]}"
  if [ "${OCT4}" -lt 254 ]; then
    DEFAULT_A_RECORD_IP="${OCT1}.${OCT2}.${OCT3}.$((OCT4 + 1))"
  else
    DEFAULT_A_RECORD_IP="${OCT1}.${OCT2}.${OCT3}.$((OCT4 - 1))"
  fi
else
  DEFAULT_A_RECORD_IP=""
fi
A_RECORD_IP="${A_RECORD_IP:-${DEFAULT_A_RECORD_IP}}"
SWARM_VM_NAME="${SWARM_VM_NAME:-stremio-beamup-swarm-0}"
TARGET_IP="${TARGET_IP:-$(virsh domifaddr "${SWARM_VM_NAME}" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1)}"
DEPLOYER_VM_NAME="${DEPLOYER_VM_NAME:-stremio-addon-deployer}"
DEPLOYER_IP="${DEPLOYER_IP:-$(virsh domifaddr "${DEPLOYER_VM_NAME}" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1)}"

if ! command -v dnsmasq >/dev/null 2>&1; then
  echo "dnsmasq is not installed. Run ./local-deployment/server-init.sh first." >&2
  exit 1
fi

if [ -z "${HOST_LAN_IP}" ]; then
  echo "Could not detect main VM LAN IP. Set HOST_LAN_IP and retry." >&2
  exit 1
fi

if [ -z "${DNS_UPSTREAM}" ]; then
  echo "DNS_UPSTREAM is empty. Set DNS_UPSTREAM and retry." >&2
  exit 1
fi

if [ -z "${TARGET_IP}" ]; then
  echo "Could not detect target IP for ${SWARM_VM_NAME}. Set TARGET_IP and retry." >&2
  exit 1
fi

if [ "${BEAMUP_DNS_MODE}" = "proxy" ] && [ -z "${A_RECORD_IP}" ]; then
  echo "Could not determine A record IP for a.${LOCAL_BEAMUP_DOMAIN}. Set A_RECORD_IP and retry." >&2
  exit 1
fi

if [ -z "${DEPLOYER_IP}" ]; then
  echo "Could not detect deployer IP for ${DEPLOYER_VM_NAME}. Set DEPLOYER_IP and retry." >&2
  exit 1
fi

ensure_nat_first() {
  local chain="$1"
  shift
  while sudo iptables -t nat -C "${chain}" "$@" 2>/dev/null; do
    sudo iptables -t nat -D "${chain}" "$@"
  done
  sudo iptables -t nat -I "${chain}" 1 "$@"
}

remove_nat_rule_all() {
  local chain="$1"
  shift
  while sudo iptables -t nat -C "${chain}" "$@" 2>/dev/null; do
    sudo iptables -t nat -D "${chain}" "$@"
  done
}

ensure_forward_first() {
  while sudo iptables -C FORWARD "$@" 2>/dev/null; do
    sudo iptables -D FORWARD "$@"
  done
  sudo iptables -I FORWARD 1 "$@"
}

remove_forward_rule_all() {
  while sudo iptables -C FORWARD "$@" 2>/dev/null; do
    sudo iptables -D FORWARD "$@"
  done
}

install_boot_service() {
  echo "Installing boot persistence service: ${BOOT_SERVICE_NAME}"
  sudo tee "${BOOT_SERVICE_PATH}" >/dev/null <<EOF
[Unit]
Description=Restore Beamup local DNS/NAT configuration
Wants=network-online.target
After=network-online.target libvirtd.service
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=LOCAL_BEAMUP_DOMAIN=${LOCAL_BEAMUP_DOMAIN}
Environment=BEAMUP_DNS_MODE=${BEAMUP_DNS_MODE}
ExecStart=/usr/bin/env bash ${SCRIPT_PATH} --no-service-install
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "${BOOT_SERVICE_NAME}" >/dev/null
}

if [ "${BEAMUP_DNS_MODE}" = "proxy" ]; then
  if ! ip -4 -o addr show dev "${HOST_LAN_IFACE}" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${A_RECORD_IP}"; then
    echo "Adding ${A_RECORD_IP}/32 to ${HOST_LAN_IFACE} for a.${LOCAL_BEAMUP_DOMAIN}"
    sudo ip addr add "${A_RECORD_IP}/32" dev "${HOST_LAN_IFACE}"
  fi

  echo "Configuring dnsmasq (proxy): ${LOCAL_BEAMUP_DOMAIN}, www.${LOCAL_BEAMUP_DOMAIN}, a.${LOCAL_BEAMUP_DOMAIN} -> ${A_RECORD_IP}; wildcard -> ${HOST_LAN_IP}"
  sudo tee /etc/dnsmasq.d/beamup-local.conf >/dev/null <<EOF
listen-address=127.0.0.1,${HOST_LAN_IP}
bind-interfaces
no-resolv
server=${DNS_UPSTREAM}
domain-needed
bogus-priv
address=/a.${LOCAL_BEAMUP_DOMAIN}/${A_RECORD_IP}
address=/${LOCAL_BEAMUP_DOMAIN}/${A_RECORD_IP}
address=/www.${LOCAL_BEAMUP_DOMAIN}/${A_RECORD_IP}
address=/.${LOCAL_BEAMUP_DOMAIN}/${HOST_LAN_IP}
EOF
else
  echo "Configuring dnsmasq (direct): ${LOCAL_BEAMUP_DOMAIN}, www.${LOCAL_BEAMUP_DOMAIN}, a.${LOCAL_BEAMUP_DOMAIN} -> ${DEPLOYER_IP}; wildcard -> ${TARGET_IP}"
  sudo tee /etc/dnsmasq.d/beamup-local.conf >/dev/null <<EOF
listen-address=127.0.0.1,${HOST_LAN_IP}
bind-interfaces
no-resolv
server=${DNS_UPSTREAM}
domain-needed
bogus-priv
host-record=a.${LOCAL_BEAMUP_DOMAIN},${DEPLOYER_IP}
host-record=${LOCAL_BEAMUP_DOMAIN},${DEPLOYER_IP}
host-record=www.${LOCAL_BEAMUP_DOMAIN},${DEPLOYER_IP}
address=/*.${LOCAL_BEAMUP_DOMAIN}/${TARGET_IP}
EOF
fi
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

if [ "${BEAMUP_DNS_MODE}" = "proxy" ]; then
  echo "Enabling IPv4 forwarding"
  sudo tee /etc/sysctl.d/99-beamup-local.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
EOF
  sudo sysctl -p /etc/sysctl.d/99-beamup-local.conf >/dev/null

  # Remove old broad DNAT rules that break outbound HTTP/HTTPS from nested VMs.
  remove_nat_rule_all PREROUTING -p tcp --dport 80 -j DNAT --to-destination "${TARGET_IP}:80"
  remove_nat_rule_all PREROUTING -p tcp --dport 443 -j DNAT --to-destination "${TARGET_IP}:443"

  ensure_forward_first -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  echo "Adding iptables forwarding from main VM to ${TARGET_IP}"
  for port in 80 443; do
    ensure_nat_first PREROUTING -d "${HOST_LAN_IP}" -p tcp --dport "${port}" -j DNAT --to-destination "${TARGET_IP}:${port}"
    ensure_forward_first -p tcp -d "${TARGET_IP}" --dport "${port}" -j ACCEPT
  done

  echo "Adding iptables forwarding for ${LOCAL_BEAMUP_DOMAIN}, www.${LOCAL_BEAMUP_DOMAIN} -> ${DEPLOYER_IP} (80/443)"
  for port in 80 443; do
    ensure_nat_first PREROUTING -d "${A_RECORD_IP}" -p tcp --dport "${port}" -j DNAT --to-destination "${DEPLOYER_IP}:${port}"
    ensure_nat_first OUTPUT -d "${A_RECORD_IP}" -p tcp --dport "${port}" -j DNAT --to-destination "${DEPLOYER_IP}:${port}"
    ensure_forward_first -p tcp -d "${DEPLOYER_IP}" --dport "${port}" -j ACCEPT
  done

  echo "Adding iptables forwarding for a.${LOCAL_BEAMUP_DOMAIN}:22 -> ${DEPLOYER_IP}:22"
  ensure_nat_first PREROUTING -d "${A_RECORD_IP}" -p tcp --dport 22 -j DNAT --to-destination "${DEPLOYER_IP}:22"
  ensure_nat_first OUTPUT -d "${A_RECORD_IP}" -p tcp --dport 22 -j DNAT --to-destination "${DEPLOYER_IP}:22"
  ensure_forward_first -p tcp -d "${DEPLOYER_IP}" --dport 22 -j ACCEPT
else
  echo "Direct mode: removing any proxy-mode iptables rules and virtual IP"
  for port in 80 443; do
    remove_nat_rule_all PREROUTING -d "${HOST_LAN_IP}" -p tcp --dport "${port}" -j DNAT --to-destination "${TARGET_IP}:${port}"
    remove_forward_rule_all -p tcp -d "${TARGET_IP}" --dport "${port}" -j ACCEPT
    if [ -n "${A_RECORD_IP}" ]; then
      remove_nat_rule_all PREROUTING -d "${A_RECORD_IP}" -p tcp --dport "${port}" -j DNAT --to-destination "${DEPLOYER_IP}:${port}"
      remove_nat_rule_all OUTPUT -d "${A_RECORD_IP}" -p tcp --dport "${port}" -j DNAT --to-destination "${DEPLOYER_IP}:${port}"
    fi
    remove_forward_rule_all -p tcp -d "${DEPLOYER_IP}" --dport "${port}" -j ACCEPT
  done
  if [ -n "${A_RECORD_IP}" ]; then
    remove_nat_rule_all PREROUTING -d "${A_RECORD_IP}" -p tcp --dport 22 -j DNAT --to-destination "${DEPLOYER_IP}:22"
    remove_nat_rule_all OUTPUT -d "${A_RECORD_IP}" -p tcp --dport 22 -j DNAT --to-destination "${DEPLOYER_IP}:22"
    if ip -4 -o addr show dev "${HOST_LAN_IFACE}" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${A_RECORD_IP}"; then
      sudo ip addr del "${A_RECORD_IP}/32" dev "${HOST_LAN_IFACE}"
    fi
  fi
  remove_forward_rule_all -p tcp -d "${DEPLOYER_IP}" --dport 22 -j ACCEPT
fi

if [ "${INSTALL_BOOT_SERVICE}" -eq 1 ]; then
  install_boot_service
fi

echo "Local access configured (mode: ${BEAMUP_DNS_MODE})."
if [ "${BEAMUP_DNS_MODE}" = "proxy" ]; then
  echo "${LOCAL_BEAMUP_DOMAIN}, www.${LOCAL_BEAMUP_DOMAIN}, a.${LOCAL_BEAMUP_DOMAIN} -> ${A_RECORD_IP}"
  echo "  ${LOCAL_BEAMUP_DOMAIN}, www.${LOCAL_BEAMUP_DOMAIN} forwarded to ${DEPLOYER_IP}:80/443"
  echo "  a.${LOCAL_BEAMUP_DOMAIN} forwarded to ${DEPLOYER_IP}:22"
else
  echo "${LOCAL_BEAMUP_DOMAIN}, www.${LOCAL_BEAMUP_DOMAIN}, a.${LOCAL_BEAMUP_DOMAIN} -> ${DEPLOYER_IP} (direct)"
  echo "  wildcard *.${LOCAL_BEAMUP_DOMAIN} -> ${TARGET_IP} (direct)"
  echo "  (clients must have a route to ${DEPLOYER_IP} and ${TARGET_IP})"
fi
echo "Other domains forwarded to upstream DNS ${DNS_UPSTREAM}"
echo "Use domains like anything.${LOCAL_BEAMUP_DOMAIN} and point your client DNS to ${HOST_LAN_IP}."
echo "Boot persistence enabled via ${BOOT_SERVICE_NAME}."
