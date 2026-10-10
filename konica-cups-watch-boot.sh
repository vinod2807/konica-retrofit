#!/bin/sh
# Reconcile Konica USB queues after boot, once CUPS is listening.
# Fixes stale paused/enabled state when udev coldplug raced cupsd
# (udev RUN+=cupsenable fails silently if cupsd is not up yet).
# The watch script itself re-checks real USB presence, so this is safe.
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if lpstat -r >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
/usr/local/bin/konica-cups-watch.sh check >/dev/null 2>&1
