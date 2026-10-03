# Konica Minolta 206 — PAPPL/legacy-printer-app raster "ghosting" bug

**Status:** root-caused to a high-confidence hypothesis, **workaround in place**
**Date:** 2026-10-03
**Author:** vinod2807 (with AI assistant)
**Purpose:** this document is written to be handed to other experts/AI systems for
independent review. It contains the full evidence chain, the hypotheses that were
tested and **ruled out**, and an explicit list of open questions (§10).

---

## 1. Executive summary

Two printing paths drive the same physical printer. One produces correct output,
the other produces a visual artefact we call **"ghosting"** — a band across the
lower part of the sheet that repeats content which should not be there.

| Path | Scheduler | Simplex | Duplex (long-edge) |
|---|---|---|---|
| `KONICA_MINOLTA_206` | classic CUPS | **clean** | **clean** |
| `konica206uri` | `legacy-printer-app` (PAPPL) | **ghosts** | **ghosts** |

The single variable that tracks correctness is the **`*ImageableArea`** reported to
the driver:

```
konica206uri    (driverless shim)  *ImageableArea A4: "3.996850393701 11.990551181102 591.27874015748 829.899212598425"   ← 4pt/12pt inset
KONICA_MINOLTA_206 (vendor PPD)     *ImageableArea A4/A4: "0 0 595 842"                                                 ← full page
```

`libpappl` **hardcodes** the inset and ignores every PPD-level override (three
tested, §6). The vendor filter `245igdirf` always declares the **full** sheet in
PJL (`PAPERWIDTH=4958`, `PAPERLENGTH=7016` = 595.0 × 841.9 pt). So on the PAPPL
path the raster the printer receives is geometrically smaller than the page the
printer is told it is, and the mismatch shows up as content in the wrong vertical
region.

The classic queue honours the PPD's `*ImageableArea`, so the vendor's full-page
value makes raster and declared page agree, and output is correct.

**Workaround:** use `KONICA_MINOLTA_206` for all printing. It is now the default.
`konica206uri` is retained only as the CUPS-3.0-proof path.

**We are asking for help with §10** — specifically whether the inset geometry is
really the whole story, because §7 shows the ghost is a *copy of the current
page*, which pure "uninitialised buffer" does not explain.

---

## 2. Environment

| Component | Value |
|---|---|
| OS | Ubuntu 26.04.1 LTS (resolute) |
| Kernel | 7.0.0-38-generic (was 7.0.0-31 at time of initial testing; rebooted mid-investigation) |
| CUPS | 2.4.16-1ubuntu1.3 |
| cups-filters | 2.0.1-0ubuntu4.1 |
| Printer Application | `legacy-printer-app` 1.0~b2-0ubuntu8 (pappl-retrofit 1.0b2) |
| libpappl | 1.4.9-0ubuntu2 |
| Vendor driver | `konica-minolta-245igdi-cups` 2.01 |
| Vendor filter | `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf` |
| Filter SHA-256 | `0548f3f3e20fae1e604e3bbe5464aedf5fbd8ff283f8173359f56153ce98a4d3` |
| Filter build | ELF 64-bit LSB x86-64, dynamically linked, not stripped |
| `driverless` | `/usr/bin/driverless` (cups-filters 2.0.1) |

### Printer

| Property | Value |
|---|---|
| Model | Konica Minolta 206 (bizhub 206i class), GDI laser |
| USB VID:PID | `132b:232b` |
| USB serial | `A8A6041029423` |
| Interface / endpoint | interface 1, bulk OUT `0x01` |
| Device URI | `usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1` |

### Architecture

```
GUI app / lp
    │  PDF
    ▼
CUPS 2.4.16
    ├── queue KONICA_MINOLTA_206 ──► usb backend ──► 245igdirf ──► USB   [WORKS]
    └── queue konica206uri ──► IPP ──► legacy-printer-app (PAPPL 1.4.9)
                                        │  application/vnd.cups-raster
                                        ▼
                                     245igdirf ──► custom libusb backend ──► USB  [GHOSTS]
```

The PAPPL path uses a repo-provided custom USB backend
(`/usr/local/libexec/konica-backend/usb`, libusb-only, no libcups, writes in
≤8192-byte chunks) because the classic CUPS USB backend wedge the printer on
large writes.

---

## 3. What was implemented (before the bug was found)

The repository `vinod2807/konica-retrofit` was installed on a clean Ubuntu 26.04
machine. Four installer bugs had to be fixed first (details in that repo's
README §7.1):

1. **`avahi-daemon` not running** → PAPPL aborts at startup with
   `Unable to register system, is the Avahi daemon running?`
2. **`wait_for_app()` deadlock** — it waited for the queue that `create_queues()`
   is supposed to create, so on a fresh machine it always timed out and silently
   skipped queue creation.
3. **Stale hardcoded driver name** — `legacy-printer-app drivers` lists user-added
   PPDs with an extra `-user-added` token (`...-retrofit-user-added-en`) but
   `legacy-printer-app add -m` only accepts the plain name (`...-retrofit-en`).
4. **`konica206uri-ppd` aborted every job** — it used the PAPPL *driver* PPD whose
   `*cupsFilter: ... 245igdirf` made CUPS run the GDI filter locally, so PAPPL
   received `application/vnd.printer-specific` instead of raster.

Paper handling per the owner's requirements: **A4 + one-sided (simplex) as
default**, duplex selectable, **24 paper sizes**, **no borderless sizes**.

The CUPS-facing shim PPD is generated with `driverless` from the Printer
Application, as requested:

```
$ driverless ipp://localhost:8000/ipp/print/konica206uri > shim.ppd
  24 *PageSize entries
  *DefaultPageSize: A4
  *DefaultDuplex:   None
  0 matches for /bleed|borderless/i
```

---

## 4. The bug

### 4.1 Symptom

Printed pages carry a **band of repeated content across the lower portion of the
sheet**, in the region that should be blank.

Two independent observations:

**(a) Duplex, 2-page test** (`ghost.pdf`: page 1 = black bar on the **left**,
page 2 = black bar on the **right**). Both sides of the sheet show their own page
*plus* faint leftover content from the other page. Scanning both sides showed the
extra bars sit at opposite edges of the sheet — consistent with a single extra
printed band near the sheet edge appearing on both faces.

**(b) Real 1-page PDF** (`4_Door_and_Saftey_Grill_Quotation.pdf`, a quotation
document). Printed **duplex, first 2 pages**. Page 1: the quotation renders
correctly — letterhead, item table (Door / Safety Grill / Front Door / Ladder /
Setwork), Sub Total, GST 18%, Total, and the sign-off — then a **band across the
bottom repeats the same page's `4. Ladder | - | - | - | 5,000` row**.

*(A scan of this sheet was the reference image for this report. On request it can
be re-supplied; the textual description above is sufficient to reproduce.)*

### 4.2 The critical observation

In case (b) the ghosted content is a copy of **the current page's own middle
section**, *not* data left over from a previous job. This rules out a simple
"stale buffer between jobs" explanation and means the page image itself is being
rendered into the wrong vertical extent — the printer is wrapping or
mis-positioning part of the raster.

### 4.3 It is not duplex-specific

A controlled A/B on the quotation PDF, byte-identical options, only the queue
differing:

```
lp -d konica206uri      -o sides=one-sided -o PageSize=A4 quotation.pdf
lp -d KONICA_MINOLTA_206 -o sides=one-sided -o PageSize=A4 quotation.pdf
```

| CUPS job | Queue | Result |
|---|---|---|
| `konica206uri-303` | PAPPL | **ghost** |
| `KONICA_MINOLTA_206-305` | classic | **clean** |

Simplex on `konica206uri` is affected too. (An earlier revision of this document
wrongly recorded this as duplex-only, from misreading which job produced a sample
scan. The A/B above is the corrected result.)

---

## 5. Root-cause analysis

### 5.1 The geometry mismatch

`245igdirf` emits, per page:

```
@PJL SET PAPER=A4
@PJL SET PAPERWIDTH=4958
@PJL SET PAPERLENGTH=7016
@PJL SET RESOLUTION=600
```

`4958 / 600 × 72 = 595.0 pt` and `7016 / 600 × 72 = 841.9 pt` — i.e. the **full
A4 sheet** (595.28 × 841.89 pt), at 600 dpi, with `PAPERWIDTH`/`PAPERLENGTH`
expressed in 1/600-inch units.

The raster it receives is **not** full A4 on the PAPPL path:

```
*ImageableArea A4: "3.996850393701 11.990551181102 591.27874015748 829.899212598425"
                  └ 4.0pt L          └ 12.0pt B          └ 591.3 R        └ 829.9 T
```

So the printer is told the page is a full A4 sheet, but the image covers an area
inset by 4 pt left/right and 12 pt top/bottom. The two disagree about where the
bottom of the image lies, and content lands in a band it should not occupy.

### 5.2 libpappl ignores the PPD

Three separate PPD-level attempts to make the PAPPL path use full-page geometry.
In every case the regenerated `driverless` shim was **byte-identical**:

| PPD change | shim `*ImageableArea A4` after restart |
|---|---|
| baseline | `"3.996850393701 11.990551181102 591.27874015748 829.899212598425"` |
| `*ImageableArea A4/A4: "0 0 595 842"` | *unchanged* |
| `*DefaultUseHWMargins: False` | *unchanged* |
| `*HWMargins: 0 0 0 0` (explicit) | *unchanged* |

Source confirmation — `pappl-retrofit/pappl-retrofit.c` reads `cupsBackSide` but
nothing sets `ImageableArea` from the PPD's value in this path:

```c
/* pappl-retrofit.c:1874 */
ppd_attr = ppdFindAttr(ppd, "cupsBackSide", NULL);
```

The inset appears to be a fixed PAPPL default (the driverless-generated shim
reports the same numbers for every paper size, scaled proportionally, which is
consistent with a constant default margin rather than a per-device value).

### 5.3 The classic queue is clean for a structural reason

`cupsd` **does** honour `*ImageableArea`. With the vendor's full-page value the
raster matches `PAPERWIDTH`/`PAPERLENGTH` exactly, and output is correct. Proof by
injecting the inset value into the classic queue's PPD:

| Queue | `*ImageableArea A4/A4` | Duplex long-edge |
|---|---|---|
| `KONICA_MINOLTA_206` | `"0 0 595 842"` (vendor) | **clean** (jobs 288, 296) |
| `KONICA_MINOLTA_206` | `"6 12 589 830"` (inset, injected) | **ghost** (job 295) |
| `konica206uri` | inset (forced by libpappl) | **ghost** (jobs 6, 294) |

The ghost follows the *geometry*, not the queue.

### 5.4 Plausible mechanism

Most likely: the JBIG-compressed raster is written with a plane/band geometry
derived from the imageable area, while the printer's page canvas is sized from
`PAPERLENGTH`. The mismatch causes the decoder to continue past the intended end
of the image, wrapping or re-emitting already-decoded scanlines into the
remaining strip of the page — producing a band that repeats content from earlier
in the same page.

This is consistent with §4.2 (the ghost is a copy of the current page) and with
the ghost appearing at a **sheet edge** in the duplex case.

---

## 6. Hypotheses tested and RULED OUT

Recorded so they are not re-investigated.

| # | Hypothesis | Test | Result |
|---|---|---|---|
| 1 | Duplex mechanically broken (printer can't flip) | owner inspected output | **Refuted.** Flip works; 1 sheet out, page 2 on the correct reverse. |
| 2 | Hardware lacks a duplexer | owner inspected output | **Refuted.** Duplex flip verified working; and it only fails on one queue. |
| 3 | Stream corruption from a mid-stream `EOJ` | parsed all `IMAGELEN` frames | **Refuted as *the* cause** — see §7. A structurally clean stream still ghosted (Draft job). |
| 4 | `cupsBackSide` rotation | `Rotated` vs `Normal` vs removed | **Refuted.** Only changes *binding* (`Rotated`=long-edge, `Normal`=short-edge). Ghost present in all three. |
| 5 | Resolution / data volume | Draft (lower res) vs Normal | **Refuted.** Draft produced a clean single-`EOJ` stream and *still* ghosted. |
| 6 | Band framing / `IMAGELEN` accounting | full parser, §7 | **Refuted.** Frames accounted for correctly; and a clean stream ghosted. |
| 7 | `*DefaultUseHWMargins` | set `False` | **Refuted.** No effect on reported geometry. |
| 8 | Explicit `*HWMargins` | `*HWMargins: 0 0 0 0` | **Refuted.** No effect on reported geometry. |
| 9 | Driver-name / queue selection mismatch | verified PPD paths, `cupsFilter` | **Refuted.** Both queues use the same `245igdirf` binary. |
| 10 | Kernel / USB transport | rebooted into 7.0.0-38 | **Refuted.** Reproduces identically on the new kernel. |
| 11 | `cupsCompression` / JBIG choice | inspected OCM | **Inconclusive** — `COMPRESS=JBIG` is emitted by the vendor OCM with no PPD knob found to change it. **Still open, see §10 Q3.** |

---

## 7. Stream analysis (data, not speculation)

A frame parser was written to walk the PJL stream, treating each
`@PJL SET IMAGELEN=n` as exactly `n` bytes of following data. Verbatim output for
the 2-page duplex ghost job:

```
@PJL SET COMPRESS=JBIG
@PJL SET COVER=OFF
@PJL SET HOLD=OFF
@PJL SET SECTION=OFF
@PJL SET COPIES=1
@PJL SET PAGESTATUS=START
@PJL SET DUPLEX=ON
@PJL SET BINDING=SHORTEDGE
@PJL SET PAPER=A4
@PJL SET PAPERWIDTH=4958
@PJL SET PAPERLENGTH=7016
@PJL SET MEDIASOURCE=AUTO
@PJL SET MEDIATYPE=PLAIN
@PJL SET RESOLUTION=600
@PJL SET IMAGELEN=32768   [+32768 bytes data]
@PJL SET IMAGELEN=8344    [+8344 bytes data]
@PJL SET PAGESTATUS=END
@PJL SET PAGESTATUS=START
@PJL SET DUPLEX=ON
@PJL SET BINDING=SHORTEDGE
@PJL SET PAPER=A4
@PJL SET PAPERWIDTH=4958
@PJL SET PAPERLENGTH=7016
@PJL SET MEDIASOURCE=AUTO
@PJL SET MEDIATYPE=PLAIN
@PJL SET RESOLUTION=600
@PJL SET IMAGELEN=32768   [+32768 bytes data]
@PJL SET IMAGELEN=11444   [+11444 bytes data]
@PJL SET PAGESTATUS=END
'@PJL EOJ'                                    ← end-of-job + UEL appears here
@PJL SET IMAGELEN=31844   [+31844 bytes data]
@PJL SET PAGESTATUS=END
'@PJL EOJ'
TOTAL FILE BYTES: 148621
```

Two anomalies:

1. **`@PJL EOJ` + `\x1b%-12345X` (UEL) appears mid-job**, after page 2's second
   frame, with ~30 KB of image data following it and no valid header. Total
   unaccounted bytes: 30714. This looks like the driver's async encode queue
   (`EncodeQueueWrite` / `ChunkExtendWrite` symbols are present in the OCM)
   flushing after the trailer.
2. **Frame sizes are asymmetric between pages**: page 1 = `[32768, 8344]`
   (41112 B), page 2 = `[32768, 11444]` + trailing `[31844]`. For two pages of
   near-identical black-bar content this is a large discrepancy.

**However, anomaly 1 is not the cause of the ghost**: the Draft-quality job
produced a structurally clean stream (single `EOJ`, 21 trailing bytes = just the
UEL) and *still ghosted*. Both anomalies are reported here because they may be a
*second*, independent defect, or may be a symptom of the same root cause.

Note also: the ghost appears on **simplex**, where there is only one page and no
"previous page" at all. This further decouples the ghost from the `EOJ`
anomaly.

---

## 8. Current working configuration

```
$ lpstat -d
system default destination: KONICA_MINOLTA_206

$ lpoptions -p KONICA_MINOLTA_206 | tr ' ' '\n' | grep -E '^(sides|media|PageSize|print-color-mode)='
media=iso_a4_210x297mm
PageSize=A4
print-color-mode=monochrome
sides=one-sided

$ lpoptions -p KONICA_MINOLTA_206 -l | grep -iE 'duplex|^PageSize'
PageSize/Paper Size: A3 *A4 A5 A6 B4 B5 B6 Letter Statement Legal Tabloid Executive
  16K 8K Comm10 EnvPersonal EnvC6 EnvDL FabFoldGermanLegal FLS_220X330
  FLS_8D125X13D25 FLS_8X13 FLS_8D25X13 FLS_8D5X13D5          (24 sizes)
Duplexer/Duplex Unit: *true false
Duplex/Double Sides: *None DuplexNoTumble DuplexTumble
```

Usage:

```bash
# simplex (A4, one-sided) — the defaults
lp -d KONICA_MINOLTA_206 file.pdf

# duplex, long edge
lp -d KONICA_MINOLTA_206 -o sides=two-sided-long-edge file.pdf

# duplex, short edge
lp -d KONICA_MINOLTA_206 -o sides=two-sided-short-edge file.pdf

# other sizes (24 available)
lp -d KONICA_MINOLTA_206 -o PageSize=A5 file.pdf
lp -d KONICA_MINOLTA_206 -o PageSize=Legal file.pdf
```

All four combinations (simplex / long-edge / short-edge / non-default size) plus
a bare-defaults job have been confirmed **on paper** by the owner.

---

## 9. How to reproduce

**Ghost (PAPPL path):**
```bash
F=/path/to/quotation.pdf
lp -d konica206uri -o sides=one-sided -o PageSize=A4 "$F"     # simplex ghosts too
lp -d konica206uri -o sides=two-sided-long-edge "$F"          # duplex ghosts
```

**Clean (classic path):**
```bash
lp -d KONICA_MINOLTA_206 -o sides=one-sided -o PageSize=A4 "$F"          # clean
lp -d KONICA_MINOLTA_206 -o sides=two-sided-long-edge "$F"               # clean
```

**Minimal synthetic test** (`ghost.pdf`, 2 pages, page 1 bar left, page 2 bar
right) — makes ghosting unambiguous:
```bash
printf '%%!PS-Adobe-3.0\n%%%%BoundingBox: 0 0 595 842\n%%%%Page: 1 1\ngsave 0 setgray 60 100 200 640 rectfill grestore showpage\n%%%%Page: 2 2\ngsave 0 setgray 330 100 205 640 rectfill grestore showpage\n%%%%EOF\n' > ghost.ps
gs -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -sOutputFile=ghost.pdf ghost.ps
```

**Inspect reported geometry:**
```bash
driverless ipp://localhost:8000/ipp/print/konica206uri | grep -E '^\*ImageableArea A4:|^\*PaperDimension A4:'
grep '^\*ImageableArea A4/A4:' /etc/cups/ppd/KONICA_MINOLTA_206.ppd
```

---

## 10. Open questions — please review

These are what we would most like a second opinion on.

**Q1. Is the geometry mismatch sufficient to explain a *copy of the same page*
appearing in a lower band?** Our working theory is that the raster plane geometry
and the page canvas disagree, so the JBIG decoder continues past the intended
image end and re-emits scanlines. But a pure "uninitialised buffer" story does
*not* explain repeated content, and the ghost occurs on single-page simplex jobs
where no previous page exists. **Is there a more likely mechanism we have missed —
e.g. the driver computing band height from the imageable area while the printer
derives canvas height from `PAPERLENGTH`, causing a partial wrap?**

**Q2. Where exactly does libpappl's 4 pt / 12 pt default margin come from?**
It is identical for every paper size and immune to `*ImageableArea`,
`*DefaultUseHWMargins` and `*HWMargins`. Is this a hardcoded
`ppd->default_imageable_area` fallback, a CUPS `cupsDefaultMargin`, or a
`ppd-cups` quirk? **Is there any supported way to make PAPPL report the PPD's
`ImageableArea`?** If yes, the bug is fixable without changing queues.

**Q3. Could disabling JBIG compression avoid it?** `COMPRESS=JBIG` is emitted
from the vendor OCM. We found no PPD/OCM knob to change it. If the wrap is a
JBIG-plane artefact, uncompressed or CCITT G4 output might avoid it — worth
knowing before filing upstream.

**Q4. Is the mid-stream `@PJL EOJ` + ~30 KB orphaned data a separate bug?** It
appears in some duplex streams but not all, and a clean stream still ghosted. We
suspect a race in the driver's async encode queue. **Is this worth a separate
upstream report to Konica/OpenPrinting, and does it plausibly share a root cause
with Q1?**

**Q5. Should this be reported upstream, and to whom?** The most likely candidates
are (a) `OpenPrinting/pappl-retrofit` — `*ImageableArea` not honoured, and (b)
`OpenPrinting/libpappl` — hardcoded default margins. We have a minimal
reproducer and a clean A/B. **Is there prior art on this?**

**Q6. Is the "real margins" retrofit worth keeping at all?** The vendor PPD
declares full-page `ImageableArea` for this printer. The repo's retrofit PPDs
change it to `6 12 W-6 H-12` (and PAPPL originally *rejected* the zero-margin
geometry outright — see the repo's design doc, Issue 2, error
`Invalid driver left/right margins value -70`). Given that any inset geometry
breaks output on this printer, **is the retrofit's margin change actively harmful
here, and should the vendor full-page value be used everywhere?**

---

## 11. Artefacts and file inventory

| Path | Role |
|---|---|
| `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-real-margins.ppd` | PAPPL driver PPD (real margins). Inset `ImageableArea` is what libpappl reports. |
| `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd` | PAPPL driver PPD (vendor full-page geometry) |
| `/etc/cups/ppd/KONICA_MINOLTA_206.ppd` | classic queue PPD — vendor full-page `ImageableArea`, `*DefaultDuplex: None` |
| `/usr/local/share/konica206uri/konica206uri-driverless.ppd` | the `driverless`-generated shim (24 sizes, A4, `*DefaultDuplex: None`) |
| `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf` | vendor GDI filter (patchelf'd against vendored libcups) |
| `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/mtorf.ocm` | vendor OCM config (source of `COMPRESS=JBIG`) |
| `/usr/local/libexec/konica-backend/usb` | custom chunked libusb backend used by PAPPL |
| `/usr/local/bin/ensure-konica206uri.sh` | persistence helper, wired as `ExecStartPost` |
| `/var/spool/legacy-printer-app/debug-jobdata-konica206uri-*.prn` | PAPPL job streams (PJL + JBIG), used for §7 |
| `/var/log/unattended-upgrades/unattended-upgrades.log` | confirmed no printing package was upgraded on 2026-10-03 |

Debug streams can be parsed with:

```python
import re
d = open('/var/spool/legacy-printer-app/debug-jobdata-konica206uri-N.prn','rb').read()
i, n, out = 0, len(d), []
while i < n:
    if d[i:i+9] == b'@PJL SET ':
        j = d.find(b'\r\n', i)
        if j < 0: break
        line = d[i:j].decode('latin1')
        m = re.match(r'@PJL SET IMAGELEN=(\d+)', line)
        if m:
            ln = int(m.group(1)); out.append(f'{line}   [+{ln} bytes]'); i = j+2+ln; continue
        out.append(line); i = j+2
    elif d[i:i+5] == b'@PJL ':
        j = d.find(b'\r\n', i)
        if j < 0: break
        out.append(repr(d[i:j].decode('latin1'))); i = j+2
    else:
        i += 1
print('\n'.join(out))
```

> Caution for anyone re-running this: naive regex over the stream produces **false
> positives**, because JBIG-compressed binary can contain byte sequences that look
> like PJL directives. Always consume exactly `IMAGELEN` bytes after each
> `IMAGELEN=` directive.

---

## 12. Timeline of the investigation

| Step | Action | Outcome |
|---|---|---|
| 1 | Installed repo on clean Ubuntu 26.04 | 4 installer bugs found and fixed |
| 2 | Configured A4 + simplex default, 24 sizes, driverless shim PPD | simplex verified clean (data-stream level) |
| 3 | Duplex verified from **job data only** — `DUPLEX=ON`, `BINDING=SHORTEDGE`, correct page count | **false confidence** — data stream looked right |
| 4 | Owner printed a real duplex document | ghost reported |
| 5 | A/B: `konica206uri` vs `KONICA_MINOLTA_206` | classic clean, PAPPL ghosts → path-specific |
| 6 | Tested `cupsBackSide` Rotated/Normal | only changes binding; ghost persists |
| 7 | Tested Draft resolution | clean stream, still ghosts → stream corruption refuted |
| 8 | Parsed all `IMAGELEN` frames | found mid-stream `EOJ` + 30 KB orphaned data |
| 9 | Switched default to classic queue; verified duplex long-edge on real docs | working configuration |
| 10 | Owner reported ghost on a **1-page PDF** | initially misread as simplex-only |
| 11 | Controlled A/B, identical options, both queues, **simplex** | ghost on PAPPL for simplex too; classic clean |
| 12 | Rebooted into kernel 7.0.0-38; re-verified | reproduces identically — kernel-independent |

**The main lesson:** steps 3–4. Job-data inspection (`DUPLEX=ON`, correct page
count, filter exit status 0) was *necessary but not sufficient*. Every duplex
defect found here was invisible in the data stream and only appeared on paper.