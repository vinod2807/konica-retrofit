#!/bin/bash
# Sync CUPS queue state with Konica 206i USB presence.
# Called by udev on device add/remove, by /root/Startup at boot (check),
# and by cron every 5 min (check).
# All entry points reconcile against actual USB state after a settle delay,
# so a lost or reordered udev event self-heals.
# Provenance: script pauses use -r MARKER, so a manual pause (reason "Paused")
# stays distinguishable from the script's. Auto-enable only touches queues
# disabled with MARKER, never deliberate manual pauses.
QUEUES="konica206uri konica206uri-ppd"
VENDOR="132b"
PRODUCT="232b"
MARKER="konica-usb-absent"
LOG="/var/log/konica-cups-watch.log"

PATH="/usr/bin:/usr/sbin:/bin:/sbin"
export PATH

command -v lpstat >/dev/null 2>&1 || exit 0
command -v cupsenable >/dev/null 2>&1 || exit 0
command -v cupsdisable >/dev/null 2>&1 || exit 0

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }

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

# Echoes one of: missing | enabled | disabled:<reason>
queue_state() {
  local q="$1" out second
  out=$(lpstat -p "$q" -l 2>/dev/null) || { echo "missing"; return 0; }
  if echo "$out" | grep -q " is idle\| enabled"; then
    echo "enabled"
  else
    second=$(echo "$out" | sed -n '2p' | sed 's/^[[:space:]]*//')
    echo "disabled:${second}"
  fi
}

enable_queues() {
  local q st reason
  for q in $QUEUES; do
    st=$(queue_state "$q")
    case "$st" in
      missing) log "enable $q skipped (no such queue)"; continue ;;
      enabled) continue ;;
    esac
    reason=${st#disabled:}
    if [ "$reason" = "$MARKER" ]; then
      if cupsenable "$q" >/dev/null 2>&1; then
        log "enable $q ok (was MARKER-disabled)"
      else
        log "enable $q FAILED"
      fi
    else
      log "enable $q skipped (disabled with foreign reason: ${reason:-unknown})"
    fi
  done
}

disable_queues() {
  local q st
  for q in $QUEUES; do
    st=$(queue_state "$q")
    case "$st" in
      missing) log "disable $q skipped (no such queue)"; continue ;;
      enabled) ;;
      *) continue ;; # already disabled: leave reason intact
    esac
    if cupsdisable -r "$MARKER" "$q" >/dev/null 2>&1; then
      log "disable $q ok (reason=$MARKER)"
    else
      log "disable $q FAILED"
    fi
  done
}

MODE="${1:-check}"
# Settle so back-to-back remove/add (printer reset) observes final state.
sleep 2

if konica_present; then
  PRESENT="present"
else
  PRESENT="absent"
fi

log "invoke mode=$MODE pid=$$ ppid=$PPID ACTION=${ACTION:-} DEVPATH=${DEVPATH:-} SEQNUM=${SEQNUM:-} usb=$PRESENT"

if [ "$PRESENT" = "present" ]; then
  enable_queues
else
  case "$MODE" in
    add|on)
      # Trust reality over the stale event: device is gone despite "add".
      log "event=$MODE but USB absent -> disabling"
      disable_queues
      ;;
    *)
      disable_queues
      ;;
  esac
fi

# Keep log bounded (no logrotate on Puppy).
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
  tail -n 2000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

exit 0
