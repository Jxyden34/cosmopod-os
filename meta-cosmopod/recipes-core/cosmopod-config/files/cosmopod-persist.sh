#!/bin/sh
set -eu

state=/data/cosmopod
home_source="$state/home"
home_target=/home/cosmopod
network_source="$state/network"
network_target=/etc/NetworkManager/system-connections
hostkeys="$state/ssh"

if ! mountpoint -q /data; then
    echo "Cosmopod persistent /data storage is not mounted" >&2
    exit 1
fi

install -d -m 0700 "$state"
install -d -m 0700 -o cosmopod -g cosmopod "$home_source"
install -d -m 0700 "$network_source" "$hostkeys"
install -d -m 0755 "$home_target" "$network_target"

if [ ! -e "$state/home.initialized" ]; then
    cp -a /usr/share/cosmopod/home-seed/. "$home_source/"
    chown -R cosmopod:cosmopod "$home_source"
    touch "$state/home.initialized"
fi

if ! mountpoint -q "$home_target"; then
    mount --bind "$home_source" "$home_target"
fi

if [ ! -e "$state/network.initialized" ]; then
    cp -a "$network_target"/. "$network_source/" 2>/dev/null || true
    chmod 0700 "$network_source"
    touch "$state/network.initialized"
fi

if ! mountpoint -q "$network_target"; then
    mount --bind "$network_source" "$network_target"
fi

if [ -s "$state/hostname" ]; then
    hostname_value=$(head -n 1 "$state/hostname")
    printf '%s\n' "$hostname_value" > /etc/hostname
    hostname "$hostname_value"
fi

if [ -s "$state/wifi-country" ]; then
    wifi_country=$(head -n 1 "$state/wifi-country")
    case "$wifi_country" in
        [A-Z][A-Z])
            iw reg set "$wifi_country" 2>/dev/null || \
                echo "Cosmopod warning: could not apply Wi-Fi country $wifi_country" >&2
            ;;
        *)
            echo "Cosmopod warning: ignoring invalid persistent Wi-Fi country" >&2
            ;;
    esac
fi

for private_key in \
    "$hostkeys/ssh_host_ed25519_key" \
    "$hostkeys/ssh_host_rsa_key"
do
    if ! [ -s "$private_key" ] || \
        ! ssh-keygen -y -f "$private_key" >/dev/null 2>&1
    then
        echo "Cosmopod SSH host key is missing or invalid: $private_key" >&2
        exit 1
    fi
    public_key="$private_key.pub"
    if [ ! -s "$public_key" ]; then
        public_key_tmp="$public_key.tmp.$$"
        trap 'rm -f "$public_key_tmp"' EXIT HUP INT TERM
        ssh-keygen -y -f "$private_key" > "$public_key_tmp"
        chmod 0644 "$public_key_tmp"
        mv -f "$public_key_tmp" "$public_key"
        trap - EXIT HUP INT TERM
    fi
done

chmod 0600 "$hostkeys"/ssh_host_*_key
chmod 0644 "$hostkeys"/ssh_host_*_key.pub
