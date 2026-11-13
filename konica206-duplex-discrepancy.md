# Duplex discrepancy: builtin vs system renderer (for ChatGPT analysis)

Date: 2026-10-06. Machine: shop host, CUPS 2.4.16, Ghostscript 10.06.0,
poppler via cups-filters 2.0.1, PAPPL 1.4.9, konica206-native repo HEAD.

## Symptom

Same document, same queue (`konica206-native`), same requested options
(`PageSize=A4 InputSlot=Tray1 Duplex=DuplexNoTumble sides=two-sided-long-edge
Resolution=600x600dpi`), pages 1–2 of a 3-page portrait A4 PDF:

- `system` renderer (`pdftoraster`): binds **long-edge** (correct).
- `builtin` renderer (Ghostscript `pgmraw` + own raster writer): binds
  **short-edge** (wrong).

Verified by A/B on paper: system correct (Adobe + qpdfview), builtin
flipped, system again correct. Same USB printer, same vendor filter
(`245igdirf` + private libs), same PPD
(`/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd`).

## Document

`ACCE03BCD437C7BB2EB47FC5F9925CBB-II_PUC.pdf` (was in
`/home/spot/Downloads/`): 3 pages, native size 595x842 pts (A4),
producer iLovePDF, scanned pages (raster content), Kannada text, large
light-purple "M" watermark on page 2, handwritten tick annotations, QR codes,
page numbers "-2-", "-3-". Printed range in failing/passing tests: pages 1–2
(one duplex sheet).

## Live captures (since cleaned from /tmp; hashes not recorded)

- System path: native job 18 → `18-in.ras` (69,616,348 B, 2 pages) +
  `18-out.prn` (465,608 B). Correct long-edge on paper.
- Builtin path: native job 17 → `17-in.ras` (69,616,348 B, 2 pages) +
  `17-out.prn` (467,975 B). Wrong short-edge binding on paper.

Both captured with `KONICA_CAPTURE_DIR` (tees raster into / vendor output
out of `konica_render_raster`).

## Measurements that show NO difference

Raster headers, both pages, both paths (`cupsRasterReadHeader2`):

```text
page 1 W=4961 H=7016 Duplex=1 Tumble=0 PS=595,842
page 2 W=4961 H=7016 Duplex=1 Tumble=0 PS=595,842
BitsPerColor=8 BitsPerPixel=8 BytesPerLine=4961 ColorOrder=0
ColorSpace=0 NumColors=1 HWResolution=600,600 NumCopies=1
```

Reference `pdftoraster` one-sided header also shows the quirk `Tumble=1`;
duplex long-edge reference is `Duplex=1/Tumble=0`, short-edge `1/1`.
Builtin mirrors these exactly.

PJL job prologue/epilogue, both full-document renders (3 pages):

```text
@PJL SET COPIES=1
@PJL SET DUPLEX=ON
@PJL SET BINDING=SHORTEDGE      <- emitted by BOTH paths, even long-edge
(repeated per page/sheet)
```

Full PJL greps (`BINDING|DUPLEX|COPIES|PAPERSIZE|RESOLUTION|TUMBLE`) are
identical between paths. Total stream sizes differ only ~1%
(719,560 vs 725,897 B) — JBIG compression of slightly different pixels.

## Measurements that DO differ

Per-page pixel comparison, live system raster vs live builtin raster
(34,806,376 px/page, 8-bit gray):

| Page | % pixels differing |
|---|---|
| 1 | 8.81% |
| 2 | 39.50% |

Page-2 transform tests (builtin page 2 vs system page 2):

| Transform | % differ |
|---|---|
| as-is | 39.50% |
| rot180 | 37.67% |
| flip-horizontal | 39.06% |
| flip-vertical | 36.85% |
| shifts dx/dy ±50..200 | 38.5–39.5% |

No orientation/shift explains page 2. Grayscale means are equal
(sys 240.8 vs builtin 240.8).

Page-2 delta-magnitude histogram (% of pixels):

```text
0-7: 69.53% | 8-15: 8.17% | 16-23: 4.77% | 24-31: 2.79%
32-63: ~3% | 64-127: ~1% | 128-239: ~7% | 240-255 (inverted): 2.38%
```

So ~30% of page-2 pixels differ beyond antialiasing, including 2.4%
fully inverted (black↔white). Suspects on this page: the large alpha
watermark, handwritten annotations, QR code (poppler vs gs decode/threshold).

For contrast, golden doc `standard.pdf` page 1: 0.71% differ, mean abs
diff 1.78 gray levels (pure antialiasing).

## The puzzle

Every mechanical signal (header flags, PJL binding, sizes, page order,
pixel orientation) is equivalent, yet the printer binds one stream
long-edge and the other short-edge. Pixel *content* should not be able
to change a mechanical binding on a GDI printer — unless:

1. The 2.4%-inverted content trips some printer-side auto-orientation /
   edge detection (unlikely on GDI, but not disproven), or
2. An unexamined byte-level difference exists outside the grepped PJL
   (full binary diff of the two vendor streams was never done — both
   captures were deleted after the pixel analysis), or
3. The observation is confounded (e.g. printer duplex-clutch state
   carried over between consecutive test prints).

## What was NOT done (open for analysis)

- Full binary diff of live `18-out.prn` vs `17-out.prn` (files deleted).
- Per-page JBIG payload decode and visual comparison of page 2.
- Identifying exactly which page-2 element inverts (watermark vs
  handwriting vs QR) by masking regions.
- Testing whether the flip reproduces on a *second* builtin print of the
  same pages (rules out carry-over/mechanical flakiness).
- Checking whether Ghostscript version differences (e.g. JPEG/JBIG2
  decoder, `-dPDFFitPage` interaction with scanned CropBox) explain page 2.

## Current live state

Server on `system` renderer (default). `builtin` retained behind
`KONICA_PDF_RENDERER=builtin`. No paper proof required for further
offline analysis if the source PDF is available.
