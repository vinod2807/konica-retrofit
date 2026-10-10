# Konica 206 `konica206uri` Wine-Adobe PS incident — summary for Claude

## Context

- Host: ResolutePup64 26.04 (Puppy, no systemd; CUPS via `/etc/init.d/cups`), CUPS 2.4.16, cups-filters 2.0.1, Ghostscript 10.06.0
- Printer: Konica Minolta 206, USB serial A8A6041029423
- Queues: `konica206uri` (CUPS passthrough → `ipp://localhost:8000/ipp/print/konica206uri` → legacy-printer-app PAPPL 1.4.9 → vendor `245igdirf` → custom libusb backend); classic `KONICA_MINOLTA_206` (`usb://…`, `pstops+gstoraster+245igdirf+usb`); shim PPD is driverless with passthrough only for `vnd.cups-pdf/jpeg/png`
- Repo: `github.com/vinod2807/konica-retrofit` (`/root/konica-retrofit`), installer `install-konica-anylinux.sh`

## Failure

- Wine/Adobe Acrobat printouts (`%%Creator: Wine PostScript Driver` wrapping `%%Creator: Adobe Acrobat 26.2.0`) submitted to `konica206uri` as `application/vnd.adobe-reader-postscript` (Jobs 18/19, 541696 B) died in `gstoraster`: `Ghostscript status 255`, `ioerror (-12) on closing pdfwrite device`, `gstoraster filter failed`; PAPPL stayed `Idle, 0 jobs`
- Contrasts: native PDF (Job 21, `pdftopdf+ipp`) printed; trivial plain-PS (Job 22, `gstopdf+pdftopdf+ipp`) printed; same Wine bytes on classic queue (Job 20) printed; standalone `gs` (1.3/1.7, ±PDFX3/ICC, root/`lp`, file/stdin/true-pipe) always exit 0 (~198 KB)

## Root cause

- MIME-branching gap, not corrupt input or sandbox (no AppArmor, no systemd, `TMPDIR` writable, `gs`-as-`lp` fine)
- Only `application/postscript → application/pdf` has a direct rule (`gstopdf`, cost 0); `adobe-reader-postscript` is deliberately kept out of the PDF workflow and forced through the raster roundtrip `pstops→gstoraster→rastertopwg→pwgtopdf`, which yields empty PDFs (minimal probe file → 0 bytes) or `ioerror` (Wine file) on PDF-final driverless queues

## Fixes

1. Interim (superseded): custom `/usr/lib/cups/filter/wineps2pdf` (gs 1.7 pdfwrite) + `/usr/share/cups/mime/zz-wineps.convs` + PPD `*cupsFilter2` lines → Job 19 `wineps2pdf+ipp`, completed, paper confirmed. PPD lines proved inert under `cupsfilter`; system convs rule did the work
2. Clean (current): single no-op retype `/etc/cups/wineps.convs` (`adobe-reader-postscript → postscript 0 -`), routing Wine jobs into proven `gstopdf`. Verified no-paper (exit 0, 198431 B, correct text) and paper: Job 23 (pre-cleanup) + Job 24 (`gstopdf+pdftopdf+ipp`, final state), both completed, printouts confirmed, queue empty. Interim filter, `zz` file, and PPD lines all removed

## Repo commit

- Pushed `c1c8b71` to `origin/main`: `install_wineps_convs()` + `restart_cups()` (systemd→service→init.d fallback) in installer, `docs-Wine-Adobe-PS-Fix.md`, README §7.3

## Current state / caveats

- Live fix = only `/etc/cups/wineps.convs`; `cupsd -t` ok; pending queue empty
- Only `adobe-reader-postscript` rerouted; PDF/plain-PS untouched. Encrypted-source Adobe PS may now fail at `gstopdf` instead of `gstoraster` (fail-to-fail)
- Classic-queue Wine chain changes to `gstopdf→pdftopdf→gstoraster→245igdirf` (dry-run ok, no paper test yet — that queue was off-limits)
- Revert: delete `/etc/cups/wineps.convs`, restart CUPS
- Artifacts: `/var/spool/cups/d00019-001`, `/tmp/wine19.ps`, `/tmp/min-ar.ps`, `/var/log/cups/error_log` Jobs 18/19/22/23/24, backup `/etc/cups.bak-2026-10-04-1809`
