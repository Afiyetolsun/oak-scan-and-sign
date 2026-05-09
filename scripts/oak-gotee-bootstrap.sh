#!/bin/sh
# oak-gotee-bootstrap.sh — kicks oak-gotee.service + its watchdog timer
# once systemd is ready to accept start commands.
#
# Triggered by a udev rule when usb0 (the cdc_ether interface for the
# USB Armory) is added by the kernel. udev's RUN+= calls
# `systemd-run --no-block` to spawn this script as a transient unit so
# it doesn't block udev event processing — meaning we can sleep here
# as long as we need without holding up the whole device pipeline.
#
# Why this exists at all: on this OS image the standard
# WantedBy=multi-user.target chain is broken — wants symlinks are
# correctly placed and the target reaches, but enabled units stay
# 'inactive (dead)' until something explicitly starts them. udev rules
# fire deterministically when the device appears (boot or hotplug), but
# at *boot* time udev fires before systemd has finished loading user
# units, so a direct `systemctl start` from the rule fails. This wrapper
# polls until the manager accepts the start.

set -u

# Cap the total wait at a minute — usb0 binds within seconds of boot;
# if systemd isn't accepting commands a minute later, something else
# is broken and we want to stop spinning.
DEADLINE=$(( $(date +%s) + 60 ))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if systemctl start oak-gotee.service oak-gotee-watchdog.timer 2>/dev/null; then
        # `start` is a no-op if a unit is already running, so it's safe
        # to fire on every udev add (e.g. Armory hotplug after first boot).
        logger -t oak-gotee-bootstrap "started oak-gotee.service + oak-gotee-watchdog.timer"
        exit 0
    fi
    sleep 2
done

logger -t oak-gotee-bootstrap "gave up after 60s — systemd never became ready"
exit 1
