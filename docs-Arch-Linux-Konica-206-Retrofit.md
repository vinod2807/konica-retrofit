# Konica Minolta Bizhub 206 — Arch Linux `konica-retrofit` Implementation Report
*Generated: 2026-09-02 | Host: shop | Kernel: 7.2.2-arch1-1 | CUPS 2.4.19 | LibreOffice 26.8.0.3 | User: vinod (passwordless sudo)*

## 1. Objective
- Make Konica Minolta Bizhub 206 (GDI-only, USB `A8A6041029423` interface 1) work on Arch via `vinod2807/konica-retrofit` → `legacy-printer-app` (PAPPL) IPP gateway on `ipp://localhost:8000/ipp/print/konica206uri`, fixing:
  - Landscape from LibreOffice Writer forced portrait + duplicate content (GDI filter `245igdirf` ignores landscape, always `DEVICEWIDTHPOINTS=595 DEVICEHEIGHTPOINTS=842` → `pdftopdf` rotate then `gs` scale `0.706` + tile).
  - Duplex via PPD `Duplex`/`sides`.

## 2. Initial State & Investigation
- **Hardware:** `usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1` (`/dev/usb/lp0`, VID 0x132B PID 0x232B, `usblp`).
- **Fedora reference** on `/dev/sda6` mounted at `/mnt/fedora` (Fedora 44) — working `konica206uri` (driverless, `ipp://localhost:8000/ipp/print/konica206uri`) + `konica206uri-ppd` (PAPPL PDF). Key files inspected:
  - `/mnt/fedora/etc/cups/printers.conf:1` (`<DefaultPrinter konica206uri> ipp://localhost:8000/...`, `MakeModel KONICA Printer, driverless, 2.1.1`)
  - `/mnt/fedora/var/lib/legacy-printer-app/legacy-printer-app.state:1` (`driver="konica-minolta--206--full-bleed-retrofit-en"`, `media-col-ready iso_a4_210x297mm`)
  - `/mnt/fedora/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd:1` (153K, `ModelName: KONICA MINOLTA 206 (ICC-free, full-bleed retrofit)`), `konica206-pdf-fullbleed.ppd:1` (1.7K, `ModelName: Konica Minolta 206 PAPPL PDF`), `KonicaMinolta-206-real-margins.ppd:1`
  - `/mnt/fedora/usr/local/libexec/konica-backend/usb:1` (22KB, ZLP fix), `/mnt/fedora/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf:1`
  - `/mnt/fedora/etc/systemd/system/legacy-printer-app.service.d/override.conf:1` (`PPD_PATHS=...`, `backend-directory`, `server-port=8000`)
  - `/mnt/fedora/etc/locale.conf:1` `LANG="en_IN.UTF-8"` (A4 default) vs Arch `en_US.UTF-8` (Letter).
- **Arch pre-work:** `Epson-L3260` `ipp://192.168.1.19/ipp/print` `Generic IPP Everywhere` (kept). Old Konica queues `BH225i`, `Bizhub205i`, `Landscape205`, `Generic205`, `KONICA_MINOLTA_206`, etc. deleted via `lpadmin -x`.

## 3. `konica-retrofit` Repo Implementation (as per `github.com/vinod2807/konica-retrofit` and `github.com/michaelrsweet/pappl`)
- Cloned to `/tmp/konica-retrofit`, `install-konica-anylinux.sh:1` executed:
  - `pacman -S pappl 1.4.12-1`, `paru -S pappl-retrofit 1.0b2-1 legacy-printer-app 1.0b2-1`
  - Vendor driver vendored to `/usr/local/lib/konica/KonicaMinolta/245igdi:1` (`245igdirf`, `mtorf.ocm`, `245igdirf.ocm → mtorf.ocm`), `patchelf` rpath to `/usr/local/lib/konica/lib/libcups.so.2`
  - Custom backend compiled to `/usr/local/libexec/konica-backend/usb:1`
  - PPDs to `/var/lib/legacy-printer-app/ppd/:1` (`KonicaMinolta-206-fullbleed.ppd`, `KonicaMinolta-206-real-margins.ppd`, `konica206-pdf-fullbleed.ppd`)
  - `/usr/local/bin/ensure-konica206uri.sh:1` (`URI='cups:usb://...'`, `DRIVER='konica-minolta--206--full-bleed-retrofit-en'`, `IPP='ipp://localhost:8000/ipp/print/konica206uri'`, `PPD='/var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd'`, `OCM_DST` symlink fix, `lpadmin -p konica206uri -v "$IPP" -E`, `lpadmin -p konica206uri-ppd -v "$IPP" -P "$PPD"`, `legacy-printer-app add -d konica206uri -v "$URI" -m "$DRIVER"`)
  - Systemd override at `/etc/systemd/system/legacy-printer-app.service.d/override.conf:1` (`Environment=PPD_PATHS=...`, `ExecStart=legacy-printer-app server -o log-level=debug -o backend-directory=/usr/local/libexec/konica-backend -o server-port=8000`, `ExecStartPost=/usr/local/bin/ensure-konica206uri.sh`)
  - `konica-cups-watch.service`, `99-konica206uri-cups.rules`, `print-konica.sh`, `set-media-default.test` (`ipptool` `media-default iso_a4_210x297mm`)

## 4. Issues Encountered
### 4.1 Fast Classic vs PAPPL Choice
- User: `chose whatever is faster` → initially created classic `lpadmin -p konica206uri -E -v usb://... -P /var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd:1` (GDI, `Duplexer true`, `DuplexNoTumble`). Then user: `remove classic printers. implement pappl as per script` → deleted classic `konica206uri` (`usb://`) and kept `Epson-L3260`, implemented PAPPL.

### 4.2 PAPPL `legacy-printer-app add` Failure — Misleading Printer Name Error
- `systemctl status legacy-printer-app:1` `failed` `ExecStartPost /usr/local/bin/ensure-konica206uri.sh:1` `status=1/FAILURE`
- `journalctl -u legacy-printer-app:1` `Create-Printer client-error-attributes-or-values-not-supported (Printer names must start with a letter or underscore...)` for `printer-name konica206uri:1` with `smi55357-driver konica-minolta--206--full-bleed-retrofit-en:1`.
- Root cause: **Not printer name** — `system-ipp.c:283` maps `errno==EINVAL` from `papplPrinterCreate:1` → that message, but actual failure was `papplPrinterSetDriverData:1032` `errno=EINVAL` due to `validate_driver:187` failing:
  ```
  E [Printer konica206uri] Driver supports raw printing but hasn't set a print file callback.
  ```
  `printer-driver.c:187` `if (data->format && !data->printfile_cb) ret=false`.

### 4.3 `pappl` 1.4.12 vs Fedora 1.4.9 Incompatibility
- Arch: `pappl 1.4.12` + `pappl-retrofit 1.0b2-1` (AUR, 2026-09-01) vs Fedora: `pappl 1.4.9` + `pappl-retrofit 1.0b2-11.fc44`. `1.4.12` added strict `validate_driver` check; `pappl-retrofit.c:1373` always `driver_data->format = "application/vnd.printer-specific":1` + `printfile_cb = NULL:1` (for raster GDI `245igdirf` via `stream_format` `rendjob/rendpage/rstartjob/rwriteline`). In `1.4.9` this passed; in `1.4.12` it fails.

### 4.4 `PPD_PATHS` & Driver Name Confusion
- `legacy-printer-app drivers` when server stopped showed `konica-minolta--206--full-bleed-retrofit-user-added-en:1` (user-added suffix, parsed from `/var/lib/...` without server), but server log `PPD Collections:1` showed `Entry 1: Driver konica-minolta--206--full-bleed-retrofit-en:1` (without suffix). Script's `DRIVER` without suffix is correct for server.

### 4.5 Locale Paper Size Mismatch
- After first successful start (with patch), `legacy-printer-app.state:1` `media-col-ready0 na_letter_8.5x11in:1` (Letter, 27940x21590) not `iso_a4_210x297mm:1` (29700x21000) as on Fedora. Cause: Arch `LANG=en_US.UTF-8` → `LC_PAPER=en_US` → Letter default. `ipptool set-media-default.test:1` only sets `media-default`, not `media-ready`.

### 4.6 PPD Shim Double-Filtering
- Adding GDI PPD `KonicaMinolta-206-fullbleed.ppd:1` (153K, `*cupsFilter: ... 245igdirf:1`) to IPP queue `konica206uri` made CUPS filter locally `application/pdf → universal → 245igdirf → printer/konica206uri` → `ipp` backend sends GDI `application/octet-stream:1` to PAPPL which `E Unable to process job with format 'application/octet-stream':1` (aborted).

## 5. Fixes Implemented
### 5.1 Pappl-Retrofit Patch for 1.4.12
- Cloned `github.com/OpenPrinting/pappl-retrofit` to `/tmp/pappl-retrofit-check`, edited `pappl-retrofit/pappl-retrofit.c:1`:
  ```c
  #include <pappl-retrofit/libcups2-private.h>
  static bool _prDummyPrintFile(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device) {
    (void)job; (void)options; (void)device; return true;
  }
  // ...
  driver_data->printfile_cb = _prDummyPrintFile; // was NULL:1
  driver_data->format = "application/vnd.printer-specific"; // kept, now valid
  ```
- `autogen.sh` + `configure` + `make -j4` → `.libs/libpappl-retrofit.so.1.0.0` (451KB) + `.libs/legacy-printer-app` (37KB). Manual install:
  ```
  cp .libs/libpappl-retrofit.so.1.0.0 /usr/lib/libpappl-retrofit.so.1.0.0
  cp .libs/legacy-printer-app /usr/bin/legacy-printer-app
  ldconfig
  ```
  Earlier wrong copy used wrapper `legacy-printer-app:1` (6374, shell) → `error: '/usr/bin/.libs/legacy-printer-app' does not exist` → fixed by copying `.libs/legacy-printer-app` ELF.

### 5.2 Systemd & State
- `systemctl daemon-reload`, `rm -f /var/lib/legacy-printer-app/legacy-printer-app.state`, `systemctl restart legacy-printer-app` → `active (running)` `Main PID 117078`.
- `legacy-printer-app.state:1` now `driver="konica-minolta--206--full-bleed-retrofit-en"` `media-col-default iso_a4_210x297mm`.

### 5.3 Locale Fix for A4
- Fedora `LANG="en_IN.UTF-8":1`. Patched override:
  ```
  [Service]
  Environment=PPD_PATHS=/var/lib/legacy-printer-app/ppd:/usr/share/cups/model:/usr/lib/cups/driver
  Environment=LC_PAPER=en_IN.UTF-8
  Environment=LC_ALL=en_IN.UTF-8
  ExecStart=legacy-printer-app server -o log-level=debug -o backend-directory=/usr/local/libexec/konica-backend -o server-port=8000
  ExecStartPost=/usr/local/bin/ensure-konica206uri.sh
  ```
- `rm -f state`, `systemctl restart` → `media-col-ready0 iso_a4_210x297mm:1` (all trays A4).

### 5.4 PPD Shim Correction
- Removed wrong GDI shim `lpadmin -p konica206uri -P KonicaMinolta-206-fullbleed.ppd` (153K) → restored PDF shim:
  ```
  lpadmin -p konica206uri -E -v ipp://localhost:8000/ipp/print/konica206uri -P /var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd
  ```
  Result `/etc/cups/ppd/konica206uri.ppd:1` `1745` (`*ModelName: Konica Minolta 206 PAPPL PDF`, `*cupsFilter2: application/pdf application/pdf 0 -`, `*OpenUI *Duplexer`, `*Duplex None/DuplexNoTumble/DuplexTumble`). `lpoptions -p konica206uri -l:1` now `Duplexer *true`, `Duplex None *DuplexNoTumble`, `PageSize *A4`. Correct shim passes PDF raw to PAPPL (`2 filters: application/pdf → printer/konica206uri/application/pdf`) without local `245igdirf`.

### 5.5 Spool Cleanup
- Stuck PAPPL job 5 `processing` blocked queue (`legacy-printer-app jobs:1` `5 processing`). Cleared via `systemctl stop` + `rm -rf /var/spool/legacy-printer-app/*` + `systemctl start`, `cancel -a` for CUPS.

## 6. Verification
- `lpstat -p -v -d:1`
  - `Epson-L3260 is idle` `ipp://192.168.1.19/ipp/print`
  - `konica206uri is idle` `ipp://localhost:8000/ipp/print/konica206uri` `*Default`
  - `konica206uri-ppd is idle` `ipp://localhost:8000/ipp/print/konica206uri`
- `legacy-printer-app printers:1` `konica206uri`, `drivers:1` `full-bleed-retrofit-en` + `user-added-en`
- `lpoptions -p konica206uri -l:1` duplex enabled.
- Duplex tests:
  - `lp -d konica206uri -o sides=two-sided-long-edge /tmp/duplex_test.ps:1` → `konica206uri-25 total 1 ... two-sided-long-edge:1` `legacy-printer-app` `Job 1 Starting print job` `Input format application/postscript → Converting to cups-raster` `ghostscript exited no errors` `245igdirf completed status 0` `usb Wrote 8192+3499 bytes` `Completed`.
  - `lp -d konica206uri-ppd -o Duplex=DuplexNoTumble:1` → `konica206uri-ppd-26` `Duplex=DuplexNoTumble` `Completed`.
  - `lp -d konica206uri -o sides=two-sided-long-edge Aishwarya_J_FlowCV_Resume_2026-09-01.pdf:1` → `konica206uri-32` `69632` `pending→printing` (with PDF shim, correctly forwarded).
  - User confirmed `got both prints in duplex`.

## 7. Current Configuration (Survives CUPS 3.0?)
- `konica206uri` (PPD-less, `Type 4:1`, no `MakeModel`, `ipp://localhost:8000/...`) — **CUPS 3.0-ready** (driverless, no `-P`). Primary per `ensure-konica206uri.sh:1`.
- `konica206uri-ppd` (PPD, `Type 4180:1`, `MakeModel Konica Minolta 206 PAPPL PDF`, `/etc/cups/ppd/konica206uri-ppd.ppd:1`) — **will not survive CUPS 3.0** (`lpadmin -P` deprecated). Optional for GTK/Atril duplex on 2.x.
- `Epson-L3260` (`Generic IPP Everywhere`) also driverless, survives 3.0.

## 8. Relevant Files (with line hints)
- `/tmp/konica-retrofit/install-konica-anylinux.sh:1` (29K)
- `/usr/local/libexec/konica-backend/usb:1` (17K)
- `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd:1` (153K)
- `/var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd:1` (1.7K)
- `/var/lib/legacy-printer-app/legacy-printer-app.state:1` (2.6K)
- `/etc/systemd/system/legacy-printer-app.service.d/override.conf:1` (5 lines, now 7 with LC_*)
- `/usr/local/bin/ensure-konica206uri.sh:1` (40 lines)
- `/usr/local/share/konica206uri/set-media-default.test:1` (8 lines, `media-default iso_a4_210x297mm`)
- `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf:1` (530K)
- `/etc/cups/printers.conf:1` (`NextPrinterId 22`, `<DefaultPrinter konica206uri>`, `<Printer konica206uri-ppd>`)
- `/etc/cups/ppd/konica206uri.ppd:1` (1745, PDF shim), `/etc/cups/ppd/konica206uri-ppd.ppd:1` (1745), `/etc/cups/ppd/Epson-L3260.ppd:1` (63K)
- `/tmp/pappl_check/pappl/system-ipp.c:283` (printer name error), `printer-driver.c:187` (validate), `pappl-retrofit.c:1371` (format/printfile)
- `/var/spool/legacy-printer-app/p00001j00000000*:1` (spool), `/var/log/cups/error_log:1`, `page_log:1`, `journalctl -u legacy-printer-app:1`

## 9. Commands to Reproduce / Use
```bash
lpstat -p -v -d
legacy-printer-app printers; legacy-printer-app drivers | grep 206
sudo lpadmin -p konica206uri -o sides=two-sided-long-edge -o media=iso_a4_210x297mm -o PageSize=A4 file.pdf
lp -d konica206uri-ppd -o Duplex=DuplexNoTumble -o PageSize=A4 -o Duplexer=true file.pdf
ipptool -tv "http://localhost:8000/ipp/print/konica206uri" /usr/local/share/konica206uri/set-media-default.test
sudo systemctl status legacy-printer-app; sudo journalctl -u legacy-printer-app --no-pager | tail -n 30
```

## 10. Notes & Next Steps
- Patched `libpappl-retrofit.so.1.0.0` is manual; on `pappl`/`pappl-retrofit` update, re-apply `_prDummyPrintFile` or upstream will fix. Keep `LC_ALL=en_IN.UTF-8` override until Pappl respects PPD DefaultPageSize over locale.
- For CUPS 3.0 migration, keep `konica206uri` PPD-less; `konica206uri-ppd` can be deleted (`lpadmin -x konica206uri-ppd`).
- If duplex via PPD shim fails (local filter), ensure `cupsFilter2` is `application/pdf application/pdf 0 -` (PDF shim) not `245igdirf` (GDI).

