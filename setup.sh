#!/bin/bash

setup_log="$(mktemp -t setup_logXXX)"
red="\033[1;31m"
green="\033[1;32m"
cyan="\033[0;36m"
normal="\033[0m"

title() {
  clear
  echo -ne "${cyan}
################################################################################
#                                                                              #
#   This is automated shell script to install wireguard in unprivileged lxc    #
#                                                                              #
#                                    By                                        #
#                                                                              #
#                               Hein Oke Soe                                   #
#                                                                              #
################################################################################
${normal}
"
}

display_usage() {
  cat <<EOF

Usage: wireguard [--public-ipv4 <ipv4 address>] [--port <port>]
       wireguard [--remove]

  --public-ipv4   The public ipv4 address to be used in wireguard
  --port          The port number to listen in wireguard
  --remove        Remove and clean up

EOF
}

spin() {
  local i=0
  local sp="/-\|"
  local n=${#sp}
  printf " "
  sleep 0.2
  while true; do
    printf "\b${cyan}%s${normal}" "${sp:i++%n:1}"
    sleep 0.2
  done
}

log() {
  exec 3>&1 4>&2
  trap 'exec 2>&4 1>&3' 0 1 2 3
  exec 1>>"$setup_log" 2>&1
  echo -e "\n$1\n"
}

run_step() {
  local msg="$1"
  local func=$2
  local pos
  IFS='[;' read -p $'\e[6n' -d R -a pos -rs
  local current_row=${pos[1]}
  local current_col=${pos[2]}
  printf "${cyan}$msg${normal}\033[$current_row;50H"
  spin &
  spinpid=$!
  trap 'kill $spinpid' SIGTERM SIGKILL
  $func "$msg" &>/dev/null
  if [[ $? -eq 0 ]]; then
    kill $spinpid
    printf "\b \t\t${cyan}[OK]${normal}\n"
  else
    kill $spinpid
    printf "\b \t\t${red}[Failed]${normal}\n"
    printf "\n${red}Sorry! $msg went wrong. See full log at $setup_log ${normal}\n\n"
    exit 1
  fi
}

check_command() {
  check_command_result=()
  for i in $@; do
    if ! command -v $i &>/dev/null; then
      check_command_result+=("$i")
    fi
  done
}

is_valid_port() {
  (( 0 < "$1" && "$1" <= 65535 ))
}

parse_flags() {
  if [[ $# -eq 1 && "$1" == "--remove" ]]; then
    if lxc ls | grep wireguard &>/dev/null ; then
      remove
    else
      echo -e "\n${red}Wireguard has not been installed yet.${normal}\n" >&2
      exit 1
    fi
  fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      --public-ipv4)
        FLAGS_IP="$2"
        shift
        shift
        ;;
      --port)
        FLAGS_PORT="$2"
        if ! is_valid_port "${FLAGS_PORT}"; then
          echo -e "\n${red}Invalid value for port: ${FLAGS_PORT}${normal}\n" >&2
          exit 1
        fi
        shift
        shift
        ;;
      *|-*|--*)
        if ! [[ $1 == "-h" || $1 == "--help" ]]; then
          echo -e "\n${red}Unsupported flag${normal}" >&2
        fi
        display_usage >&2
        exit 1
        ;;
    esac
  done
}

get_user_input() {
  if [[ -z ${FLAGS_IP} ]]; then
    ip=$(curl -s ip.me)
    read -rp "Please enter the ipv4 public address: " -e -i $ip ip
  else
    ip=${FLAGS_IP}
  fi
  if [[ -z ${FLAGS_PORT} ]]; then
    port=56780
    read -rp "Please enter the listening port for wireguard: " -e -i $port port
  else
    port=${FLAGS_PORT}
  fi
  read -srp "Please enter sudo password to create character device and change permission: " password
  echo
}

prepare() {
  log "$1"
  SUBUID=$(cat /etc/subuid | grep $USER | cut -d':' -f2)
  mkdir -p ~/wireguard/{net,files}
  echo $password | sudo -S mknod ~/wireguard/net/tun c 10 200
  echo $password | sudo -S chown $SUBUID:$SUBUID ~/wireguard/net/tun
  curl -sL https://raw.githubusercontent.com/heinokesoe/wireguard-in-unprivileged-lxc/main/wireguard.sh -o ~/wireguard/wireguard.sh
}

initialize() {
  log "$1"
  lxc init images:ubuntu/jammy wireguard-in-lxc \
    -c boot.autostart=true \
    -c linux.kernel_modules=ip_tables,ip6_tables
  lxc config set wireguard-in-lxc raw.lxc "lxc.mount.entry = /home/$USER/wireguard/net dev/net none bind,create=dir"
  lxc config set wireguard-in-lxc raw.lxc "lxc.cgroup.devices.allow = c 10:200 rwm"
  lxc config device add wireguard-in-lxc port proxy listen=udp:0.0.0.0:$port connect=udp:0.0.0.0:$port
}

install_wireguard() {
  log "$1"
  lxc start wireguard-in-lxc
  lxc file push ~/wireguard/wireguard.sh wireguard-in-lxc/root/
  lxc exec --env PORT=$port --env IP=$ip wireguard-in-lxc -- bash wireguard.sh
}

remove_wireguard_lxc_container() {
  log "$1"
  lxc delete -f wireguard-in-lxc
}

remove_wireguard_directory() {
  log "$1"
  echo $password | sudo -S rm -r ~/wireguard
}

remove() {
  read -srp "Please enter sudo password to remove wireguard directory: " password
  echo
  run_step "Removing wireguard lxc container" "remove_wireguard_lxc_container"
  run_step "Removing wireguard directory" "remove_wireguard_directory"
  printf "\n${green}Wireguard has been successfully removed.${normal}\n\n"
  exit 0
}

finish() {
  printf "\n\n${green}Wireguard has been successfully installed.${normal}\n"
  printf "\n${green}When you want to add clients or manage wireguard, run 'wireguard' again.${normal}\n\n"
}

main() {
  check_command curl lxc
  if [[ ${#check_command_result[@]} -ne 0 ]]; then
    echo -e "\n\n${red}${check_command_result[@]} need to be installed first.${normal}\n\n"
    exit 1
  fi
  parse_flags "$@"
  if lxc ls | grep wireguard-in-lxc &>/dev/null ; then
    lxc exec wireguard-in-lxc bash wireguard.sh
    exit 0
  fi
  title
  get_user_input
  run_step "Preparing requirements on host" "prepare"
  run_step "Initializing lxc container" "initialize"
  run_step "Installing wireguard in lxc container" "install_wireguard"
  finish
  exit 0
}

main $@
