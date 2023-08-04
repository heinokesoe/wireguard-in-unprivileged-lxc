#!/bin/bash

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

function installWireGuard() {
  if [[ -z ${IP} ]]; then
    read -rp "Please enter the ipv4 public address: "
    SERVER_PUB_IP=${REPLY}
  else
    SERVER_PUB_IP=$(echo $IP)
  fi

  SERVER_PUB_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
  
  SERVER_WG_NIC=wg0
  
  SERVER_WG_IPV4=10.66.66.1
  
  SERVER_WG_IPV6=fd42:42:42::1
  
  if [[ -z ${PORT} ]]; then
    read -rp "Please enter the listening port for wireguard: "
    SERVER_PORT=${REPLY}
  else
    SERVER_PORT=$(echo $PORT)
  fi

  CLIENT_DNS_1=1.1.1.1
  
  CLIENT_DNS_2=8.8.8.8

  ALLOWED_IPS="0.0.0.0/0,::/0"

  # Install WireGuard tools and module
  apt-get update
  apt-get install -y wireguard iptables resolvconf qrencode

  # Make sure the directory exists (this does not seem the be the case on fedora)
  mkdir /etc/wireguard >/dev/null 2>&1

  chmod 600 -R /etc/wireguard/

  SERVER_PRIV_KEY=$(wg genkey)
  SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

  # Save WireGuard settings
  echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/wireguard/params

  # Add server interface
  echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

  echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

  # Enable routing on the server
  echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf

  sysctl --system

  systemctl start "wg-quick@${SERVER_WG_NIC}"
  systemctl enable "wg-quick@${SERVER_WG_NIC}"

  # Check if WireGuard is running
  systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
  WG_RUNNING=$?

  # WireGuard might not work if we updated the kernel. Tell the user to reboot
  if [[ ${WG_RUNNING} -ne 0 ]]; then
    echo -e "\n${RED}WARNING: WireGuard does not seem to be running.${NC}"
    echo -e "${ORANGE}You can check if WireGuard is running with: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
    echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_WG_NIC}\", please reboot!${NC}"
    exit 1
  fi
}

function newClient() {
  mkdir -p /root/files
  ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"
  echo ""
  echo "Client configuration"
  echo ""
  echo "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."

  until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
    read -rp "Client name: " -e CLIENT_NAME
    CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/wireguard/${SERVER_WG_NIC}.conf")

    if [[ ${CLIENT_EXISTS} != 0 ]]; then
      echo ""
      echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
      echo ""
    fi
  done

  for DOT_IP in {2..254}; do
    DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf")
    if [[ ${DOT_EXISTS} == '0' ]]; then
      break
    fi
  done

  if [[ ${DOT_EXISTS} == '1' ]]; then
    echo ""
    echo "The subnet configured supports only 253 clients."
    exit 1
  fi

  BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
  until [[ ${IPV4_EXISTS} == '0' ]]; do
    read -rp "Client WireGuard IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
    CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
    IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/32" "/etc/wireguard/${SERVER_WG_NIC}.conf")

    if [[ ${IPV4_EXISTS} != 0 ]]; then
      echo ""
      echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
      echo ""
    fi
  done

  BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
  until [[ ${IPV6_EXISTS} == '0' ]]; do
    read -rp "Client WireGuard IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
    CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"
    IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/128" "/etc/wireguard/${SERVER_WG_NIC}.conf")

    if [[ ${IPV6_EXISTS} != 0 ]]; then
      echo ""
      echo -e "${ORANGE}A client with the specified IPv6 was already created, please choose another IPv6.${NC}"
      echo ""
    fi
  done

  # Generate key pair for the client
  CLIENT_PRIV_KEY=$(wg genkey)
  CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
  CLIENT_PRE_SHARED_KEY=$(wg genpsk)
  
  # Create client file and add the server as a peer
  echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"/root/files/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

  # Add the client as a peer to the server
  echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

  wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

  echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"

  qrencode -t ansiutf8 -l L <"/root/files/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

  echo -e "\n${GREEN}Your client config file is in /root/files/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf in lxc container.\n${NC}"
  echo -e "${GREEN}If you want to it in host, you can run this >>> lxc file pull wireguard-in-lxc/root/files/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf ~/wireguard/files/ <<<\n${NC}"
}

function listClients() {
  NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
  if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
    echo ""
    echo -e "${ORANGE}You have no existing clients!${NC}"
    return 1
  fi
  echo -e "\n${GREEN}List of clients:${NC}"
  grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
  NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
  if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
    echo ""
    echo -e "${ORANGE}You have no existing clients!${NC}"
    return 1
  fi

  echo ""
  echo -e "${GREEN}Select the existing client you want to revoke${NC}"
  grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
  echo ""
  until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
    if [[ ${CLIENT_NUMBER} == '1' ]]; then
      read -rp "Select one client [1]: " CLIENT_NUMBER
    else
      read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
    fi
  done

  # match the selected number to a client name
  CLIENT_NAME=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

  # remove [Peer] block matching $CLIENT_NAME
  sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

  # remove generated client file
  rm -f "/root/files/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

  # restart wireguard to apply changes
  wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")
}

function manageMenu() {
  while true
  do
    unset MENU_OPTION
    unset CLIENT_NAME
    unset CLIENT_NUMBER
    unset IPV4_EXISTS
    unset IPV6_EXISTS
    echo ""
    echo "What do you want to do?"
    echo "     1) Add a new user"
    echo "     2) List all users"
    echo "     3) Revoke existing user"
    echo "     4) Exit"
    echo ""
    until [[ ${MENU_OPTION} =~ ^[1-4]$ ]]; do
      read -rp "Select an option [1-4]: " MENU_OPTION
    done
    case "${MENU_OPTION}" in
      1)
        newClient
        ;;
      2)
        listClients
        ;;
      3)
        revokeClient
        ;;
      4)
        exit 0
        ;;
    esac
  done
}

# Check if WireGuard is already installed and load params
if [[ -e /etc/wireguard/params ]]; then
  echo ""
  echo "Welcome to WireGuard-in-unprivileged-lxc!"
  echo "The git repository is available at: https://github.com/heinokesoe/wireguard-in-unprivileged-lxc"
  source /etc/wireguard/params
  manageMenu
else
  installWireGuard
fi
