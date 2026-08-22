# Konica Minolta 206 — Full Retrofit Documentation

**System:** Ubuntu 26.04 LTS (classic .deb CUPS 2.4.16, not snap)
**Printer:** Konica Minolta 206 (GDI, USB serial `A8A6041029423`)
**Date:** 2026-08-16
**Status:** WORKING — Atril prints duplex A4 pages correctly via the PAPPL queue

---

## 1. Overview

The Konica Minolta 206 is a **GDI printer** (`MFG:KONICA MINOLTA;CMD:GDI,XPS;MDL:206`)
with a proprietary binary driver (`245igdirf`) and no IPP Everywhere firmware. It is
driven through two coexisting, permanent queues:

| Queue | CUPS name | Backend path | Purpose |
|-------|-----------|--------------|---------|
| PAPPL / Printer Application | `konica206uri` | `cups:usb://...&interface=1` | Normal printing (Atril, GUI apps, `lp`) |
| Classic CUPS | `KONICA_MINOLTA_206` | `usb://...&interface=1` | Fallback / test / banner pages |

`legacy-printer-app` (the OpenPrinting **Printer Application** built on
`pappl-retrofit` / PAPPL) emulates an IPP printer at
`ipp://localhost:8000/ipp/print/konica206uri`. CUPS/GUI clients submit PDF over
IPP; the app converts it to the proprietary GDI stream (via Ghostscript raster →
`245igdirf`) and sends it to the printer through the **classic CUPS USB backend**
for reliable chunked writes.

> Two very different things were broken and both were fixed:
> **(A) an all-black page**, caused by a TonerSave option mismatch, and
> **(B) the printer dropping off USB mid-job**, caused by PAPPL sending one large
> ~61 KB write that the printer's USB controller cannot handle.

---

## 2. Hardware & Driver Facts

- **Printer:** Konica Minolta 206, USB `Bus 002 Device 023: ID 132b:232b`, serial `A8A6041029423`.
- **Vendor driver package:** `konica-minolta-245igdi-cups` (PPDs for 205i/225i/245i; no native 206 PPD).
- **Driver filter:** `/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf` (binary, proprietary, GDI/XPS).
- **Printer interfaces:** Interface 0 = vendor-specific, Interface 1 = printer class. No `usblp` driver owns either interface; access is via raw `/dev/bus/usb`.
- **Rendering chain (PDF → printer):**
  `pdftopdf` → `ghostscript` (raster) → `245igdirf` (GDI/PJL stream) → USB backend.

### Render-architecture fact (critical)

The CUPS-side PPD only controls CUPS's **preprocessing**. PAPPL renders with **its
own driver PPD** (the one chosen at `legacy-printer-app add -m ...`). Any
render-critical setting (TonerSave, Duplex, margins) must be set in the **PAPPL
driver PPD**, not the CUPS queue PPD.

---

## 3. Current Configuration (Reference)

### 3.1 Printer Application service

- **Service:** `legacy-printer-app.service` (enabled at boot, active).
- **Endpoint:** `http://localhost:8000/` (web UI) and `http://localhost:8000/ipp/print/konica206uri` (IPP).
- **Drop-in:** `/etc/systemd/system/legacy-printer-app.service.d/override.conf`

```ini
[Service]
Environment=PPD_PATHS=/var/lib/legacy-printer-app/ppd:/usr/share/cups/model:/usr/lib/cups/driver
ExecStart=
ExecStart=legacy-printer-app server -o log-level=debug -o backend-directory=/usr/lib/cups/backend
ExecStartPost=/usr/local/bin/ensure-konica206uri.sh
```

- `backend-directory=/usr/local/libexec/konica-backend` points the `cups:` device
  scheme at a **self-contained chunked USB backend** (see §11) instead of PAPPL's
  own libusb path or the classic CUPS backend.

### 3.2 PAPPL printer state

- **State file:** `/var/lib/legacy-printer-app/legacy-printer-app.state`
- **Printer:** `konica206uri`
- **Device URI:** `cups:usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1`
- **Driver:** `konica-minolta--206--full-bleed-retrofit-en`
- **Defaults (set via IPP):** media `iso_a4_210x297mm`, duplex, monochrome, 600dpi.

### 3.3 PAPPL driver PPD (render-critical)

- `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd` (active driver)
- `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-real-margins.ppd` (alternate driver)
- `/var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd` (CUPS passthrough PPD)

Key settings that MUST be present in the PAPPL driver PPD:
- `*DefaultOCM_TonerSave: TRUE` (prevents black pages — see Issue 5)
- `*DefaultDuplexer: true`, `*DefaultDuplex: DuplexNoTumble` (2-sided printing)
- Full-bleed `*ImageableArea A4: "0 0 595 842"`
- `*cupsFilter: "application/vnd.cups-raster 0 /usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf"` (proprietary driver)
- **No** `cupsICCProfile` lines (breaks Ghostscript — see Issue 1)

### 3.4 CUPS queues

- **PAPPL passthrough queue** `konica206uri`:
  - device URI `ipp://localhost:8000/ipp/print/konica206uri`
  - PPD `/var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd`
    (`cupsFilter2: "application/pdf application/pdf 0 -"` → CUPS sends PDF unchanged, PAPPL renders)
- **Classic queue** `KONICA_MINOLTA_206` (untouched, still system default):
  - device URI `usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1`
  - PPD `/etc/cups/ppd/KONICA_MINOLTA_206.ppd` (ICC-free)

### 3.5 Persistence helper

- `/usr/local/bin/ensure-konica206uri.sh` — `ExecStartPost` that re-adds the
  `konica206uri` queue and re-sets A4 media-default if it is missing after a
  service restart (fixes the driver-name restart quirk — see Issue 9).

### 3.6 Restored/clean binaries

- `/usr/lib/cups/backend/usb` — pristine classic USB backend ELF
  (sha256 `1ebbe1e6...`).
- `/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf` — pristine
  vendor driver binary (sha256 `0faf0a69...`).
- Diagnostic capture wrappers that were temporarily installed have been removed.

---

## 4. Issues, Causes, and Solutions (Summary)

| # | Symptom | Root cause | Fix |
|---|---------|------------|-----|
| 1 | `gstoraster filter failed` / `undefined in .putdeviceprops` | Konica ICC profile passed to Ghostscript 10.06.0 crashes | Remove `cupsICCProfile` lines from PPD |
| 2 | `Invalid driver left/right margins value -70` | Vendor PPD's full-bleed zero-margin `ImageableArea` rejected by PAPPL | Rewrite `ImageableArea` with real margins (`18 18 W-18 H-18`) |
| 3 | `Unable to open device`, queue paused, no filter runs | PAPPL builds its own URI without `interface=` and `strcmp`s it; passed URI included `&interface=1` | Use PAPPL's exact URI `usb://KONICA%20MINOLTA/206?serial=A8A6041029423` (no `interface=`) |
| 4 | Printer raises size error / "data receiving" | PAPPL PPD default media = Letter; printer tray is A4 | Set `media-default = iso_a4_210x297mm`; always pass A4 |
| 5 | **All-black page** | PAPPL passes `noOCM_TonerSave`; driver defaults to toner-save ⇒ black. Classic passes `OCM_TonerSave=TRUE` | `*DefaultOCM_TonerSave: TRUE` in PAPPL driver PPD |
| 6 | **Printer drops off USB mid-job** (device N → N+1, "data receiving") | PAPPL `_prPrintFilterFunction` sends one up-to-65536-byte `libusb_bulk_transfer`; printer's USB controller can't take a ~61 KB single write | Switch device scheme to `cups:` so the classic USB backend writes in 8192-byte chunks |
| 7 | Banner/test PDFs wedge the printer | Banner content → `bannertopdf` → 2-PAGESTATUS / `IMAGELEN=32768` banded format the firmware can't finish | None (driver/firmware limit); use classic queue for banner/test pages |
| 8 | Atril `media-col` rejected | PPD A4 `595 842 pt` → 20990x29704 (0.01 mm); PAPPL requires exactly 21000x29700 | Declare A4 as `595.28 841.89 pt` in passthrough PPD |
| 9 | Atril sends `color`, rejected | No `*ColorModel` ⇒ no `print-color-mode-supported`; Atril defaults to color | Add `*ColorModel` with only `Gray` ⇒ CUPS advertises `monochrome`; restart cups |
| 10 | Queue disappears after service restart | User-added PPD driver registers as `-user-added-en` on restart | `ensure-konica206uri.sh` ExecStartPost re-adds queue |
| 11 | CUPS 3.0 would remove the classic backend/libcups2 | `cups:` scheme ran `/usr/lib/cups/backend/usb` (needs `libcups.so.2`) | Self-contained libusb-only backend `konica-usb-backend` (see §8a) |
| 12 | **Pure PAPPL native USB wedges printer** ("Data Receiving", no errors logged) | `papplDeviceWrite()` flushes its empty buffer before any >8192-byte write → zero-length USB packet (ZLP) sent before job data; bizhub 206 GDI firmware breaks on premature ZLP | Keep `cups:` scheme + chunked custom backend (never emits ZLPs); root cause + usbmon proof in §8e; upstream: michaelrsweet/pappl#434 |

---

## 5. Deep Dives (Root-Cause Analyses)

### Issue 1 — ICC profile crashes Ghostscript

- **Cause:** The vendor PPD contained `cupsICCProfile` entries. Ubuntu's CUPS
  raster path passed the Konica ICC profile to Ghostscript 10.06.0, which failed:
  `Unrecoverable error: undefined in .putdeviceprops` → `gstoraster filter failed`.
- **Fix:** Removed all `cupsICCProfile` lines from the working PPD. Confirmed
  normal printing returned.

### Issue 2 — PAPPL rejects the PPD geometry (`-70` margin error)

- **Cause:** The vendor PPD defines full-bleed `*ImageableArea` as `"0 0 595 842"`
  (zero margins). CUPS tolerates this; PAPPL/libpappl-retrofit performs stricter
  media/margin validation and rejected the geometry while building its IPP
  attributes.
- **Fix:** In a **copy** of the PPD, enabled `*HWMargins: 18 18 18 18` and rewrote
  all 24 full-bleed `ImageableArea` entries from `"0 0 W H"` to `"18 18 W-18 H-18"`.
  `cupstestppd` passed (exit 4 = only pre-existing unrelated warnings) and the
  PAPPL queue then created cleanly.

### Issue 3 — "Unable to open device" (URI `interface=` mismatch)

- **Cause:** `pappl_usb_find()` builds its own internal device URI and **never
  includes** CUPS's `interface=` query parameter; the open callback does a plain
  `strcmp`. Passing `usb://...&interface=1` therefore never matched.
- **Fix:** Use exactly what PAPPL generates:
  `usb://KONICA%20MINOLTA/206?serial=A8A6041029423` (no `interface=1`).
- **Lesson:** This was the breakthrough that made printing through PAPPL possible.

### Issue 4 — The media-size trap (Letter vs A4)

- **Cause:** PAPPL's PPD default media was `na_letter_8.5x11in`. The printer's
  tray holds A4; on the first job it parsed the PJL, raised a size error, and the
  next jobs sent while the error was held sat in "data receiving".
- **Fix:** Always specify A4 (`-o media=iso_a4_210x297mm`) and set the PAPPL
  printer's `media-default` to `iso_a4_210x297mm` via IPP `Set-Printer-Attributes`.
- **Lesson:** If the printer ever gets stuck in "data receiving" after a bad job,
  a power cycle clears it.

### Issue 5 — All-black pages (OCM_TonerSave) ⭐

- **Symptom:** Every print via the PAPPL queue came out all black; classic CUPS
  prints were fine.
- **Investigation:** The exact same 34 808 176-byte sGray raster was fed through
  the exact same `245igdirf` binary on both paths:
  - classic argv (`...OCM_TonerSave=TRUE`) → 174 496 bytes **correct gray** output
  - PAPPL argv (`...noOCM_TonerSave`) → 164 550 bytes **all-black** output
- **Cause:** The driver's TonerSave option inverts rendering. Classic CUPS passes
  `OCM_TonerSave=TRUE`; PAPPL's driver PPD defaulted to `noOCM_TonerSave`, so the
  driver produced black. Incremental tests (ColorModel=Gray, Duplex, media-col)
  did **not** change the output; only flipping TonerSave did.
- **Fix:** In the PAPPL driver PPD:
  `*DefaultOCM_TonerSave: FALSE` → `TRUE` (applied to both full-bleed and
  real-margins PPDs).
- **Verification:** Job 18 produced 174 496 bytes, 6 bands, EOJ — **byte-identical**
  to the classic output (sha256 `bfcaa12f...`).

### Issue 6 — Printer drops off USB mid-job (large single write) ⭐

- **Symptom:** Dense jobs via PAPPL wedged the printer at "data receiving";
  kernel log showed `usb 2-2: USB disconnect, device number 22` then re-enumeration
  as device 23; backend error `Unable to write 61465 bytes to USB port: No such
  device (it may have been disconnected)`.
- **Root cause (found in source):** PAPPL's `_prPrintFilterFunction`
  (`pappl/job-process.c`, `pappl-retrofit/print-job.c`) reads filter output into a
  **65 536-byte buffer** and calls `papplDeviceWrite(device, buffer, bytes)` once
  with the whole chunk. For PAPPL-native USB, `pappl_usb_write` performs a **single
  `libusb_bulk_transfer`** of the entire buffer (61 465 bytes observed). The
  printer's USB controller overflows from one such large write and drops off the bus.
- **Contrast:** The classic CUPS USB backend writes in **8192-byte chunks**
  (confirmed by usbmon) and prints reliably.
- **Decisive proof:** The correct 174 496-byte output, sent directly through the
  classic backend (`/usr/lib/cups/backend/usb.real`), printed successfully — the
  data was fine; the transport was the problem.
- **Fix:** Switched the PAPPL printer's device URI to the **`cups:` device scheme**:

  ```
  cups:usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1
  ```

  pappl-retrofit's `cups:` scheme runs the **classic CUPS backend as a subprocess
  inside the filter chain** (`ppdFilterExternalCUPS`, exec mode 1). Job data is
  piped to the backend's stdin and the backend writes to USB in 8192-byte chunks.
  This required `-o backend-directory=/usr/lib/cups/backend` in the service.
- **Verification:** Journal shows `cfFilterExternal (usb): Wrote 8192 bytes ...`,
  `Sent 174496 bytes`; backend exited cleanly; output byte-identical to classic;
  dense-A4 and 2-sided jobs both printed; **no USB disconnect** (device number
  stayed constant).

### Issue 7 — Banner/test-page content wedges the printer

- **Cause:** Content sniffed as `application/vnd.cups-pdf-banner` goes through
  `bannertopdf`, producing a 2-PAGESTATUS job with banded `IMAGELEN=32768,32768,...`.
  The 206 firmware only finishes the normal single-band format; the banner format
  leaves it stuck in "data receiving" permanently (needs power cycle).
- **Detection is by content, not filename** (renaming still detected as banner).
- **Affected sources:** PAPPL web-UI "Print Test Page", CUPS "Print Test Page"
  button, and CUPS job-sheet banners (`confidential`, `classified`, ...).
- **Workaround:** Not fixed (driver/firmware limitation). Use the classic
  `KONICA_MINOLTA_206` queue for any test/banner page. Normal documents (including
  Atril duplex) are never affected.

### Issue 8 — Atril `media-col` collection rejected

- **Cause:** Atril derives the media size from the PPD's A4 points and sends a
  `media-col` collection. With A4 declared as `595 842 pt` it converted to
  `20990x29704` (0.01 mm units), which PAPPL strictly rejects
  (`Unsupported media-col collection value`, IPP status 5).
- **Fix:** Declare A4 as `595.28 841.89 pt` so it converts to exactly
  `21000x29700`, matching PAPPL's supported A4. Update both
  `*PageSize`/`*PageRegion`/`*PaperDimension` **and** `*ImageableArea` A4 values.

### Issue 9 — Atril sends `print-color-mode=color`, rejected

- **Cause:** The passthrough PPD had no `*ColorModel` option, so CUPS advertised no
  `print-color-mode-supported` values and Atril defaulted to `color`. PAPPL supports
  only `monochrome` and rejected the job.
- **Fix:** Add `*OpenUI *ColorModel/Color Model` with only `*ColorModel Gray` so
  CUPS advertises `print-color-mode-supported = monochrome`. **CUPS must be
  restarted** after editing the PPD for the attribute to appear. Atril then sends
  `monochrome` and jobs pass validation.

### Issue 10 — Queue disappears after `systemctl restart`

- **Cause:** On restart, user-added PPDs register under `-user-added-en`, but
  `legacy-printer-app add` accepts the non-suffixed name and drops state referencing
  the suffixed name.
- **Fix:** `/usr/local/bin/ensure-konica206uri.sh` runs as `ExecStartPost`: if the
  `konica206uri` queue is missing after startup it re-adds it (with the `cups:`
  URI) and re-applies the A4 media default. The queue now survives restarts.

---

## 6. How to Use

### Print normally (Atril / GUI)

Just print from Atril (or any app) to the `konica206uri` printer. Options (A4,
duplex, gray) are exposed via IPP. Verified working: **duplex page from Atril**.

### Print from the command line

```bash
lp -d konica206uri -o media=iso_a4_210x297mm -o sides=two-sided-long-edge mydoc.pdf
```

### Fallback / test / banner pages

```bash
lp -d KONICA_MINOLTA_206 mydoc.pdf
```

### Recover a wedged printer

If the printer ever shows "data receiving" after a bad job, power-cycle it.

### Admin

- PAPPL web UI: `http://localhost:8000/`
- PAPPL logs: `sudo journalctl -u legacy-printer-app -f`
- PAPPL debug copy of every job (in debug mode):
  `/var/spool/legacy-printer-app/debug-jobdata-konica206uri-N.prn`

---

## 7. Known Limitations

1. **Banner/test-page content wedges the printer** (Issue 7). Use the classic
   queue for test/banner pages; power-cycle to recover if wedged.
2. **No Avahi**: PAPPL's mDNS discovery/registration errors in the journal are
   cosmetic (no Avahi daemon installed). Explicit CUPS queue handles discovery.
3. **Classic queue is the only banner-safe path** and relies on the aging vendor
   driver package.
4. **Printer must not be mid-wedge** when sending a job; a wedged printer causes
   backend aborts on subsequent jobs until power-cycled.

---

## 8. CUPS 3.0 / Future

- **Classic queue (`KONICA_MINOLTA_206`) breaks under CUPS 3.0** — PPDs, filters,
  and classic backends are removed.
- **PAPPL queue keeps working** — it is pure IPP (`ipp://localhost:8000/...`);
  the app owns the PPD/filter/backend work and is CUPS-version-independent. CUPS
  3.0 discovers it via mDNS or a manual IPP printer entry.
- The thin CUPS-side PPD becomes irrelevant under 3.0; all options (A4, duplex,
  gray) already come through IPP attributes from the app.
- Plan: migrate any test/banner needs into a second Printer Application, or accept
  that test pages go through the PAPPL queue with the banner wedge limitation.
- This machine runs classic .deb CUPS 2.4.16 (no `cups` snap installed).

## 8a. CUPS 3.0-proofing: self-contained chunked USB backend (2026-08-16)

- **Problem:** The `cups:` scheme originally launched the **classic CUPS USB
  backend** (`/usr/lib/cups/backend/usb`) as a subprocess. It never talked to the
  CUPS daemon, but it links **`libcups.so.2`** (package `libcups2t64`, CUPS 2.4.x).
  The CUPS 3.0 transition would remove the classic backend binaries and likely
  `libcups2`, breaking the subprocess.
- **Solution — `konica-usb-backend`** (source:
  `/home/vinod/konica-usb-backend/konica-usb-backend.c`, built binary installed at
  `/usr/local/libexec/konica-backend/usb`):
  - Depends **only on `libusb-1.0`** + libc — no libcups, no CUPS daemon. Survives
    CUPS 3.0.
  - CUPS-compatible backend: discovery mode (no `DEVICE_URI`) lists the device as
    `direct usb://KONICA%20MINOLTA/206?serial=...&interface=1`; job mode reads
    stdin and writes to the printer.
  - Writes in **≤8192-byte chunks** via `libusb_bulk_transfer` (endpoint 0x01,
    interface 1) — mirrors the classic backend behavior that fixed the USB wedge.
  - Matches the printer by serial `A8A6041029423` (VID 132b / PID 232b).
- **Config:** `backend-directory=/usr/local/libexec/konica-backend` in the systemd
  drop-in. The `cups:` URI scheme is unchanged
  (`cups:usb://...&interface=1`).
- **Verified:**
  - Direct pipe: `sudo env DEVICE_URI="usb://...?serial=A8A6041029423&interface=1" usb < /tmp/out-classic.prn`
    → 21×8192 + 2464-byte tail = 174496 bytes written, exit 0, **no USB
    disconnect** (device stayed 23).
  - Full stack: 2-sided `twopage` via the PAPPL queue (job 25) — journal shows
    `/usr/local/libexec/konica-backend/usb` started, `Wrote 8192/960 bytes`,
    backend exited clean, job completed.
  - User confirmed both printed fine.
- **Note:** The classic CUPS queue still uses `/usr/lib/cups/backend/usb` and is
  unaffected; that binary remains only for the legacy queue.

## 8b. CUPS 3.0 readiness — refined assessment (2026-08-16)

`libcups3` itself is **not a blocker** for the retrofit path. The distinction is
between the PAPPL application and the custom USB backend, not the presence of
`libcups3`.

Data path under CUPS 3.x:

```
CUPS 3.x ──IPP──► legacy-printer-app (PAPPL) ──► 245igdirf
     ──cups: subprocess──► /usr/local/libexec/konica-backend/usb
     ──libusb──► Konica 206
```

Three different libcups situations:

| Component | libcups2 dependency? | CUPS 3 concern |
|---|---|---|
| Classic `KONICA_MINOLTA_206` queue (`/usr/lib/cups/backend/usb`) | Yes (`libcups.so.2`) | Red — breaks under CUPS 3 |
| `konica-usb-backend` (`/usr/local/libexec/konica-backend/usb`) | No (libusb-1.0 + libc only) | Green — survives |
| `legacy-printer-app` / PAPPL | Modern pappl-retrofit builds support **libcups3** | Amber — manageable |

- OpenPrinting added **libcups3 support** to pappl-retrofit, libppd, and
  libcupsfilters; pappl-retrofit vendors the CUPS 2.x side/back-channel code so it
  builds with either `libcups2` or `libcups3`.
- Current OpenPrinting development tests against CUPS 2.4.x, 2.5.x, and
  CUPS 3.x/libcups3. libcups 3.0.2 (released 2026-06-05) is the mature CUPS 3
  library.
- **The one real caveat:** the installed package is `legacy-printer-app
  1.0~b2-0ubuntu8`. When the distro transitions to CUPS 3, the app must be
  upgraded to a pappl-retrofit build linked against the libcups3/libppd/
  libcupsfilters stack. That is a **normal package migration**, not a
  fundamental printer-driver problem.
- This is exactly why the driver was relocated to `/usr/local` (§8c): the
  rendering binary is decoupled from the `konica-minolta-245igdi-cups` package,
  so the migration only touches the app package itself.

## 8c. Hardening: driver relocated to /usr/local, packages held (2026-08-16)

- **Relocated the vendor 245igdi driver tree** from `/usr/lib/cups/filter/
  KonicaMinolta/` to `/usr/local/lib/konica/KonicaMinolta/` (binary + `mtorf.ocm`
  + `Halftones/` + `Colorworlds/` + `Profiles/`). `/usr/local` is never touched
  by `apt`, so rendering survives removal of the `konica-minolta-245igdi-cups`
  package (already absent from current Ubuntu sources — `apt-cache madison`
  returns nothing).
- **Repointed both retrofit PPDs** (`*cupsFilter` line 39 and `*OCM_resourceDir`
  line 56) to `/usr/local/lib/konica/KonicaMinolta/245igdi/...`. The filter has
  no compiled-in absolute paths; `OCM_resourceDir` (from the PPD) is what it uses
  to find its support files.
- **Verified byte-identical:** job 26 via the PAPPL queue after relocation →
  174496 B, sha256 `bfcaa12f...` = `/tmp/out-classic.prn`. `job-state: completed`
  `job-completed-successfully`, no USB disconnect.
- **`apt-mark hold`** applied to: `legacy-printer-app`, `libpappl-retrofit1`,
  `libpappl1t64`, `konica-minolta-245igdi-cups` (prevents a release upgrade from
  silently removing them).
- **Archived `.debs`** for offline reinstall:
  `legacy-printer-app`, `libpappl-retrofit1`, `libpappl1t64`, `libcups2t64`,
  `libcupsimage2t64` (driver `.deb` not recoverable from current repos; its
  installed tree is fully archived instead — see backup).
- The Debian 13 kit installs the driver to `/usr/local` too, with all kit PPDs
  already repointed.

## 8d. Portable installer + GitHub (2026-08-16)

- The full setup (backup, docs, backend source, Debian 13 kit) is mirrored to
  **https://github.com/vinod2807/konica-retrofit** (private).
- Added **`install-konica-anylinux.sh`** at the repo root: a distro-agnostic
  installer (Debian/Ubuntu/Fedora/Arch/openSUSE) that detects the distro,
  installs pappl-retrofit (package → bundled debs → OpenPrinting source build),
  auto-detects the printer serial via `lsusb`, installs the driver under
  `/usr/local`, builds the chunked backend from source, creates the PAPPL +
  CUPS queues, and verifies. Handles CUPS 3.0 (no `lpadmin`) by exposing the
  raw IPP endpoint.
- Verified end-to-end on this machine (re-run = idempotent; queue recreated,
  backend discovery OK, CUPS default retained).
- **Backup defect found & fixed while building the installer:** the driver tree
  had been archived at `usr/local/lib/KonicaMinolta/...` (missing the `konica/`
  wrapper level), which would not have matched the PPDs' `*OCM_resourceDir`
  paths on restore; and three `.debs` (`legacy-printer-app`, `libpappl-retrofit1`,
  `libpappl1t64`) had not been copied into `debs/`. Both corrected, manifest +
  tarball regenerated (74 files, 0 checksum failures), repo re-synced.

---

## 9. Files & Artifacts

### Active configuration
- `/etc/systemd/system/legacy-printer-app.service.d/override.conf`
- `/var/lib/legacy-printer-app/legacy-printer-app.state`
- `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd` (driver)
- `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-real-margins.ppd` (alternate driver)
- `/var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd` (CUPS passthrough)
- `/usr/local/bin/ensure-konica206uri.sh`
- `/usr/local/libexec/konica-backend/usb` (self-contained chunked USB backend; source `/home/vinod/konica-usb-backend/konica-usb-backend.c`, sha256 `d76e61bc...`)
- `/usr/local/lib/konica/KonicaMinolta/245igdi/` (relocated vendor driver tree;
  retrofit PPDs point here — see §8c)
- `/etc/cups/ppd/KONICA_MINOLTA_206.ppd` (classic queue; untouched)

### Backup
- `/home/vinod/konica-printer-backup-20260807-153913/` (verified SHA256SUMS)
- `/home/vinod/konica-pappl-backup-20260816-1050/` + `konica-pappl-backup-20260816-1050.tar.gz`
  (full new-PAPPL-printer backup incl. relocated driver, PPDs, backend, ensure
  script, systemd drop-in, Debian 13 kit, debs, dpkg-info; verified SHA256SUMS)

### Investigation notes & diagnostics
- `/home/vinod/KONICA_PAPPL_RETROFIT_INVESTIGATION.md` (full round-by-round log)
- `/home/vinod/konica-pappl-usb-diagnostic-20260807/` (strace + usbmon captures:
  `round5-clean-a4-usbmon.log` proves 8192-byte classic writes;
  `cups-twopage-usbmon.log` etc.)
- `/var/spool/legacy-printer-app/debug-jobdata-konica206uri-*.prn` (per-job outputs)

### Key hashes / identifiers
- Correct gray output sha256: `bfcaa12f891a0e2d13a9ea29ae6b6fa8186b1717c1cc0fcc838abaf65c7a6a96`
- Pristine classic USB backend `/usr/lib/cups/backend/usb`: sha256 `1ebbe1e68d3f1ffbab2cc0f5a0dc2c0c8393dcb3ea47df74416e73147947dc3f`
- Pristine driver `/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf`: sha256 `0faf0a69aa772805423a9c4c1e5bb20f74d0bf43daeee676d4fa7c658377380d`

---

## 10. Safety Rules (from the project)

- **Never delete or modify the classic `KONICA_MINOLTA_206` queue or its PPD** — it
  is the fallback and the banner-safe path.
- **Never restore `cupsICCProfile` lines** unless the Ghostscript/profile
  compatibility issue is resolved independently.
- When testing driver/PPD changes, work only on **copies** and keep the verified
  backup available.
- Any job sent while the printer is wedged will abort at the backend — power-cycle
  the printer first.


## 8e. Native PAPPL USB path ruled out — ZLP root cause found (2026-08-21)

**Experiment:** a parallel PAPPL printer (`konica206pappl`, plain `usb://KONICA%20MINOLTA/206?serial=...`
URI, no `cups:` scheme) was created to test whether the custom chunked backend could be dropped in
favor of PAPPL's native USB device support. First job wedged the printer.

**Symptom:** panel stuck at "Data Receiving"; journal shows filter chain and backend all
"exited with no errors", job `Completed`; **no USB disconnect**. Silent false-success failure —
worse than the Aug-7 wedge (which at least dropped off the bus).

**Root cause (usbmon-proven, see `backup/diagnostics/usbmon-zlp/`):**

1. `_prPrintFilterFunction` reads 10,491 bytes and calls `papplDeviceWrite(dev, buf, 10491)`
2. `papplDeviceWrite` (pappl/device.c): `bufused(0) + 10491 > 8192` ⇒ "flush" of the EMPTY buffer
   ⇒ `pappl_write(device, buffer, 0)` — no zero-length guard anywhere down the stack
3. `pappl_usb_write` → `libusb_bulk_transfer(..., len=0, ...)` ⇒ **zero-length packet on the wire
   BEFORE any job data**
4. bizhub 206 GDI firmware breaks on the premature ZLP; subsequent data is ACKed but never rendered

usbmon diff (working `konica206uri` job vs wedging native job): the working path contains only
non-zero bulk OUT writes (8192-byte chunks from the classic-style backend); the wedging path starts
with `S Bo:3:009:1 -115 0` / `C Bo:3:009:1 0 0`.

**Why the `cups:` scheme is immune:** the same `papplDeviceWrite` buffering runs, but
`_prCUPSDevWrite()` ends in `write(pipe_fd, buffer, bytes)` — a zero-byte pipe write is a kernel
no-op. The ZLP never materializes. The custom chunked backend likewise never emits zero-length
transfers.

**Why the Aug-7 "chunk size" theory was incomplete:** with big jobs, PAPPL native emits a ZLP
before *every* >8192-byte read chunk (each triggers `flush(0)`). The classic backend's reliable
8192-byte writes worked not because of their size, but because they never interleave ZLPs.
A libusb burst-size probe (8 KiB … sustained 64 KiB, no ZLPs) passes cleanly — synthetic traffic
without ZLPs cannot reproduce this failure.

**Disposition:** do not use PAPPL's native USB path on this device. Upstream report filed:
https://github.com/michaelrsweet/pappl/issues/434 (suggested fix: guard `device->bufused > 0`
before the flush, and/or return early for `bytes == 0` in `pappl_usb_write`).
Recovery from the wedge: power-cycle, then verify via `konica206uri`.

### 8e.1 — Decision tree: switching to native PAPPL USB after the upstream fix

Upstream status: **fixed same-day** — michaelrsweet/pappl#434 closed with
`9093b16` (master) and `bc29de9` (v1.4.x backport, ships in the next 1.4.x
release). Until Fedora packages a pappl release containing the fix
(`rpm -q pappl`; check `dnf changelog pappl | grep -i 434` or empty-buffer
guard in `papplDeviceWrite`), **native `usb://` still wedges this printer.**

Once a fixed pappl is installed:

1. Re-create a test queue per dossier §6 (`PAPPL_ZLP_DOSSIER.md`) and print
   one job; verify paper output AND absence of "Data Receiving" wedge.
2. If it validates, switching is an optional 5-minute cleanup:
   - change device URI `cups:usb://...` → `usb://...` (no `interface=`)
   - drop `-o backend-directory=...` from the systemd override
   - retire `/usr/local/libexec/konica-backend/`
3. If anything looks off, keep the custom backend — it is unaffected by all
   of this and remains the proven path.

Gains from switching are marginal (one small binary less). The custom backend
also keeps its 30-second no-progress abort safety net, which PAPPL's native
path lacks (`libusb_bulk_transfer` timeout=0 = infinite hang on a wedged
device). There is no urgency either way.
