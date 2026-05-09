#!/usr/bin/env bash
# Deploy the OAK host-side bits.
#
# Two modes:
#
#   ./scripts/deploy.sh
#     One-shot setup: bring up usb0 and start the forwarder for this
#     boot only. Goes away on reboot. Good for first-time testing.
#
#   ./scripts/deploy.sh --systemd
#     Install the forwarder as a systemd service (oak-gotee.service)
#     that auto-starts on boot, auto-restarts on failure, and is bound
#     to the cdc_ether usb0 device so it follows the Armory in/out.
#     Recommended for any persistent setup.
#
# Env:
#   OAK_IP   IP of the OAK4 (default 192.168.88.236)

set -euo pipefail
OAK_IP="${OAK_IP:-192.168.88.236}"
HERE="$(cd "$(dirname "$0")" && pwd)"

MODE=oneshot
if [ "${1:-}" = "--systemd" ]; then
    MODE=systemd
fi

echo "→ copying scripts to ${OAK_IP}:/tmp/"
scp "$HERE/forwarder.py" "$HERE/oak-host-setup.sh" \
    "$HERE/oak-gotee.service" "$HERE/install-systemd.sh" \
    "$HERE/oak-gotee-watchdog.sh" "$HERE/oak-gotee-watchdog.service" \
    "$HERE/oak-gotee-watchdog.timer" \
    "$HERE/oak-gotee-bootstrap.sh" "$HERE/99-oak-gotee.rules" \
    "root@${OAK_IP}:/tmp/"

if [ "$MODE" = "systemd" ]; then
    echo "→ installing systemd unit on ${OAK_IP}"
    ssh "root@${OAK_IP}" 'sh /tmp/install-systemd.sh'
else
    echo "→ running one-shot setup on ${OAK_IP}"
    ssh "root@${OAK_IP}" 'sh /tmp/oak-host-setup.sh'
fi

echo
echo "Now: from this directory run"
echo "  oakctl app run ."
echo "and open http://${OAK_IP}:8080"
