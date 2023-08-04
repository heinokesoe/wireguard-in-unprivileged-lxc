# Wireguard in Unprivileged LXC

This is the wireguard server installed in unprivileged lxc container.

## Prerequisites
- LXD
- curl

## Install

As this is for unprivileged lxc, run this as normal user.\
But you will be prompted to put sudo password as sudo is required to create character device and change permission.\
When you run the first time, it will install wireguard in unprivileged lxc container.
```
curl -sL https://raw.githubusercontent.com/heinokesoe/wireguard-in-unprivileged-lxc/main/setup.sh -o ~/.local/bin/wireguard
chmod +x ~/.local/bin/wireguard
wireguard
```
You can specify flags to customize the setup. For example, to use ipv4 address 10.10.100.100 and the port 56780 for listening, you can run:
```
wireguard --public-ipv4 10.10.100.100 --port 56780
```
If you want to add, list or revoke clients, run
```
wireguard
```
again.

## Remove

To remove and clean up, run this:
```
wireguard --remove
```
