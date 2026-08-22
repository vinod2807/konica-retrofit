# Konica Minolta 206 Print Stack — Investigation Log

| | |
|---|---|
| **Date** | 2026-08-21 |
| **System** | Fedora 44 (`fedora` host), CUPS 2.4.19 + `legacy-printer-app` (PAPPL 1.4.9 / pappl-retrofit 1.0b2) |
| **Printer** | bizhub 206, GDI-only (`CMD:GDI,XPS`), USB `132b:232b`, serial `A8A6041029423` |
| **Working queue** | `konica206uri` → IPP → legacy-printer-app :8000 → `pdftopdf→gs→245igdirf` → custom chunked libusb backend |
| **Outcome** | Native PAPPL USB path ruled out (ZLP firmware wedge); root cause proven, fixed upstream same-day |

---

## 1. Objective

Determine whether any alternative to the pappl-retrofit GDI stack exists for
this printer — PCL drivers, PostScript, or PAPPL's native USB transport — and
fully explain the historical "printer drops off USB" wedge.

## 2. Experiments & results

### Phase 1 — PCL viability (negative)

| Probe | Method | Result |
|---|---|---|
| Raw PCL6/PCL XL (Ghostscript `pxlmono`, A4 simplex+duplex) | direct via chunked backend, then dedicated CUPS queue `konica206-pcl` | USB-accepted, never rendered |
| Raw PCL5 minimal escape sequence + `ljet4` page | direct via backend | accepted, never rendered |
| **Official KM vendor driver** `konica-minolta-246pcl-cups-0.16` (BH226PCL6Linux kit, `246pclrf`) | extracted RPM → `/usr/local/lib/konica/KonicaMinolta/246pcl` + wrapper filter | accepted, never rendered |

Debugging the vendor filter surfaced three independent issues (worth knowing
for future vendor-driver work):

1. **SELinux**: files extracted via `cp -a` keep stale contexts (`user_tmp_t`)
   → `cupsd_t` denied execute. Fix: `restorecon -R`.
2. **Ownership**: Monotype filters must be `root:root 755` or CUPS refuses them.
3. **`$PPD` env dependency**: `246pclrf` reads the PPD path exclusively from
   the `PPD` environment variable and ignores CUPS' standard `argv[6]`;
   solved with a one-line wrapper script exporting `PPD=$6`.

Conclusion: this unit is the GDI-controller SKU; the 246pcl driver targets the
separate PCL-controller variant (`MDL:206 PCL`, `CMD:PJL,PCL,PCLXL`). Do not retry.

### Phase 2 — PostScript (negative)

Raw PostScript probe (the bizhub-360 PS PPD passes PS through unfiltered):
accepted on USB, silently discarded. Consistent with `CMD:GDI,XPS`.

### Phase 3 — Burst-size probing (misleading pass)

A custom libusb harness sent a verified 675 KB GDI stream with escalating
chunk sizes — 8 KiB control → 32 KiB → 61,465 B (the Aug-7 "killer") → 64 KiB
first-chunk → sustained all-64KiB. **All passed**, no disconnects.

At the time this suggested PAPPL's native path was safe. It wasn't — the probe
could not emit ZLPs, which turned out to be the actual trigger. Lesson recorded:
synthetic traffic patterns cannot certify this firmware; only real driver paths count.

### Phase 4 — Pure PAPPL native USB (positive reproduction → root cause)

Parallel queue `konica206pappl` (plain `usb://` URI, no `cups:` scheme).
First job wedged the printer at "Data Receiving" — with journal showing
job Completed, zero errors, no disconnect. Silent false-success failure.

usbmon capture diffed against the working queue revealed the trigger:

```
S Bo:3:009:1 -115 0          ← ZERO-LENGTH PACKET before any job data
C Bo:3:009:1 0 0
S Bo:3:009:1 -115 10445      ← GDI stream
C Bo:3:009:1 0 10445
S Bo:3:009:1 -115 46         ← PAGESTATUS=END / EOJ tail
C Bo:3:009:1 0 46            ← all ACKed; firmware never renders
```

**Root cause chain** (full analysis: `PAPPL_ZLP_DOSSIER.md`):

```
papplDeviceWrite(buf, 10491)
  └─ bufused(0)+10491 > 8192 ⇒ flush empty buffer
       └─ pappl_write(device, buffer, 0)        ← no zero-length guard
            └─ pappl_usb_write(…, 0)
                 └─ libusb_bulk_transfer(len=0) ⇒ ZLP on wire
                      └─ bizhub 206 GDI state machine breaks
```

The `cups:` scheme is immune because its write callback ends in
`write(pipe_fd, buffer, bytes)` — a zero-byte pipe write is a kernel no-op.
The custom chunked backend likewise never emits zero-length transfers.

Historical correction: the Aug-7 "chunk size" theory was incomplete. With big
jobs, PAPPL native interleaves a ZLP before *every* >8192-byte chunk. The
classic backend's reliable 8192-byte writes worked because they never carry
ZLPs — not because of their size.

## 3. Upstream outcome

Report filed as [michaelrsweet/pappl#434](https://github.com/michaelrsweet/pappl/issues/434)
with usbmon evidence and suggested fix. Closed as fixed in **86 minutes**:
`9093b16` (master), `bc29de9` (v1.4.x backport). Until Fedora ships a pappl
release containing the guard, native `usb://` still wedges this printer.

## 4. System state after the investigation

| Item | State |
|---|---|
| `konica206uri` | untouched, verified healthy post-recovery |
| `konica206uri-ppd` | untouched |
| Test queues (`konica206-pcl`, `konica206-pappl`) | removed |
| Vendor 246pcl files | removed |
| Custom backend + retrofit stack | unchanged, load-bearing |
| Evidence | `backup/diagnostics/usbmon-zlp/` (captures), spool debug jobdata |

## 5. Documents produced

| Document | Purpose |
|---|---|
| `backup/docs/PAPPL_ZLP_DOSSIER.md` | Full technical dossier (repro, code paths, fixes) — also local `~/PAPPL-ZLP-DOSSIER.md` |
| `KONICA_206_RETROFIT_DOCUMENTATION.md` §8e + §8e.1 | Incident summary + post-fix adoption decision tree |
| `backup/diagnostics/usbmon-zlp/*.log` | Raw bus captures (working vs wedging) |

## 6. Standing rules (updated)

1. Never use PAPPL's native USB path on this device until a fixed pappl is
   installed **and** validated per `PAPPL_ZLP_DOSSIER.md` §6.
2. Any job sent while the printer shows "Data Receiving" aborts — power-cycle first.
3. Banner/test-page content still wedges the firmware independently (§4 Issue 7).
4. When copying vendor binaries from temp dirs on SELinux systems: plain `cp`,
   then `restorecon -R`; filters must be `root:root 0755`; some Monotype
   filters require `$PPD` env (wrapper pattern documented).
