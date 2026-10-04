#!/bin/bash
# konica-stuck-watch.sh — recover helper jobs wedged with NO PROGRESS.
# A job counts as stuck only when the helper log shows no activity
# ([Job ID] lines: page rendering, backend events) for SILENCE_AFTER
# seconds. Long healthy jobs (100-200 pages) render continuously and are
# never touched, no matter how long they take.
# Two-stage: 1st sighting -> cancel the job, 2nd sighting (still silent
# next run) -> restart legacy-printer-app.
# Only restarts when the USB printer is present; otherwise just logs.
# Log: /var/log/konica-stuck-watch.log
PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/bin:/bin"
export PATH

APP_PRINTER_URI="ipp://localhost:8000/ipp/print/konica206uri"
STATE_FILE="/var/lib/legacy-printer-app/legacy-printer-app.state"
APP_LOG="/var/log/legacy-printer-app.log"
LOG="/var/log/konica-stuck-watch.log"
MARKDIR="/var/run/konica-stuck"
SILENCE_AFTER=600      # 10 min with zero job activity -> stuck
WARN_AFTER=7200        # 2h processing even with progress -> warn only, never cancel
VENDOR="132b"
PRODUCT="232b"

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }
command -v legacy-printer-app >/dev/null 2>&1 || exit 0
[ -f "$STATE_FILE" ] || exit 0
mkdir -p "$MARKDIR" 2>/dev/null

printer_present() {
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

# epoch of last [Job ID] activity in the helper log; empty if none
last_activity() {
  local id="$1" lastline ts epoch
  [ -f "$APP_LOG" ] || return 1
  lastline=$(grep -a -F "[Job $id]" "$APP_LOG" 2>/dev/null | tail -n 1)
  [ -n "$lastline" ] || return 1
  ts=$(echo "$lastline" | sed -n 's/^[^[]*\[\([0-9T:.-]*Z\)\].*/\1/p')
  [ -n "$ts" ] || return 1
  epoch=$(date -d "$ts" +%s 2>/dev/null) || return 1
  echo "$epoch"
}

now=$(date +%s)

while IFS= read -r line; do
  case "$line" in
    *'state="5"'*) ;;
    *) continue ;;
  esac
  id=$(echo "$line" | sed -n 's/.*id="\([0-9]*\)".*/\1/p')
  proc=$(echo "$line" | sed -n 's/.*processing="\([0-9]*\)".*/\1/p')
  name=$(echo "$line" | sed -n 's/.*name="\([^"]*\)".*/\1/p')
  [ -n "$id" ] && [ -n "$proc" ] || continue
  age=$((now - proc))

  last=$(last_activity "$id")
  if [ -n "$last" ]; then
    silence=$((now - last))
  else
    silence=$age
  fi

  if [ "$silence" -gt "$SILENCE_AFTER" ]; then
    if [ -f "$MARKDIR/job-$id" ]; then
      log "STUCK job $id ($name) silent ${silence}s (age ${age}s) — restarting app"
      if printer_present; then
        pkill -f "legacy-printer-app server" 2>/dev/null
        sleep 5
        if pgrep -f "legacy-printer-app server" >/dev/null 2>&1; then
          pkill -9 -f "legacy-printer-app server" 2>/dev/null
          sleep 4
        fi
        /root/Startup/legacy-printer-app-konica.sh >/dev/null 2>&1
        sleep 4
        if pgrep -f "legacy-printer-app server" >/dev/null 2>&1; then
          log "RESTART ok, app running again"
        else
          log "RESTART FAILED, app not running"
        fi
      else
        log "STUCK job $id ($name) silent ${silence}s but printer absent — not restarting"
      fi
      rm -f "$MARKDIR/job-$id"
    else
      log "STUCK job $id ($name) silent ${silence}s (age ${age}s) — canceling"
      legacy-printer-app cancel -u "$APP_PRINTER_URI" -j "$id" >>"$LOG" 2>&1
      touch "$MARKDIR/job-$id"
    fi
  elif [ "$age" -gt "$WARN_AFTER" ]; then
    log "NOTE job $id ($name) processing ${age}s but still active — leaving alone"
  fi
done <"$STATE_FILE"

# clear markers for jobs that are no longer stuck
for m in "$MARKDIR"/job-*; do
  [ -e "$m" ] || continue
  jid=${m##*/job-}
  if ! grep -q "id=\"$jid\".*state=\"5\"" "$STATE_FILE" 2>/dev/null; then
    rm -f "$m"
  fi
done

# keep own log bounded (no logrotate on Puppy)
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  tail -n 2000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

exit 0
