# konica206uri Wine-PS failure — symptoms for diagnosis

## Setup

- OS: Ubuntu 26.04, CUPS 2.4.16, cups-filters 2.0.1, Ghostscript 10.06.0
- CUPS queue `konica206uri` -> `DeviceURI ipp://localhost:8000/ipp/print/konica206uri`
  -> `legacy-printer-app` PAPPL 1.4.9 -> vendor `245igdirf` -> custom libusb backend
- PPD `/etc/cups/ppd/konica206uri.ppd` driverless shim, only passthrough:
  - `*cupsFilter2: "application/vnd.cups-pdf application/pdf 0 -"`
  - `*cupsFilter2: "image/jpeg image/jpeg 0 -"`
  - `*cupsFilter2: "image/png image/png 0 -"`

## Failing job (18, 19 repeatable)

- `lpstat`: `konica206uri-19 root 541696 — Status: cfFilterGhostscript Ghostscript PID 13009 stopped status 255, job-completed-with-errors`
- `file /var/spool/cups/d00019-001`: `PostScript DSC 3.0`, `%!PS-Adobe-3.0`, `%%Creator: Wine PostScript Driver`, `%%Title: AC7401B743FA3F5AF14D972CF11A1B74-DOC_20261002_WA0004.pdf`
- Contains `%%BeginDocument: Wine passthrough` + `%ADO_BeginApplicationHeaderComments` / `%%Creator: Adobe Acrobat 26.2.0`
- CUPS detects: `CONTENT_TYPE=application/vnd.adobe-reader-postscript`, `FINAL_CONTENT_TYPE=application/pdf`
- Chain: `pstops -> gstoraster -> rastertopwg -> pwgtopdf -> pdftopdf -> ipp`
- `error_log`:
  - `cfFilterGhostscript command: gs -dQUIET -dSAFER -dNOPAUSE -dBATCH -dNOINTERPOLATE -dNOMEDIAATTRS -dUsePDFX3Profile -sstdout=%stderr -sOutputFile=%stdout -sDEVICE=pdfwrite -dDoNumCopies -dShowAcroForm -dCompatibilityLevel=1.3 -dAutoRotatePages=/None -dAutoFilterColorImages=false -dNOPLATFONTS -dColorImageFilter=/FlateEncode -dPDFSETTINGS=/default -dColorConversionStrategy=/LeaveColorUnchanged -r600x600 -dDEVICEWIDTHPOINTS=595 -dDEVICEHEIGHTPOINTS=842 -dcupsManualCopies -I/usr/share/cups/fonts -sOutputICCProfile=srgb.icc -c -f -_`
  - `Cannot add Metadata to PDF files with version earlier than 1.4.`
  - `GPL Ghostscript 10.06.0: ERROR: ioerror (-12) on closing pdfwrite device.`
  - `PID gstoraster stopped status 1, printer-state-message="gstoraster filter failed", Job stopped due to filter errors.`
- PAPPL `localhost:8000/konica206uri` stays `Idle, 0 jobs`. Job never reaches printer.

## Working contrasts

- Job 21 same queue: `File of type application/pdf`, `d00021-001: PDF 1.7 1 page`, chain `pdftopdf+ipp` only, `Job completed`, printed.
- Jobs 12-15, 17: PDF, `pdftopdf+ipp` only, completed.
- Job 20 same Wine-PS type (`762880 B` PostScript) on classic queue `KONICA_MINOLTA_206` (`pstops+gstoraster+245igdirf+usb`): `Job completed`.
- Manual repro as root succeeds (exit 0, ~198 KB PDF):
  - `gs [exact CUPS args above with -sOutputFile=/tmp/x.pdf] -c -f d00019-001` -> ok
  - `gs [same to %stdout] > file` -> ok
  - `pstops 19 ... d00019-001 | gs ...` -> ok (pipe-exit 0,0)

## Question

Why does Ghostscript `pdfwrite` to stdout fail only inside the CUPS daemon multi-filter pipe for this Wine-PS, while succeeding standalone and while PDF passthrough works?
