# Konica Minolta 206 — PAPPL "ghosting" bug: root cause and fix

**Status:** **root-caused and fixed**, verified on paper
**Date:** 2026-10-03
**Supersedes:** the earlier "geometry mismatch, root cause not fully explained"
draft of this document. Two of its claims were wrong; see §9.

---

## 1. Summary

Printed pages from the Printer Application queue (`konica206uri`) carried a
**ghost** — a band across the lower part of the sheet repeating content that
should not be there. It affected simplex and duplex alike.

**Root cause:** `245igdirf` always declares the **full** sheet in PJL
(`PAPERWIDTH=4958`, `PAPERLENGTH=7016`), but the raster it receives is sized
from the media collection's *imageable area*, which comes from the driver PPD's
`*ImageableArea`. When that value is inset, the raster is **shorter and narrower
than the canvas the printer was told about**, so the image is rendered into the
wrong vertical extent and already-decoded scanlines reappear lower down.

**Fix:** force `*ImageableArea` to equal `*PaperDimension` for **every** paper
size in the PAPPL driver PPD. The installer now does this automatically and
verifies it.

Measured, same filter, same document, two queues:

| Path | Raster fed to `245igdirf` | PJL canvas | Result |
|---|---|---|---|
| PAPPL, inset `ImageableArea` | **4860 × 6816** | 4958 × 7016 | **ghost** (height 200px / 2.9% short) |
| PAPPL, full-page `ImageableArea` | **4961 × 7016** | 4958 × 7016 | **clean** |
| Classic CUPS, full-page `ImageableArea` | **4961 × 7016** | 4958 × 7016 | **clean** |

---

## 2. Environment

| Component | Value |
|---|---|
| OS / kernel | Ubuntu 26.04.1 LTS / 7.0.0-38-generic |
| CUPS / cups-filters | 2.4.16-1ubuntu1.3 / 2.0.1-0ubuntu4.1 |
| Printer Application | `legacy-printer-app` 1.0~b2-0ubuntu8 (pappl-retrofit 1.0b2) |
| libpappl | 1.4.9-0ubuntu2 |
| Vendor driver | `konica-minolta-245igdi-cups` 2.01 |
| Vendor filter | `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf` |
| Filter SHA-256 | `0548f3f3e20fae1e604e3bbe5464aedf5fbd8ff283f8173359f56153ce98a4d3` |
| Printer | Konica Minolta 206, USB `132b:232b`, serial `A8A6041029423`, interface 1 |
| Paper loaded | A4 only (the printer errors on other sizes without the paper) |

```
CUPS ─┬─ konica206uri ──IPP──► legacy-printer-app ──raster──► 245igdirf ──► libusb backend ──► USB
      └─ KONICA_MINOLTA_206 ───────────────────────────────► 245igdirf ──► cups usb backend ──► USB
```

---

## 3. The defect, in numbers

### 3.1 What the driver declares (identical on both paths)

```
@PJL SET PAPER=A4
@PJL SET PAPERWIDTH=4958
@PJL SET PAPERLENGTH=7016
@PJL SET RESOLUTION=600
```

`4958 / 600 × 72 = 595.0 pt`, `7016 / 600 × 72 = 841.9 pt` → the **full A4 sheet**
(595.28 × 841.89 pt), with the dimensions expressed in 1/600-inch units.

### 3.2 What the raster actually was

Captured by temporarily wrapping `245igdirf` and `tee`-ing its stdin. The
vendor filter's input is **not** CUPS raster (magic `3SaR`), so the geometry
fields were located by scanning for plausible values rather than by a fixed
struct offset. Two `u32` fields sit at offsets 376 and 380:

| Path | field @376 | field @380 | vs canvas 4958 × 7016 |
|---|---|---|---|
| PAPPL, inset | 4860 | **6816** | width −98 px (2.0%), height **−200 px (2.9%)** |
| Classic / fixed PAPPL | 4961 | **7016** | width +3 px (0.06%), height **exact** |

### 3.3 Why the inset appeared — the job's own `media-col`

The filter's argv carries the exact media collection PAPPL resolved:

```
media-col={media-key=iso_a4_210x297mm_auto_plain
           media-size={x-dimension=21000 y-dimension=29700}
           media-bottom-margin=423 media-left-margin=212
           media-right-margin=212 media-top-margin=423 ...}
```

All in 1/100 mm:

```
imageable = (21000 − 212 − 212) × (29700 − 423 − 423)
          = 20576 × 28854  (1/100 mm) = 8.101 × 11.361 in
          → at 600 dpi     = 4860 × 6816 px      ← the raster we measured
canvas    = 21000 × 29700 (1/100 mm) = A4        ← 4960 × 7016 px, what PJL declares
```

`media-left-margin=212` / `media-bottom-margin=423` are exactly `6 pt` / `12 pt`
— i.e. **the `6 12 589 830` inset from the `real-margin` retrofit PPD**. The
raster geometry is fully explained by the PPD's `*ImageableArea`.

### 3.4 The bug was bigger than A4

The shipped `KonicaMinolta-206-fullbleed.ppd` is **not** uniformly full-page.
Auditing all 24 sizes:

```
FULL-PAGE (safe)  : 2  -> A4, Letter
INSET (6pt/12pt)  : 15 -> A3, A5, A6, B4, B5, B6, Statement, Legal, Tabloid,
                         Executive, 16K, 8K, Comm10, EnvC6, EnvDL
```

So an A4-only test would have looked like a pass while 15 other sizes still
ghosted. The fix normalises **all** sizes.

---

## 4. Why the earlier PPD experiments appeared to do nothing

Worth recording, because it cost real time and produced a wrong conclusion.

The Printer Application persists each printer's media collection in
`/var/lib/legacy-printer-app/legacy-printer-app.state`:

```
media-col-default bottom="423" left="141" length="29700" name="iso_a4_210x297mm"
                  right="141" source="auto" top="423" type="plain" width="21000"
```

`423`/100 mm = 12.0 pt and `141`/100 mm = 4.0 pt — the classic **cups-filters
default margins**. That is where the "libpappl reports a 4pt/12pt inset"
observation came from.

However, re-testing showed this state value is **not** what sizes the raster:

| Action | `media-col-default` margins | Job raster |
|---|---|---|
| restart service only | 423 / 141 (unchanged) | unchanged |
| delete + re-add printer | 423 / 141 (**still unchanged**) | — |
| driver PPD `*ImageableArea` → full page | 423 / 141 | **4860×6816 → 4961×7016** ✓ |

So `media-col-default` is a sticky cups-filters default that never follows the
PPD, while the **per-job** `media-col` *does* follow the PPD's `*ImageableArea`.
Only the latter matters for output.

### 4.1 Rounding trap

While testing, setting `*ImageableArea A4/A4: "0 0 595.276 841.89"` against
`*PaperDimension A4/A4: "595 842"` made PAPPL reject the driver outright:

```
E [Printer konica206uri] Invalid driver left/right margins value -9.
```

595.276 pt is *wider* than 595 pt, so the right margin goes negative. This is the
same class of failure as the `-70` error in the project's original design doc
(Issue 2). **`*ImageableArea` must match `*PaperDimension` byte-for-byte** (both
`"595 842"` for A4). The installer derives one from the other to guarantee this.

---

## 5. The fix

In `install_ppds()`:

1. **Normalise geometry** — rewrite every `*ImageableArea` to
   `"0 0 <W> <H>"` using that size's `*PaperDimension`. Regexes match size keys
   with `[^:]+`, not `\S+`, because keys like
   `FLS_8D125X13D25/FLS 8 1/8 x 13 1/4` contain spaces.
2. **Guard rail** — a Python check re-reads the PPD and warns if any
   `*ImageableArea` still differs from its `*PaperDimension`.
3. **Default driver** — `DRIVER_MATCH` now defaults to `full-bleed-retrofit`,
   with a comment explaining this is a correctness requirement, not aesthetics.
4. **Shim sanitising** — the full-page driver exposes a `.Borderless` variant of
   every size (48 entries instead of 24). `sanitize_shim_ppd()` drops any size
   declaration whose name contains a borderless token (case-insensitively), so
   the shim keeps the 24 standard sizes the owner asked for.

Result on the target machine:

```
==> normalised 24 *ImageableArea entries to full page
==> PAPPL driver PPD geometry: 24 sizes, 24 full-page
==> Geometry check OK: all *ImageableArea match *PaperDimension (full page).
==> Shim PPD: 24 paper sizes, default A4
```

---

## 6. Verified on paper

| Check | Queue | Result |
|---|---|---|
| Duplex long-edge, A4 | `konica206uri` | **clean** (job 310) |
| Simplex, real quotation PDF, pure defaults | `konica206uri` | **clean** (job 311) |
| Duplex long-edge, real 2-page .docx | `KONICA_MINOLTA_206` | clean (job 297) |
| Simplex, real quotation PDF | `KONICA_MINOLTA_206` | clean (jobs 301, 305) |

Both queues now render simplex **and** duplex correctly.

**Not verified on paper:** non-A4 sizes. The machine has only A4 loaded and the
printer reports a page-size error otherwise, so A3/A5/Legal/etc. are correct by
construction (same full-page geometry as A4) but untested.

---

## 7. How to reproduce / re-diagnose

**Geometry measurement** (the decisive check). Wrap the filter, print one job,
read offsets 376/380 of its input:

```bash
D=/usr/local/lib/konica/KonicaMinolta/245igdi/Filters
sudo cp $D/245igdirf $D/245igdirf.real
sudo tee $D/245igdirf >/dev/null <<'EOF'
#!/bin/bash
D=/usr/local/lib/konica/KonicaMinolta/245igdi/Filters
mkdir -p /tmp/cap; : > /tmp/cap/argv.txt
for a in "$@"; do echo "ARG: $a" >> /tmp/cap/argv.txt; done
tee /tmp/cap/stdin.ras | $D/245igdirf.real "$@"
rc=$?
i=0; for a in "$@"; do i=$((i+1)); [ -f "$a" ] && cp "$a" /tmp/cap/arg${i}.ras 2>/dev/null; done
exit $rc
EOF
sudo chmod 755 $D/245igdirf && sudo systemctl restart legacy-printer-app
lp -d konica206uri -o sides=one-sided -o PageSize=A4 file.pdf
python3 -c "
import struct; b=open('/tmp/cap/stdin.ras','rb').read(8192)
print('raster %d x %d  (canvas must be 7016 high)' % (
  struct.unpack_from('<I',b,376)[0], struct.unpack_from('<I',b,380)[0]))"
sudo rm $D/245igdirf.real && sudo mv $D/245igdirf.real $D/245igdirf   # restore
```

**Invariant check** (no printing needed):

```bash
python3 - /var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd <<'PY'
import re, sys
pd, ia = {}, {}
for line in open(sys.argv[1], encoding='latin-1'):
    m = re.match(r'\*PaperDimension\s+([^:]+):\s*"?([\d.]+)\s+([\d.]+)', line)
    if m: pd[m.group(1)] = (float(m.group(2)), float(m.group(3)))
    m = re.match(r'\*ImageableArea\s+([^:]+):\s*"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)"', line)
    if m: ia[m.group(1)] = tuple(float(m.group(i)) for i in (2,3,4,5))
bad = [k for k,(w,h) in pd.items() if ia.get(k) and
       (abs(ia[k][0])>.001 or abs(ia[k][1])>.001 or abs(ia[k][2]-w)>.001 or abs(ia[k][3]-h)>.001)]
print("non-full-page sizes:", bad or "none")
PY
```

> Caution: naive regex over `debug-jobdata-*.prn` yields **false positives**,
> because JBIG-compressed binary can contain byte sequences resembling PJL
> directives. Always consume exactly `IMAGELEN` bytes after each `IMAGELEN=`.

---

## 8. Related, still-open observation

Some duplex streams contain a mid-job end-of-job marker with orphaned data
after it:

```
@PJL SET IMAGELEN=11444   [+11444 bytes]
@PJL SET PAGESTATUS=END
@PJL EOJ                             ← job ends here
[30714 bytes of unheadered image data]
@PJL SET IMAGELEN=31844   [+31844 bytes]
```

This looks like the driver's async encode queue (`EncodeQueueWrite`,
`ChunkExtendWrite` in `mtorf.ocm`) flushing after the trailer. It is **not** the
ghosting cause — a structurally clean stream (single `EOJ`, Draft quality) still
ghosted. It may still be a separate defect worth reporting upstream.

---

## 9. Corrections to the earlier draft

Recorded so the wrong conclusions are not carried forward.

| Earlier claim | Reality |
|---|---|
| "libpappl **hardcodes** the 4pt/12pt inset and ignores the PPD" | **Wrong.** The per-job `media-col` follows the PPD's `*ImageableArea` exactly. The 4pt/12pt values in `legacy-printer-app.state` are a separate, sticky cups-filters *default* that never affects the raster. |
| "Ghost affects simplex and duplex" | **Right**, but the first reading of a sample scan suggested duplex-only; a controlled A/B settled it. |
| "Only 2 of 24 sizes are full-page" (i.e. the fix was A4-only) | **Right**, and worse than first thought — the shipped retrofit PPDs are internally inconsistent, so an A4-only test would have passed while 15 sizes still ghosted. |
| "Ghost is unexplained leftover buffer data" | **Wrong.** It is the raster being sized from the imageable area while the driver declares the full sheet; a same-page copy is exactly what that mismatch produces. |

Credit: the decisive step — instrumenting the filter to read the real raster
geometry instead of inferring it — came from an external review
(`pappl-ghosting-analysis.md`, Claude). Its core hypothesis (raster dimensions
mismatch, not stale buffers) was correct and is what §3 now confirms.

---

## 10. Files

| Path | Role |
|---|---|
| `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd` | **active** PAPPL driver PPD; all 24 `*ImageableArea` normalised to full page |
| `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-real-margins.ppd` | alternate PPD, real margins — **will ghost**, kept for reference |
| `/etc/cups/ppd/KONICA_MINOLTA_206.ppd` | classic queue PPD, full-page geometry, `*DefaultDuplex: None` |
| `/usr/local/share/konica206uri/konica206uri-driverless.ppd` | `driverless` shim: 24 standard sizes, A4, `*DefaultDuplex: None`, no borderless |
| `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf` | vendor filter (patchelf'd against vendored libcups) |
| `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/mtorf.ocm` | vendor OCM (source of `COMPRESS=JBIG`) |
| `/var/lib/legacy-printer-app/legacy-printer-app.state` | printer state incl. the sticky `media-col-default` margins |
| `/var/spool/legacy-printer-app/debug-jobdata-*.prn` | PAPPL job streams (PJL + JBIG) |