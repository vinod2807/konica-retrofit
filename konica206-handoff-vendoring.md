# konica206-native — complete handoff for Phase 4 (vendoring)

Companion to `docs/` in `https://github.com/vinod2807/konica206-native`.
Purpose: give an AI reviewer everything needed to design Phase 4
(vendor `libpappl` + `libcups`) without re-discovering history.

## 1. Machine and printer

- Host: shop machine, x86_64, Linux 7.0.14, Ubuntu 26.04-ish userland
  (Puppy-style: PID 1 is busybox init, but `systemd` unit files,
  `udev`, `cron.daily` exist; **no `crond` running**, no `logrotate`
  binary, no `ss` binary — use `/proc` and `curl` for checks).
- Printer: Konica Minolta bizhub 206, GDI-only, USB `132b:232b`,
  serial `A8A6041029423`, printer-class **interface 1** (exclusive —
  only one stack may hold it at a time).
- Device ID: `MFG:KONICA MINOLTA;CMD:GDI,XPS;MDL:206;PRINTER` (no PCL,
  no PostScript — proven by failed generic-PCL and Konica-PCL tests;
  see `docs/pcl-test-report.md`).
- Hard USB rule: writes **≤8192 bytes** per bulk transfer; ~61 KB single
  writes knock the printer off the bus. Never "optimise" this
  (`KONICA_CHUNK`, `KONICA_TIMEOUT_MS=10000`, `KONICA_MAX_STALLS=6`).

## 2. Two printing stacks (both live)

| | `konica206uri` (old) | `konica206-native` (new) |
|---|---|---|
| Server | `legacy-printer-app` 1.0b2 (distro pkg) `:8000` | own binary, `:8001` |
| Driver | retrofit `KonicaMinolta-206-fullbleed.ppd` via pappl-retrofit | built-in `konica-bizhub-206` |
| Renderer | `245igdirf` + private libs | same filter + libs |
| USB | external custom backend | same 8K logic built in |
| CUPS queues | `konica206uri` (driverless shim, 24 sizes) | `konica206-native` (generated PPD, 8 sizes, no ISOB) |
| Default printer | `KONICA_MINOLTA_206` (classic USB queue, same GDI filter) | — |
| Stuck recovery | `konica-stuck-watch.sh` + service supervision | in-app watchdog (600 s silence → cancel) |

## 3. What was done (chronological)

1. **PCL investigation** — generic PCL5 (`ljet4`), PCL6 (`pxlmono`),
   raw PCL, and Konica's own `206 PCL` driver all transfer cleanly over
   USB but print nothing (GDI-only device). GDI control prints.
   Report: `docs/pcl-test-report.md`.
2. **Stock GDI test** — Konica `BH226GDILinux` `206gdi` prints simplex;
   lacks duplex UI (retrofit PPD provides it). Temp queues removed.
3. **Native app built** (from `konica206-native.tar.gz`): PAPPL wrapper
   around `245igdirf` + ported libusb sender. Stages 0–4 passed
   (build, offline render, direct USB page, IPP prototype on `:8001`,
   CUPS proxy queue). Build needed a project-local `pkg-config →
   pkgconf` symlink (Ubuntu ships only `pkgconf`).
4. **Wine/Adobe saga** — Adobe crashed on the new queue (divide-by-zero
   in Wine `gdi32`): root cause was non-standard `ISOB4/ISOB5` size
   names. Removed from queue PPD; Adobe prints, preview back to 100%.
   Also added `ImageableArea` margins + translated size names along the
   way (harmless, kept).
5. **Watchdog** — in-app stuck-job detection committed, live, proven
   passive on healthy jobs (`test/test_watchdog.c`, `make
   check-watchdog`).
6. **Tray mapping** — IPP `auto/tray-1/by-pass-tray` → PPD
   `Auto/Tray1/Bypass`, verified on paper both trays.
7. **Duplex saga (biggest)** — builtin duplex bound short-edge while
   system bound long-edge. Controlled A/B (power-cycles, byte captures)
   showed headers/PJL/pixels equivalent; external review spotted the
   cause: `pdftoraster` rotates even pages 180° per PPD
   `*cupsBackSide: Rotated`, builtin didn't. Two earlier red herrings
   were fixed for real along the way (raster `MediaPosition` was 0 not
   3; `ImagingBoundingBox`/scale were zero). Rotation implemented per
   rule table (Rotated/ManualTumble/Flipped), paper-proven long-edge.
   Full record: `docs/duplex-investigation.md` + machine-local
   `/root/konica206-duplex-investigation/`.
8. **Phase 3 prototype** — builtin PDF renderer (Ghostscript `pgmraw` at
   exact PPD points → normalize → own uncompressed raster-v2 writer)
   behind `KONICA_PDF_RENDERER=system|builtin`. Pixel parity 0.7% on
   goldens; live default is `system` (pinned in code + service file).
9. **Phase 5 items** — nightly state backup + log rotation
   (`dist/konica206-maintenance.sh` → `/etc/cron.daily/`), PS behaviour
   documented (direct IPP aborts cleanly, CUPS converts), tray gaps
   noted.
10. **Docs in repo** — `README.md`, `INSTALL-konica206-native.md`,
    `docs/{roadmap,hardening-plan,design-plan,pcl-test-report,
    duplex-investigation}.md`, `test/golden/` baselines, `dist/` (service,
    udev rule, queue PPD, maintenance script).

## 4. Live state (verify before working)

- Native server on `:8001` with `KONICA_PDF_RENDERER=builtin` in env
  (deliberate post-fix state); queue `konica206-native` idle.
- Old `:8000` app running, idle; default printer `KONICA_MINOLTA_206`.
- Check a native server's env via `/proc/<pid>/environ` (never assume
  which renderer is live — a whole investigation was once invalidated
  by an assumed restart; always `grep KONICA_PDF_RENDERER`).
- `pgrep -f` patterns match the invoking shell itself; use `[k]`-style
  self-excluding patterns when killing.
- Build toolchain currently **installed** (Phase 3 work); historical
  practice is removing it after each phase (keep runtime `libpappl1t64`).

## 5. Key file map (repo + machine)

- Repo `/root/konica206-native`: `src/{main,konica_usb,konica_filter,konica_watch}.c`,
  `tools/{konica-send,konica-render}.c`, `test/{test_chunking,test_watchdog}.c`,
  `test/golden/`, `dist/`, `docs/`, `Makefile`.
- Machine-only (never commit): `/usr/local/lib/konica/` (vendor tree +
  private `libcups`), `/var/lib/legacy-printer-app/ppd/`,
  `/var/lib/konica206-native.state`, `/root/konica206-duplex-investigation/`
  (268 MB captures), `/root/konica-phase0/` (backups + golden outputs).

## 6. Conventions that prevent past mistakes

- Paper/restart/service/queue-default changes need explicit approval.
- One code change → rebuild → offline proof → paper proof → commit+push.
- Restarting the native server: kill by verified PID, confirm env of the
  new PID, confirm printer registration, confirm old stack untouched.
- Never touch `konica206uri`, `KONICA_MINOLTA_206`, `/etc/cups`,
  `/var/lib/legacy-printer-app`, `/usr/local/lib/konica` (read-only).
- Python-heredoc edits double-escaped C literals here before — check
  `grep '\\\\'` after scripted edits and rebuild with warnings visible.

## 7. What is wanted now: Phase 4 vendoring

Design a self-contained dependency set so `ldd konica206-native` shows
nothing a distro upgrade can remove except libc/libusb: vendor
`libpappl` + the `libcups` it links (+ non-system deps) into a private
lib dir with rpath (mirroring `/usr/local/lib/konica/lib`), or
static-link where licences permit. Include: pinned source tarballs +
SHA-256, reproducible build flags, acceptance (remove distro
`libpappl1t64` on a test box without breaking the app), full paper
matrix, and a security-update plan for the vendored copies (decision D3).
Keep the `system`-renderer default and the `builtin` flag working through
the change.
