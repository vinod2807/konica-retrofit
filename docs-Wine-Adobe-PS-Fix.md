# Wine-Adobe PostScript fix (2026-10-04)

Wine/Acrobat print output that embeds an Adobe block is classified by CUPS as
`application/vnd.adobe-reader-postscript`. That type has no direct-to-PDF
conversion rule, so CUPS forces it through
`pstops -> gstoraster -> rastertopwg -> pwgtopdf` and the job dies with:

```
Ghostscript stopped with status 255
GPL Ghostscript 10.06.0: ERROR: ioerror (-12) on closing pdfwrite device.
gstoraster filter failed.
```

Plain `application/postscript` has a direct `gstopdf -> PDF` rule and prints
fine (Job 22); native PDF needs no conversion and prints fine (Jobs 12-15,
17, 21); the same Wine file prints on the classic queue (Job 20), which
consumes raster directly. Standalone `gs` (any of CompatibilityLevel
1.3/1.7, with/without PDFX3/ICC, as root or `lp`, file/stdin/pipe) always
succeeds, and a minimal `%%Creator: Adobe Acrobat` hello-world file takes the
same `gstoraster` branch and yields a 0-byte PDF — so the branch itself, not
the file content or the sandbox, is broken for PDF-final driverless queues.

## Fix

One no-op MIME retype rule, installed by `install_wineps_convs()` in
`install-konica-anylinux.sh`:

`/etc/cups/wineps.convs` (0644):
```
application/vnd.adobe-reader-postscript application/postscript 0 -
```

This restores the working `gstopdf` path for Wine jobs. No custom filter,
no PPD edit (an earlier `wineps2pdf` + `zz-wineps.convs` workaround was
superseded and removed). Restart is via `restart_cups()`, which falls back
from systemd to `service`/`/etc/init.d/cups` for non-systemd hosts (Puppy).

## Verification

- No-paper: `cupsfilter -i application/postscript -m application/pdf`
  on the failing file → exit 0, ~198 KB PDF, correct text, `gstopdf` only.
- Paper: Job 23 (pre-cleanup, via interim filter) and Job 24
  (`gstopdf+pdftopdf+ipp`, final state) both `Job completed`; owner
  confirmed both printouts. Queue empty afterwards.
- Regressions: plain PS still `gstopdf`; minimal adobe-reader file now
  converts to a non-empty PDF (was 0 bytes); native PDF path untouched.

## Notes / risks

- Only `adobe-reader-postscript` jobs are rerouted. Upstream keeps that
  type out of the PDF workflow deliberately (encrypted sources); an
  encrypted-source file may now fail at `gstopdf` instead of `gstoraster`
  (fail-to-fail, not a regression — it never printed on this queue).
- Classic-queue chain for Wine files changes from
  `pstops->gstoraster->245igdirf` to `gstopdf->pdftopdf->gstoraster->245igdirf`
  (dry-run resolves; not yet confirmed on paper).
- Revert: delete `/etc/cups/wineps.convs` and restart CUPS.
