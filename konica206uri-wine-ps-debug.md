# konica206uri Wine-Adobe PS failure — process, root cause, fix

## 1. Environment

- ResolutePup64 (Puppy, no systemd), CUPS 2.4.16, cups-filters 2.0.1, Ghostscript 10.06.0
- No AppArmor (`aa-status` missing), no journal DENIEDs, `TMPDIR /var/spool/cups/tmp` (`drwxrwx--T root:lp`, `sudo -u lp touch` ok)
- Queues: `konica206uri` (CUPS passthrough -> `ipp://localhost:8000/ipp/print/konica206uri` -> legacy-printer-app PAPPL 1.4.9 -> vendor `245igdirf` -> custom libusb backend); classic `KONICA_MINOLTA_206` (`usb://...serial=A8A6041029423&interface=1`, `pstops+gstoraster+245igdirf+usb`)
- Shim PPD `/etc/cups/ppd/konica206uri.ppd` originally only:
  `application/vnd.cups-pdf -> application/pdf 0 -`, `image/jpeg -> image/jpeg 0 -`, `image/png -> image/png 0 -`

## 2. Failure

- Jobs 18/19: `konica206uri-19 root 541696`, file `AC7401...-DOC_20261002_WA0004.pdf`
- `file`: PostScript DSC 3.0, `%!PS-Adobe-3.0`, `%%Creator: Wine PostScript Driver`, contains `%%BeginDocument: Wine passthrough` + `%%Creator: Adobe Acrobat 26.2.0`
- CUPS: `CONTENT_TYPE=application/vnd.adobe-reader-postscript`, `FINAL_CONTENT_TYPE=application/pdf`; chain `pstops -> gstoraster -> rastertopwg -> pwgtopdf -> pdftopdf -> ipp`
- `error_log`: `Cannot add Metadata to PDF files with version earlier than 1.4`, then `GPL Ghostscript 10.06.0: ERROR: ioerror (-12) on closing pdfwrite device`, `Ghostscript stopped status 255`, `gstoraster filter failed`, `Job stopped due to filter errors`
- gs command (failing): `gs -dQUIET -dSAFER -dNOPAUSE -dBATCH -dNOINTERPOLATE -dNOMEDIAATTRS -dUsePDFX3Profile -sstdout=%stderr -sOutputFile=%stdout -sDEVICE=pdfwrite -dDoNumCopies -dShowAcroForm -dCompatibilityLevel=1.3 -dAutoRotatePages=/None -dAutoFilterColorImages=false -dNOPLATFONTS -dColorImageFilter=/FlateEncode -dPDFSETTINGS=/default -dColorConversionStrategy=/LeaveColorUnchanged -r600x600 -dDEVICEWIDTHPOINTS=595 -dDEVICEHEIGHTPOINTS=842 -dcupsManualCopies -I/usr/share/cups/fonts -sOutputICCProfile=srgb.icc -c -f -_`
- PAPPL `localhost:8000/konica206uri` stayed `Idle, 0 jobs`; printer `idle, gstoraster filter failed`

## 3. Working contrasts

- Job 21 (native app): `File of type application/pdf`, `PDF 1.7 1 page`, chain `pdftopdf+ipp` only, `Job completed`, printed
- Jobs 12-15, 17: PDF, same passthrough, completed
- Job 20 (same Wine-PS bytes, 762880 B, on classic queue): `pstops+gstoraster+245igdirf+usb`, `Job completed`
- Job 22 (trivial `%!PS` hello-world): detected `application/postscript`, chain `gstopdf+pdftopdf+ipp`, `Job completed`
- Manual `gs` always ok (~198 KB): exact CUPS args to file or `%stdout`, `CompatibilityLevel` 1.3/1.7, ±PDFX3/ICC, as root and as `lp` with `TMPDIR=/var/spool/cups/tmp`, file redirect, stdout-pipe to `cat`, and true pipe `pstops|gs|cat` — all exit 0

## 4. Debug process

1. Per `konica206uri-wine-ps-fix.md` Steps 1-3: env cleared (no AppArmor/systemd, perms ok, `gs` as `lp` ok); trivial PS prints -> content/MIME-specific, not environment -> Fix B track.
2. Oracle reproducer (no paper): `cupsfilter -p konica206uri.ppd -m application/pdf /tmp/wine19.ps` fails exit 1 with identical `ioerror (-12)` when fix rule removed; passes with rule present.
3. gs matrix (all exit 0): T1 exact-1.3-PDFX3-ICC stdin->stdout-pipe, T2 1.7, T3 1.3 bare, T4 to file, T5 true-pipe `pstops|gs|cat` — harness-independent `gs` exonerated.
4. Minimal MIME probe: crafted `/tmp/min-ar.ps` (`%!PS`, `%%Creator: Adobe Acrobat`, hello-world) detected as `adobe-reader-postscript`, routed to `gstoraster`, exit 0 but **0-byte PDF**. So the `adobe-reader -> gstoraster -> PDF` branch is broken in general; Wine content just fails loudly.
5. Rule audit: `cupsfilters-ghostscript.convs:16` has `application/postscript -> application/pdf 0 gstopdf` but **no** `adobe-reader-postscript -> pdf` rule (intentional bypass per `cupsfilters-individual.convs` comment about encrypted sources, forcing `pstops` cost 66 + raster roundtrip). PPD-only `*cupsFilter2` lines were ignored by `cupsfilter`/daemon chain resolution in testing; system `mime.convs` rule was honored.

## 5. Root cause

MIME branching gap, not corrupt input or sandbox. Wine-Adobe output is classified `adobe-reader-postscript` (Acrobat marker within 4096 bytes per `cupsfilters.types:75`), which has no direct-to-PDF conversion. It is forced through the raster roundtrip (`gstoraster` pdfwrite-1.3 intermediate -> raster -> `pwgtopdf`), which yields empty output (trivial file) or `ioerror (-12)` close failure (Wine file) on PDF-final driverless chains. Plain `postscript` avoids this via direct `gstopdf`; native PDF avoids conversion entirely; classic queue consumes raster directly via `245igdirf`.

## 6. Fix applied (Fix B)

- `/usr/lib/cups/filter/wineps2pdf` (`root:root 0755`): `gs -q -dSAFER -dBATCH -dNOPAUSE -dCompatibilityLevel=1.7 -sDEVICE=pdfwrite -sOutputFile=- "${6:--}"`
- `/etc/cups/ppd/konica206uri.ppd:26-27` added (per doc; inert in tests but harmless):
  `application/vnd.adobe-reader-postscript -> application/pdf 0 wineps2pdf`
  `application/postscript -> application/pdf 0 wineps2pdf`
- Effective change `/usr/share/cups/mime/zz-wineps.convs` (honored by resolver):
  `application/vnd.adobe-reader-postscript application/pdf 0 wineps2pdf`
  `application/postscript application/pdf 0 wineps2pdf`
- Restart via `/etc/init.d/cups restart` (no systemd); `cupsd -t` ok
- Verify (no paper): `cupsfilter -m application/pdf /tmp/wine19.ps` -> exit 0, `wineps2pdf started/exited ok`, 196216 B PDF
- Verify (paper): `lp -i konica206uri-19 -H restart` -> `Started filter wineps2pdf`, `Started backend ipp`, `Job completed 17:54:12`; `lpstat -W not-completed` empty; owner confirmed printout

## 7. Open points for further analysis

- Why exactly does the `gstoraster` pdfwrite-1.3 close fail (or empty) only under the `cfFilterGhostscript` harness — temp-file lifecycle, logging co-process, downstream EOF timing — given identical CLI passes standalone?
- Is `CompatibilityLevel 1.3 + UsePDFX3Profile` vs embedded XMP Metadata (needs 1.4+) contributory, or incidental (warning appears in passing cases too)?
- Upstream-worthy: should `adobe-reader-postscript -> pdf` direct rule exist (or PPD `cupsFilter2` be honored) for driverless PDF-final printers?
- Risk notes: PPD edit lost if shim regenerated (system convs survives); `postscript` cost-0 tie between `gstopdf` and `wineps2pdf` — consider narrowing system rule to `adobe-reader` only to leave proven plain-PS path untouched.
- Artifacts: `/var/spool/cups/d00019-001` (failing input), `/tmp/wine19.ps`, `/tmp/s1.ps`, `/tmp/min-ar.ps`, `/tmp/oracle-log.txt`, `/var/log/cups/error_log` Jobs 18/19/22, Job 19 completion at 17:54:12.
