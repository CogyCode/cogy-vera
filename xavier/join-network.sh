#!/bin/bash
# Joins this machine to CogyServer's private network. Does nothing if it is
# already on it. The join key is read from a file, so it never appears on a
# command line (ps) or in a log.
#
#   sudo ./join-network.sh --login-server http://<server-ip>:8780 --auth-key <key>
set -euo pipefail

login_server="" auth_key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --login-server) login_server=$2; shift 2 ;;
    --auth-key) auth_key=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if command -v tailscale >/dev/null && [ -n "$(tailscale ip -4 2>/dev/null | head -1)" ]; then
  echo "Already on the private network: $(tailscale ip -4 | head -1)"
  exit 0
fi
[ -n "$login_server" ] && [ -n "$auth_key" ] || {
  echo "usage: sudo $0 --login-server http://<server-ip>:8780 --auth-key <key>" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

if ! command -v tailscale >/dev/null; then
  echo "Installing Tailscale from its signed apt repository"
  . /etc/os-release
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -qq
  apt-get install -y -qq tailscale
fi
systemctl enable --now tailscaled

key_file=$(mktemp)
trap 'rm -f "$key_file"' EXIT
chmod 600 "$key_file"
printf '%s' "$auth_key" > "$key_file"
tailscale up --login-server "$login_server" --auth-key "file:$key_file"
echo "Joined: $(tailscale ip -4 | head -1)"
