# konica206uri / konica206uri-ppd Unexpected Disable — Investigation Report

Date: 2026-10-08 (IST, UTC+5:30). Host: Puppy-like Linux, no systemd (PID 1 not systemd), CUPS 2.4.16.
Author: OpenCode agent. Purpose: handoff to Claude AI for further root-cause analysis.

## 1. Issue Summary

Two CUPS queues sharing the same legacy backend became disabled simultaneously:

- `konica206uri` (PrinterId 2, UUID 0643a87c-...)
- `konica206uri-ppd` (PrinterId 3, UUID e65026ff-...)

CUPS state (pre-reboot, observed 2026-10-08 14:2x IST):

```
printer konica206uri disabled since Thu 08 Oct 2026 01:14:19 PM IST -
    Paused
printer konica206uri-ppd disabled since Thu 08 Oct 2026 01:14:19 PM IST -
    Paused
```

`/etc/cups/printers.conf` for both:

```
State Stopped
StateMessage Paused
Reason paused
Type 12372
Accepting Yes
DeviceURI ipp://localhost:8000/ipp/print/konica206uri
```

Interpretation: manual pause (`cupsdisable` / IPP `Pause-Printer`), NOT backend-error auto-stop.

User actions in session:
1. Set `konica206-native` as default printer (`lpadmin -d konica206-native`) — verified `system default destination: konica206-native`.
2. Asked who/why disabled, what triggered it, whether native started printing then.
3. Rebooted twice during investigation (boot ~13:53 IST, then ~17:12 IST).

## 2. Environment / Queue Map

`lpstat -p -d -v` (pre-reboot):

| Queue | State | DeviceURI | Notes |
|---|---|---|---|
| CUPS-PDF | idle/enabled | pdf-writer:/export/share/pdf/ | — |
| EPSON_L3260 | idle/enabled | ipp://192.168.1.19:631/ipp/print | network |
| konica206-native | idle/enabled | ipp://localhost:8001/ipp/print/konica206 | NEW stack, `konica206-native` binary, port 8001 |
| konica206uri | disabled/Paused | ipp://localhost:8000/ipp/print/konica206uri | LEGACY stack, `legacy-printer-app`, port 8000 |
| konica206uri-ppd | disabled/Paused | same as above | duplicate queue, same backend |
| KONICA_MINOLTA_206 | idle/enabled (was default) | usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1 | direct USB |

Processes (pre-reboot):

```
cupsd -C /etc/cups/cupsd.conf -s /etc/cups/cups-files.conf
konica206-native server -o server-port=8001 -o listen=localhost ...
legacy-printer-app server -o backend-directory=/usr/local/libexec/konica-backend -o server-port=8000
```

USB device: `132b:232b KONICA MINOLTA 206` on `Bus 002` (`2-2`), serial `A8A6041029423`.

CUPS config notes:
- `cupsd.conf`: `LogLevel warn`, `SystemGroup lpadmin`, `Port 631`, `<Location /admin/conf> AuthType None`, default policy `Order deny,allow` with no auth → unauthenticated localhost admin allowed. No username logged (`localhost - -`).
- No `journald` (`No journal files`), no `/var/log/syslog|auth.log`, no systemd timers.

## 3. Timeline (IST)

All times IST unless noted (IST = UTC+5:30).

- `06/Oct 22:05:09` — last completed `konica206uri` print (job 107, Fellowship form, 2 pages, per `page_log`).
- `08/Oct 12:50–12:55` — burst of `konica206-native` jobs (certificates: MD marks, internship, degree, EPH, IAPA, Axon, KMC, MBBS...).
- `08/Oct 12:53:38` — paired `Pause-Printer`, then `12:54:06` paired `Resume-Printer` (legacy queues flapped during native testing).
- `08/Oct 13:05:41` — `Create-Job + Send-Document` to `KONICA_MINOLTA_206` (direct USB, 3.5 MB); `page_log`: `job 142, PU_marks_card, 1 page, one-sided`.
- `08/Oct 13:14:19` — **the disable event**: 2x `POST /admin/ Pause-Printer successful-ok` (157 bytes + 161 bytes). `StateTime 1791445459` decodes to exactly this second (`date -d @1791445459` = `Thu Oct 8 01:14:19 PM IST 2026`).
- `08/Oct ~13:53` — reboot (cupsd/kthreadd START 13:53, `uptime` 34 min at 14:27, `dmesg -T` boot USB at 13:53:49). Disabled state persisted (stored in `printers.conf`).
- `08/Oct 14:20:13` — first `konica206-native` job after gap (`Print-Job`, 341 KB, gThumb); then 14:21–14:24 burst (chem/physics/bio PDFs, jobs 143–149).
- `08/Oct 14:25:38` — `CUPS-Set-Default successful-ok` (this session's `lpadmin -d konica206-native`).
- `08/Oct ~17:12` — second reboot (user-initiated). `uptime 7 min` at 17:19.
- Post-reboot `17:13:52` — `konica206uri` + `konica206uri-ppd` back to `idle/enabled` (udev add path). Default still `konica206-native`.

Gap: **66 minutes** with zero `konica206-native` activity between disable and next native print. Confirmed in `access_log`, `page_log` (142 → 143), and `/tmp/konica206-native.log` (only `Get-Printer-Attributes` probes at `08:50Z`, first `[Job]` render `Job 64` at `08:54:33Z` = 14:24 IST).

## 4. Key Log Excerpts

### 4.1 `/var/log/cups/access_log` (the event — only 2 lines that minute)

```
localhost - - [08/Oct/2026:13:05:41 +0530] "POST /printers/KONICA_MINOLTA_206 HTTP/1.1" 200 632 Create-Job successful-ok
localhost - - [08/Oct/2026:13:05:41 +0530] "POST /printers/KONICA_MINOLTA_206 HTTP/1.1" 200 3585084 Send-Document successful-ok
localhost - - [08/Oct/2026:13:14:19 +0530] "POST /admin/ HTTP/1.1" 200 157 Pause-Printer successful-ok
localhost - - [08/Oct/2026:13:14:19 +0530] "POST /admin/ HTTP/1.1" 200 161 Pause-Printer successful-ok
localhost - - [08/Oct/2026:14:20:13 +0530] "POST /printers/konica206-native HTTP/1.1" 200 341656 Print-Job successful-ok
```

No `GET` requests in the 5 min before `13:14` (checked `13:08–13:14`). Browser Pause would leave `GET /admin`, `GET /printers/...`. Absence points to CLI/script/direct IPP.

### 4.2 Long pause/resume history (both queues always as pair)

`grep Pause-Printer|Resume-Printer access_log` shows ~20 paired toggles since `03/Oct`:

```
03/Oct 20:19 Pause → Resume
04/Oct 10:58 Resume x2, 10:59 Resume x2, 13:09 Pause x2, 17:27 Resume x2
05/Oct 12:09 Pause x2, 15:27 Resume x2
06/Oct 11:53 Pause x2 … 19:58 Resume … 21:13 Pause/Resume … (many flaps 21:13–21:59)
06/Oct 22:05 Pause x2
07/Oct 07:02 Resume x2, 08:48 Pause x2, 09:55 Resume x2, 10:04 Pause x2, 10:40 Resume x2, 15:42 Resume x2, 17:02 Pause x2, 18:12 Resume x2
08/Oct 10:20 Resume x2, 12:53 Pause x2, 12:54 Resume x2, 13:14 Pause x2  ← final
```

157 bytes = `konica206uri` (12 chars), 161 bytes = `konica206uri-ppd` (16 chars) — inferred from consistent pairing.

### 4.3 `/var/log/cups/error_log` around `13:14`

Nothing at `13:1x` (only routine `BrowseOrder`/`ColorManager` warnings at restarts). No backend failure logged.

### 4.4 `/var/log/cups/page_log`

```
konica206uri ... [06/Oct/2026:22:05:09] ... Fellowship_admission_application_form ... two-sided-long-edge  ← last legacy job
KONICA_MINOLTA_206 root 142 [08/Oct/2026:13:05:52] ... PU_marks_card ...
konica206-native root 143 [08/Oct/2026:14:20:20] ... gThumb job #1 ...
```

### 4.5 `dmesg` (current boot only — pre-reboot lost on reboot, /tmp is tmpfs)

Current boot shows per-job `usblp` claim/release (NOT device unplug):

```
[13:53:49] usblp 2-2:1.1: usblp0: USB Bidirectional printer dev 2 ...
[13:54:08] usblp0: removed
[14:20:18] usblp 2-2:1.1: usblp0: ...
[14:21:20] usblp0: removed
... (repeats per native job 14:21–14:24)
```

True unplug would show `USB disconnect`, not just `usblp0: removed`. Current `udevtrace.log` shows only interface `unbind/bind 2-2:1.1`, never `usb_device remove` during printing.

## 5. Automation Scripts (full source reviewed)

### 5.1 `/usr/local/bin/konica-cups-watch.sh` — PRIME SUSPECT (enable/disable queues)

```bash
#!/bin/bash
# Sync CUPS queue state with Konica 206i USB presence.
# Called by udev on device add/remove and by systemd at boot (check).
QUEUES="konica206uri konica206uri-ppd"
VENDOR="132b"
PRODUCT="232b"
...
enable_queues() { for q in $QUEUES; do cupsenable "$q"; done; }
disable_queues() { for q in $QUEUES; do cupsdisable "$q"; done; }
case "${1:-check}" in
  add|on) enable_queues ;;
  remove|off) disable_queues ;;
  check) konica_present && enable_queues || disable_queues ;;
esac
```

Presence = scan `/sys/bus/usb/devices/*/idVendor|idProduct` for `132b/232b`.

### 5.2 `/etc/udev/rules.d/99-konica206uri-cups.rules`

```
ACTION=="add",    SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="132b/232b/100", RUN+="/usr/local/bin/konica-cups-watch.sh add"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="132b/232b/100", RUN+="/usr/local/bin/konica-cups-watch.sh remove"
```

Note: rule matches `usb_device` remove, NOT interface `unbind` (what per-job `usblp` flap produces). So normal printing should NOT trigger it; only physical unplug/power-off/reset should.

### 5.3 `/usr/local/bin/konica-stuck-watch.sh` — RULED OUT (despite cron firing at 13:14)

- Cron: `*/2 * * * * /usr/local/bin/konica-stuck-watch.sh` (fires at :12, :14, :16… so coincidence).
- Source reviewed (119 lines): only `legacy-printer-app cancel -u ipp://localhost:8000/... -j $id` + `pkill legacy-printer-app` + restart via `/root/Startup/legacy-printer-app-konica.sh`. Zero `cupsdisable`/`Pause-Printer`. Only acts after 600 s silence + marker file two-stage. Log `/var/log/konica-stuck-watch.log` does not exist (never fired or tmpfs).
- `SILENCE_AFTER=600`, `WARN_AFTER=7200`, `VENDOR/PRODUCT` USB guard.

### 5.4 `/etc/cron.daily/konica206-maintenance` — RULED OUT

Header: `Never touches printers, queues, services or the old konica206uri stack.` Only backs up `/var/lib/konica206-native.state` and rotates `/tmp/konica206-native.log`.

### 5.5 `/root/Startup/legacy-printer-app-konica.sh` (boot, called by stuck-watch on restart)

Starts `legacy-printer-app server -o server-port=8000` + `legacy-printer-app add -d konica206uri` if missing. Does not pause/resume CUPS queues.

## 6. Hypotheses (ranked)

1. **udev `remove` → `konica-cups-watch.sh remove` → `cupsdisable` (auto, on USB unplug/power-off after 13:05 direct-USB print).** Fits paired-pause pattern, fits 9-min gap after direct-USB job (user may have powered off/unplugged). Unprovable now: pre-reboot `dmesg` + `/tmp/udevtrace.log` lost on 13:53 reboot; `access_log` identical to manual.
2. **Manual `cupsdisable konica206uri konica206uri-ppd` (or scripted IPP) by user testing migration to `konica206-native`.** Fits no-GET signature, fits daytime testing burst, fits flapping history (12:53–12:54 manual test just before). `/root/.history` shows no `cupsdisable` but history is partial (only `opencode/uptime/...`); no `bash_history` file.
3. **CUPS auto-disable on backend failure — REJECTED.** `Reason paused` + `Accepting Yes` + no `error_log` backend error + both queues same second = manual, not backend.
4. **Web UI Pause — REJECTED.** No GETs.
5. **stuck-watch / maintenance cron — REJECTED** (source review + missing log).

Residual uncertainty is fundamental: at `LogLevel warn`, CUPS logs neither authenticated user, nor client PID, nor `User-Agent`, nor which binary sent `Pause-Printer`.

## 7. Why Still Disabled After First Reboot (root-cause of stale state)

- `printers.conf` persists `State Stopped` across reboot.
- `add` udev rule only fires on plug event; device was already plugged at 13:53 boot, so no `add`.
- Boot-time `check` never ran: comment says “systemd at boot”, but host has no systemd (`systemctl: Host is down`), and `/tmp/bootsysinit.log` (Puppy init) shows `cups: started scheduler` + `konica206-native: started` but no `konica-cups-watch.sh check`.
- Result: stale `Paused` survived until second reboot (~17:12) where device re-enumerated (`Bus 002 Device 003`, new devnum) firing `add` → `cupsenable`, observed `enabled since 17:13:52`.

## 8. Post-Second-Reboot Status (verified 17:19 IST, up 7 min)

```
printer konica206uri is idle. enabled since 17:13:52
printer konica206uri-ppd is idle. enabled since 17:13:52
printer konica206-native is idle. enabled since 14:32:52 (note: timestamp pre-reboot? CUPS preserved)
system default destination: konica206-native  ← persists
Bus 002 Device 003: 132b:232b KONICA MINOLTA 206  ← present
:8000 legacy-printer-app UP, :8001 konica206-native UP, :631 cupsd UP
Manual `konica-cups-watch.sh check` exit 0, no change (already enabled)
```

## 9. What Was Checked (for Claude: avoid re-doing)

- [x] `lpstat -p -d -v -a -l`, `printers.conf`, `cupsd.conf`, `error_log`/`access_log`/`page_log`
- [x] `StateTime 1791445459` decode, `ss -tlnp`, `ps aux`, `lsusb`, `/sys/bus/usb` scan
- [x] Full source of `konica-stuck-watch.sh`, `konica-cups-watch.sh`, `konica206-maintenance`, `legacy-printer-app-konica.sh`
- [x] `crontab -l`, `/var/spool/cron/crontabs/root`, `/etc/cron.daily`, udev rules, `/tmp/udevtrace.log`, `/tmp/bootkernel.log`, `/tmp/bootsysinit.log`, `dmesg -T`, `/var/spool/cups`, `/var/cache/cups`, `/var/lib/legacy-printer-app.state`, `/tmp/konica206-native.log`, `/var/log/legacy-printer-app.log`
- [x] `konica206-native` idle-gap proof (3 log sources), `find` persisted files modified 13:13–13:15 (empty), `/root/.history` review
- [ ] NOT done (destructive/avoided): running `konica-cups-watch.sh remove/add` to reproduce, enabling `LogLevel debug`, physical unplug test

## 10. Open Questions for Claude

1. Given `LogLevel warn`, is there any other persisted artifact (e.g., `/var/log/cups/access_log` byte-count fingerprint, `job.cache`, IPP `requesting-user-name`) that distinguishes `cupsdisable(8)` vs `konica-cups-watch.sh` vs raw IPP? Both ultimately exec `cupsdisable` → same IPP op.
2. Could `cups-browsed`, `ipp2ppd`, or `legacy-printer-app` itself ever emit `Pause-Printer`? No evidence in `ps` or logs, but worth ruling out from binary strings/config.
3. Is the `99-konica206uri-cups.rules` `PRODUCT==132b/232b/100` (bcd 0100) robust to the `usblp` per-job claim/release cycle? Current trace says yes (no `usb_device remove`), but a USB reset during the 13:05 direct-USB job could have synthesized a `remove+add` with `add` lost if cupsd was restarting?
4. Recommended hardening: should `konica-cups-watch.sh` be invoked from Puppy `bootsysinit`/`/root/Startup` `check` to avoid stale-paused-after-reboot? Should `check` be cron-guarded (e.g., every 5 min) or would that mask real unplug?
5. Recommended observability: `LogLevel debug` + `PageLog`/`AccessLog` rotation, `auditd` rule on `cupsd`, or wrapper logging around `cupsdisable` (`/usr/local/bin/cupsdisable` shim) to capture `PPID/caller` for next occurrence?
6. Should duplicate `konica206uri-ppd` be deleted to reduce confusion, given both point to same `ipp://localhost:8000` and `konica206-native` is now default?

## Appendix: Useful Paths

- `/etc/cups/printers.conf`, `/etc/cups/cupsd.conf`, `/etc/cups/cups-files.conf`
- `/var/log/cups/access_log`, `error_log`, `page_log`
- `/var/log/legacy-printer-app.log`, `/tmp/konica206-native.log`, `/tmp/udevtrace.log`, `/tmp/bootkernel.log`, `/tmp/bootsysinit.log`
- `/usr/local/bin/konica-cups-watch.sh`, `konica-stuck-watch.sh`, `/etc/udev/rules.d/99-konica206uri-cups.rules`, `/etc/cron.daily/konica206-maintenance`, `/root/Startup/legacy-printer-app-konica.sh`
- `/var/lib/legacy-printer-app/legacy-printer-app.state`, `/var/lib/konica206-native.state`, `/var/spool/cups/`, `/var/cache/cups/job.cache`
- USB: `/sys/bus/usb/devices/2-2/{idVendor,idProduct,product,manufacturer}`, `lsusb -d 132b:232b`
