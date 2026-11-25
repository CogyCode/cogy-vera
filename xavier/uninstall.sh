#!/bin/bash
# Removes Vera's services and firewall rule. The machine stays on the private
# network, and other services (such as cogy-system1) are not touched.
#
#   sudo ./uninstall.sh                 services and firewall rule
#   sudo ./uninstall.sh --remove-files  also the code, model, source and logs
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. config/settings.env

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
remove_files=0
case "${1:-}" in
  "") ;;
  --remove-files) remove_files=1 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

for svc in "$SERVICE_NAME" "$MODEL_SERVICE_NAME" "$FIREWALL_SERVICE_NAME"; do
  systemctl disable --now "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/$svc.service"
done
systemctl daemon-reload
echo "Services and firewall rule removed"

if [ "$remove_files" -eq 1 ]; then
  rm -rf "$PREFIX" "$DATA_DIR" "$LOG_DIR"
  userdel "$SERVICE_USER" 2>/dev/null || true
  echo "Removed $PREFIX, $DATA_DIR, $LOG_DIR and the $SERVICE_USER account"
fi
