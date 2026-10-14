#!/usr/bin/env bash
# Install or update the host firewall from this directory, with a safety net:
# a timer removes the new rules after 10 minutes unless this script is run
# again with --confirm once you have checked SSH still works from outside.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--confirm" ]]; then
  sudo systemctl stop host-firewall-rollback.timer 2>/dev/null || true
  echo "rollback cancelled; the firewall stays"
  exit 0
fi

sudo nft -c -f "$here/host-firewall.nft"
sudo install -D -m 0644 "$here/host-firewall.nft" /etc/nftables.d/host-firewall.nft
sudo install -m 0644 "$here/host-firewall.service" /etc/systemd/system/host-firewall.service
sudo systemctl daemon-reload
sudo systemctl stop host-firewall-rollback.timer 2>/dev/null || true
sudo systemd-run --unit=host-firewall-rollback --on-active=10min /usr/sbin/nft delete table inet host_firewall
sudo systemctl enable host-firewall.service
sudo systemctl restart host-firewall.service
sudo nft list table inet host_firewall
echo
echo "Applied. It is removed again in 10 minutes unless you check SSH and the sites from"
echo "OUTSIDE this host (a connection from here goes over loopback and proves nothing),"
echo "then run: $0 --confirm"
