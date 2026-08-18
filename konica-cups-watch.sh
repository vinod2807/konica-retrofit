#!/bin/bash
# Sync CUPS queue state with Konica 206i USB presence.
# Called by udev on device add/remove and by systemd at boot (check).
QUEUES="konica206uri konica206uri-ppd"
VENDOR="132b"
PRODUCT="232b"

# udev/systemd do not guarantee an interactive-shell PATH.
PATH="/usr/bin:/usr/sbin:/bin:/sbin"
export PATH

command -v lpstat >/dev/null 2>&1 || exit 0
command -v cupsenable >/dev/null 2>&1 || exit 0
command -v cupsdisable >/dev/null 2>&1 || exit 0

konica_present() {
  local v p
  for v in /sys/bus/usb/devices/*/idVendor; do
    [ -f "$v" ] || continue
    [ "$(cat "$v" 2>/dev/null)" = "$VENDOR" ] || continue
    p="${v%/idVendor}/idProduct"
    if [ -f "$p" ] && [ "$(cat "$p" 2>/dev/null)" = "$PRODUCT" ]; then
      return 0
    fi
  done
  return 1
}

enable_queues() {
  local q
  for q in $QUEUES; do
    lpstat -p "$q" >/dev/null 2>&1 || continue
    cupsenable "$q" >/dev/null 2>&1
  done
}

disable_queues() {
  local q
  for q in $QUEUES; do
    lpstat -p "$q" >/dev/null 2>&1 || continue
    cupsdisable "$q" >/dev/null 2>&1
  done
}

case "${1:-check}" in
  add|on)
    enable_queues
    ;;
  remove|off)
    disable_queues
    ;;
  check)
    if konica_present; then
      enable_queues
    else
      disable_queues
    fi
    ;;
  *)
    echo "Usage: $0 {add|remove|on|off|check}" >&2
    exit 2
    ;;
esac
