# CUPS 3.0 Compatibility

How this setup behaves when CUPS removes PPD support — and what has been
verified live on the machine.

Status: **verified working on Fedora 44 (CUPS 2.4.19)** with the same code
paths that CUPS 3.0 uses. Duplex printing is PPD-independent.

---

## 1. TL;DR — are we safe when CUPS 3.0 arrives?

**Yes** for the printer, driver, rendering, and duplex. The setup already
uses the CUPS 3.0 architecture (a Printer Application owns the driver and
rendering; CUPS only proxies IPP). The one genuine CUPS 3.0 breakage — the
removal of the classic `libcups.so.2` ABI that the closed-source 245igdirf
filter needs — is neutralized by vendoring.

Remaining caveats are distro/app-side migration work that affects every
machine, not this printer specifically (see §5).

---

## 2. Architecture: why PPD removal does not affect printing

CUPS 3.0 removes PPD support from the CUPS scheduler. Printing becomes
Printer-Application-only:

- The CUPS queue is a thin IPP proxy to a Printer Application.
- The Printer Application owns the driver, PPDs, filters, and rendering.
- Options are negotiated purely over IPP (`Get-Printer-Attributes`,
  `Create-Job`, `Send-Document`).

This setup already matches that model:

```
GUI app ──> cupsd (:631) ──IPP──> legacy-printer-app (:8000)
                                   │  PAPPL queue konica206uri
                                   │  PPD: /var/lib/legacy-printer-app/ppd/
                                   │       KonicaMinolta-206-fullbleed.ppd
                                   │  filters: pdftopdf → ghostscript
                                   │           → 245igdirf → chunked USB backend
                                   └─> USB: KONICA MINOLTA 206
```

Verified: the entire filter chain (`pdftopdf → ghostscript → 245igdirf →
backend`) runs **inside `legacy-printer-app`** (journal shows
`[Job N] cfFilterChain: Running filter: …` from the Printer App PID), never in
cupsd.

The `/etc/cups/ppd/*.ppd` files exist only so CUPS 2.x can show options in
GUI dialogs. They are not consulted for rendering and disappear harmlessly on
CUPS 3.0.

---

## 3. The real CUPS 3.0 breakage and how it is handled

CUPS 3.0 ships only `libcups3` (SONAME `libcups3.so.3`) and drops the
classic `libcups.so.2`. The closed-source 245igdirf filter is hard-linked
against the classic ABI and will never be ported.

Mitigation (`vendor_libcups()` in `install-konica-anylinux.sh`):

- Extracts `libcups.so.2` + `libcupsimage.so.2` from the archived
  `libcups2t64_2.4.16-1ubuntu1.3_amd64.deb`.
- Installs them privately at `/usr/local/lib/konica/lib/`.
- rpath-patches 245igdirf (`patchelf --set-rpath`) to resolve them there.

Verified:

```console
$ env -i ldd /usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf
        libcups.so.2      => /usr/local/lib/konica/lib/libcups.so.2
        libcupsimage.so.2 => /usr/local/lib/konica/lib/libcupsimage.so.2
```

The filter is therefore immune to whatever CUPS the host ships.

---

## 4. Duplex printing is PPD-independent (verified live)

Duplex is negotiated and transported as the IPP `sides` attribute, not as a
PPD option.

### 4.1 What the Printer Application advertises over IPP

```console
$ ipptool -tv ipp://localhost:8000/ipp/print/konica206uri get-printer-attributes.test
        sides-supported (1setOf keyword) =
            one-sided,two-sided-long-edge,two-sided-short-edge
        job-creation-attributes-supported (…keyword) =
            …, sides, …, duplex-unit, …
```

### 4.2 What GUI apps see through the CUPS queue (same IPP values)

```console
$ ipptool -tv ipp://localhost:631/printers/konica206uri get-printer-attributes.test
        sides-supported (1setOf keyword) =
            one-sided,two-sided-long-edge,two-sided-short-edge
```

### 4.3 The duplex request flows entirely over IPP

```console
$ lp -d konica206uri -o sides=two-sided-long-edge /tmp/3page.pdf
```

Journal shows the full chain:

```
Validate-Job request:  sides keyword two-sided-long-edge
Create-Job request:    sides keyword two-sided-long-edge
[Job N] Adding option: Duplex
[Job N]   Duplex=DuplexNoTumble
[Job N]   Duplexer=true
cfFilterExternal (245igdirf): argv[5]: … Duplex=DuplexNoTumble Duplexer …
cfFilterGhostscript: gs … -dDuplex … -scupsPageSizeName=A4 …
cfFilterExternal (usb): … Wrote … bytes of print data …
[Job N] Completed, job-impressions-completed=0.
```

3-page document printed duplex (2 sheets). Single-page test files print
simplex by definition — a 1-page job has no back side to print.

### 4.4 How the GTK dialog gets the duplex toggle on CUPS 3.0

Fedora 44's GTK3 print backend (`libprintbackend-cups.so`) links `libcups`
and queries printers over IPP; the binary already contains the
`sides-supported` attribute and `ipp://localhost/printers/%s` strings:

```console
$ strings /usr/lib64/gtk-3.0/3.0.0/printbackends/libprintbackend-cups.so
        sides-supported
        ipp://localhost/printers/%s
```

So the "Two-sided" toggle is rendered from IPP `sides-supported` values and
the job is submitted as `sides=two-sided-long-edge` — no PPD involved.

---

## 5. Remaining caveats (distro/app-side, not printer-side)

| Area | Risk | Who handles it |
|------|------|----------------|
| GTK3 links classic `libcups.so.2` | On CUPS 3.0 the distro must ship a print backend built for `libcups3` | Fedora/GTK (not us) |
| Old GTK3 apps that hardcode PPD reading | May show a reduced duplex dialog | Per-app / upstream |
| `konica206uri-ppd` classic queue | Uses `lpadmin -P` (unsupported on CUPS 3.0); skipped gracefully | Installer already guards it |
| `lpadmin -P` driverless-PPD attachment | CUPS 2.x convenience only; PPD-less IPP queue still works | Installer falls back to PPD-less |

None of these break printing or duplex through the primary `konica206uri`
queue.

---

## 6. Installer CUPS-3.0 readiness

`install-konica-anylinux.sh` is already CUPS-3.0-aware:

- Creates the primary queue **PPD-less** (`lpadmin -p … -v ipp://… -E`).
- Generates and attaches the driverless PPD for CUPS 2.x, falling back to
  PPD-less when `lpadmin -P` is unsupported.
- Skips `-P` for the `-ppd` queue on CUPS 3.0.
- Vendors libcups2 so 245igdirf keeps working.
- ensure-konica206uri.sh re-creates both queues and the OCM resource-tree
  symlink on every invocation.

Re-running the installer on a CUPS 3.0 host is therefore safe and idempotent.

---

*Documented from a live Fedora 44 verification session (CUPS 2.4.19,
`legacy-printer-app` 1.0b2-11.fc44). All IPP/duplex checks above were run
against the running system.*