#!/bin/sh
# Run on the OAK4 host as root to install the gotee forwarder + its
# watchdog as systemd units. The forwarder auto-starts on boot and on
# Armory hotplug; the watchdog probes it every 30s and auto-recovers
# from silent upstream wedges.
#
# Idempotent: re-running re-installs all units and scripts.
#
# Usage (from your laptop):
#   scp scripts/forwarder.py scripts/oak-gotee.service \
#       scripts/oak-gotee-watchdog.sh scripts/oak-gotee-watchdog.service \
#       scripts/oak-gotee-watchdog.timer scripts/install-systemd.sh \
#       root@<oak-ip>:/tmp/
#   ssh root@<oak-ip> 'sh /tmp/install-systemd.sh'
#
# Or in one shot via deploy.sh: see scripts/deploy.sh --systemd

set -eu

SRCDIR="${SRCDIR:-/tmp}"
# /data is persistent on Luxonis OS RVC4 (ext4 overlay onto /dev/sda11).
# /var/lib looks writable but is overlayed onto /var/volatile/ which is
# tmpfs-backed and wiped at every boot — files placed there survive
# until reboot, then disappear. /etc would also work (also persisted via
# /overlay), but app data belongs under /data.
INSTALL_DIR=/data/oak-gotee
UNIT_DIR=/etc/systemd/system

# One-time migration: previous installs put files under /var/lib/oak-gotee.
# Wipe that stale dir on every install so the systemd unit doesn't fall
# back to it after an OS update / file shuffle.
rm -rf /var/lib/oak-gotee 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
install -m 0644 "$SRCDIR/forwarder.py"             "$INSTALL_DIR/forwarder.py"
install -m 0755 "$SRCDIR/oak-gotee-watchdog.sh"    "$INSTALL_DIR/watchdog.sh"
install -m 0755 "$SRCDIR/oak-gotee-bootstrap.sh"   "$INSTALL_DIR/bootstrap.sh"
install -m 0644 "$SRCDIR/oak-gotee.service"          "$UNIT_DIR/oak-gotee.service"
install -m 0644 "$SRCDIR/oak-gotee-watchdog.service" "$UNIT_DIR/oak-gotee-watchdog.service"
install -m 0644 "$SRCDIR/oak-gotee-watchdog.timer"   "$UNIT_DIR/oak-gotee-watchdog.timer"

# udev rule: triggers bootstrap.sh when usb0 appears. Replaces our
# WantedBy=multi-user.target chain because that doesn't reliably fire
# at boot on this OS image.
install -m 0644 "$SRCDIR/99-oak-gotee.rules" /etc/udev/rules.d/99-oak-gotee.rules
udevadm control --reload-rules

# Stop any manual forwarder we may have left running pre-systemd.
if [ -f /tmp/fwd.pid ]; then
    OLDPID=$(cat /tmp/fwd.pid)
    kill -9 "$OLDPID" 2>/dev/null || true
    rm -f /tmp/fwd.pid
fi

# Disable the OS's NetworkManager-wait-online.service: on this image it
# blocks multi-user.target for ~90s every boot waiting for an "online"
# state we don't need (the LAN is already up, but NM doesn't agree).
# That delayed every WantedBy=multi-user.target unit — including ours —
# by the same 90s, OR caused systemd to never reach multi-user.target
# at all (system stayed in 'starting' state). Disabling it is safe:
# nothing else on this device hard-requires it.
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true

systemctl daemon-reload
# `reenable` rebuilds the WantedBy symlinks from the unit file's current
# [Install] section. Plain `enable` is a no-op when a stale symlink from
# a previous WantedBy target already exists.
systemctl reenable oak-gotee.service
systemctl reenable oak-gotee-watchdog.timer

# Belt-and-suspenders: WantedBy=multi-user.target alone is not honoured
# at boot on this OS image — the .wants symlinks are present and the
# target is reached, but enabled units stay 'inactive (dead)' until
# explicitly started. Hook off oak-agent.service instead, which is the
# OS-provided unit that DOES reliably start at boot (~3s in
# systemd-analyze blame).
mkdir -p /etc/systemd/system/oak-agent.service.d
cat > /etc/systemd/system/oak-agent.service.d/10-oak-gotee.conf <<'EOF'
# Pull the gotee forwarder + its watchdog along with the OAK agent.
# oak-agent.service is what runs the camera apps; the forwarder is
# what their containers need to reach the USB Armory.
[Unit]
Wants=oak-gotee.service oak-gotee-watchdog.timer
EOF

systemctl daemon-reload
systemctl restart oak-gotee.service
# The watchdog itself is oneshot — only the *timer* needs to be enabled
# and started. The timer fires the service every 30s.
systemctl restart oak-gotee-watchdog.timer

sleep 1
echo '--- forwarder status ---'
systemctl --no-pager status oak-gotee.service | head -10
echo '--- watchdog timer ---'
systemctl --no-pager list-timers oak-gotee-watchdog.timer --all | head -5
echo '--- usb0 ---'
ip addr show usb0 | grep -E 'state|inet' || true
echo '--- bridge probe ---'
echo '{"Method":"Sign","Input":"00"}' | nc -w 5 127.0.0.1 4000 \
    || echo '(no reply yet — Armory may not be plugged in or applet not flashed)'
