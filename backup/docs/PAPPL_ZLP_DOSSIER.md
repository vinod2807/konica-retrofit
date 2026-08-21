# PAPPL Zero-Length Packet (ZLP) Wedge — Complete Technical Dossier

| | |
|---|---|
| **Date** | 2026-08-21 |
| **Upstream issue** | https://github.com/michaelrsweet/pappl/issues/434 |
| **Affected code** | PAPPL `papplDeviceWrite()` / `pappl_write()` / `pappl_usb_write()` — verified on v1.4.9, same logic on master |
| **Environment** | Fedora 44 (kernel 7.1.8-200.fc44.x86_64), pappl-1.4.9-4.fc44, pappl-retrofit-1.0b2-11.fc44, legacy-printer-app-1.0b2-11.fc44, CUPS 2.4.19 |
| **Printer** | Konica Minolta bizhub 206 — GDI host-based (`CMD:GDI,XPS`), USB `132b:232b`, serial `A8A6041029423`<br>Iface 0: vendor-specific (EP 0x03 OUT, EP 0x84/0x85/0x87 IN)<br>Iface 1: printer class 7/1/**protocol 2 (bidirectional)**, EP **0x01 bulk OUT** + 0x82 bulk IN |

---

## TL;DR

`pappelDeviceWrite()`'s flush-ahead logic calls the device write callback with
**length 0** whenever a write larger than the internal buffer arrives while the
buffer is empty. For USB devices this becomes a **zero-length packet (ZLP) on
the wire before job data**. The bizhub 206's GDI firmware treats that premature
ZLP as fatal: it ACKs all subsequent data but never renders the page, leaving
the panel stuck at *"Data Receiving"* while PAPPL logs the job as *Completed*
with zero errors. A usbmon capture proves the ZLP; a control capture of the
same document through a non-buffered path shows no ZLP and prints correctly.

---

## 1. Failure report

### Setup under test

A parallel PAPPL printer using PAPPL's **native USB device support**
(`usb://KONICA%20MINOLTA/206?serial=A8A6041029423`, no `cups:` scheme), created
to evaluate dropping our custom chunked backend.

### Symptoms of the first (and every) job

| Observation | Value |
|---|---|
| Filter chain (`gstopdf → pdftopdf → gstoraster → 245igdirf`) | all "exited with no errors" |
| Backend stage | "Backend completed with status 0" |
| Job state | `Completed`, `job-state-reasons=none` |
| Kernel log | **no USB disconnect**, no reset |
| Physical printer | wedged at **"Data Receiving"**, requires power-cycle |
| Page produced | none |

The nastiest property: **every layer reports success**. Only the hardware is
wrong. No log, exit code, or job state betrays the failure.

---

## 2. Data-plane reconstruction

PAPPL's buffering layer (`pappl/device.c`, `papplDeviceWrite`, v1.4.9 line ~1085;
`PAPPL_DEVICE_BUFSIZE = 8192` from `device-private.h`):

```c
ssize_t papplDeviceWrite(pappl_device_t *device, const void *buffer, size_t bytes)
{
  if (!device) return (-1);

  if ((device->bufused + bytes) > sizeof(device->buffer))
  {
    // Flush the write buffer...
    if (pappl_write(device, device->buffer, device->bufused) < 0)   // ← bufused can be 0!
      return (-1);
    device->bufused = 0;
  }

  if (bytes < sizeof(device->buffer))
  {
    memcpy(device->buffer + device->bufused, buffer, bytes);        // buffered
    device->bufused += bytes;
    return ((ssize_t)bytes);
  }

  return (pappl_write(device, buffer, bytes));                      // direct
}
```

`pappl_write()` (line ~1173) applies **no zero-length guard** — it forwards
straight to the scheme callback:

```c
count = (device->write_cb)(device, buffer, bytes);
```

and for USB (`pappl/usb.c`, `pappl_usb_write()`, line ~687):

```c
libusb_bulk_transfer(usb->handle, usb->write_endp, (unsigned char *)buffer,
                     (int)bytes /* ← 0 */, &icount, 0);
```

`libusb_bulk_transfer()` with length 0 submits a **zero-length packet**.

### Mapped to the wedged job (10,491-byte GDI stream)

The upstream filter (`245igdirf`) wrote its output in two pieces, so the
read loop in `_prPrintFilterFunction` (pappl-retrofit `print-job.c`, line ~1512)
made two calls — producing exactly the three bus transactions we captured:

| Step | Call | Resulting USB transaction |
|---|---|---|
| `read()` #1 → 10,445 B | `papplDeviceWrite(dev, buf, 10445)` → `10445 ≥ 8192`, flush empty buffer first | **ZLP**, then bulk OUT 10,445 B |
| `read()` #2 → 46 B (`@PJL SET PAGESTATUS=END…EOJ` tail) | `papplDeviceWrite(dev, buf, 46)` → `46 < 8192` → *buffered* | *(nothing yet)* |
| loop ends | `papplDeviceFlush(device)` → `pappl_write(buffer, 46)` | bulk OUT 46 B |

Every observed transfer on the wire maps 1:1 to this model — including the
otherwise-puzzling leading ZLP and the oddly separate 46-byte tail.

---

## 3. Bus-level evidence

Captures taken with Linux `usbmon` on the printer's bus. Raw files:
`mon-baseline.log` (working path) and `mon-wedge.log` (native path),
preserved at `backup/diagnostics/usbmon-zlp/` in
https://github.com/vinod2807/konica-retrofit

### Working path (`cups:` scheme → classic-style chunked backend)

```
S Ci:3:009:0 s 80 06 0300 0000 0004 4 <        string lang descriptor (serial match)
C Ci:3:009:0 0 4 = 04030904
S Ci:3:009:0 s 80 06 0303 0409 00ff 255 <       serial string "A8A6041029423"
C Ci:3:009:0 0 28 = 1c034100 38004100 ...
S Bo:3:009:1 -115 8192 = 1b252d31 32333435 ...  ESC%-12345X@PJL...
C Bo:3:009:1 0 8192 >
S Bo:3:009:1 -115 2296 = fc62e4f0 ...
C Bo:3:009:1 0 2296 >
```
→ string reads for URI matching + **two non-zero bulk writes**. Prints fine.

### Wedging path (native `usb://`)

Open phase:
```
S Ci:3:009:0 s 80 08 0000 0000 0001 1 <         GET_CONFIGURATION  → 01
C Ci:3:009:0 0 1 = 01
S Ci:3:009:0 s a1 00 0000 0100 0402 1026 <      GET_DEVICE_ID (class, iface 1)
C Ci:3:009:0 0 75 = 004b4d46 473a4b4f ...       "MFG:KONICA MINOLTA;CMD:GDI,XPS..."
S/Ci … 0300/0301/0302/0303                      manufacturer/product/serial strings
```

Data phase — **the smoking gun**:
```
S Bo:3:009:1 -115 0                             ◄◄◄ ZERO-LENGTH PACKET
C Bo:3:009:1 0 0                                ◄◄◄ delivered before any data
S Bo:3:009:1 -115 10445 = 1b252d31 32333435 ... ◄◄◄ the GDI stream
C Bo:3:009:1 0 10445
S Bo:3:009:1 -115 46 = 40504a4c ...             @PJL SET PAGESTATUS=END / EOJ
C Bo:3:009:1 0 46                               all ACKed — firmware never renders
```

Note what is *absent*: no read attempts on EP 0x82, no aborts, no stalls, no
disconnects. The firmware swallows everything and silently never finishes.

---

## 4. Why the `cups:` scheme never hits this

The same `papplDeviceWrite()` buffering runs for `cups:`-scheme printers, so
the identical `flush(0)` call happens there too. But that scheme's callback
ends in an ordinary pipe write:

```c
// pappl-retrofit cups-backends.c, _prCUPSDevWrite()
return (write(device_data->inputfd, buffer, bytes));   // bytes == 0 → kernel no-op
```

A zero-byte `write()` to a pipe transfers nothing. **The ZLP never exists on
that path.** Only schemes whose callbacks forward lengths verbatim to libusb
(i.e., native USB) materialize the spurious ZLP.

This also explains why the failure stayed invisible for so long: the
retrofit/legacy use case overwhelmingly runs through the `cups:` scheme.

---

## 5. Why "chunk size" was a red herring

Our earlier incident (Aug 2026) blamed PAPPL's 64 KiB single writes. That was
an incomplete model. Two experiments set it straight:

### Burst-size probe (libusb test harness, no ZLPs possible)

Sent a 675 KB verified GDI stream with varying chunk sizes:

| Pattern | Result |
|---|---|
| 8192 B × whole file (control) | prints, device alive |
| first chunk 32 KiB, rest 8192 | prints, device alive |
| first chunk **61,465 B** (the originally "fatal" size) | prints, device alive |
| first chunk 64 KiB | prints, device alive |
| **every** chunk 64 KiB (true PAPPL pattern minus ZLPs) | prints, device alive |

→ The printer has **no burst-size cliff**. `libusb_bulk_transfer` only puts a
ZLP on the wire when given length 0, which the probe never did.

### Real PAPPL native job (with ZLPs)

First job, ~10 KB stream → instant wedge.

**Conclusion:** the lethal ingredient is not transfer size — it is the
spurious zero-length packets that `papplDeviceWrite`'s flush emits between real
writes. For multi-chunk jobs, a ZLP precedes *every* >8192-byte chunk. The
classic CUPS USB backend and our custom backend work because their write loops
happen never to emit zero-length transfers.

---

## 6. Reproduction recipe

Minimal, no special hardware beyond any ZLP-intolerant USB printer:

```bash
# 1. Native-scheme printer via legacy-printer-app (pappl-retrofit)
sudo legacy-printer-app add -d zlptest \
    -v "usb://VENDOR/MODEL?serial=..." -m <any-driver>

# 2. Print anything whose driver output exceeds 8191 bytes
lp -d zlptest some-document.pdf

# 3. Observe:
#    - journalctl -u legacy-printer-app : job Completed, no errors
#    - usbmon: S Bo:<dev>:<ep> -115 0 immediately before first data
#    - printer: stuck / page missing
```

Firmware classes expected to be susceptible: host-based/GDI printers with
band-rendering state machines that treat bulk ZLP as end-of-data or
end-of-page markers.

---

## 7. Suggested fixes

Minimal (fixes the empty-flush case, keeps large-write bypass semantics):

```c
// pappl/device.c, papplDeviceWrite()
if (device->bufused > 0 && (device->bufused + bytes) > sizeof(device->buffer))
```

Defensive depth (protects every scheme and future callers):

```c
// pappl/device.c, pappl_write()
if (bytes == 0)
  return (0);
```

and/or:

```c
// pappl/usb.c, pappl_usb_write()
if (bytes == 0)
  return (0);
```

Either change eliminates the spurious ZLP; applying both is safest.
Happy to test a patch against the bizhub 206 hardware on request.

---

## 8. What we did *not* test

- Whether other KM models of the same generation share the firmware behavior
- Whether the wedge also occurs when `bufused > 0` (i.e., genuine partial-buffer
  flushes) — presumably harmless since those carry real data
- Behavior under PAPPL 2.x master (static inspection suggests unchanged)

---

## Appendix A — environment details

- OS: Fedora 44, kernel `7.1.8-200.fc44.x86_64`, SELinux enforcing
- pappl 1.4.9-4.fc64 · pappl-retrofit 1.0b2-11.fc44 · CUPS 2.4.19-3.fc44
- Printer endpoint facts (`lsusb -v`): iface 1 class 7/1/protocol 2,
  bulk OUT `0x01`, bulk IN `0x82`; iface 0 vendor-specific
- Debug job data preserved per-job at
  `/var/spool/legacy-printer-app/debug-jobdata-*.prn`
  (wedged job: `debug-jobdata-konica206pappl-1.prn`, 10,491 bytes,
  SHA-256-verified structurally identical to streams that print via the
  working queue)

## Appendix B — raw usbmon captures

See `backup/diagnostics/usbmon-zlp/{mon-baseline.log,mon-wedge.log}` in
https://github.com/vinod2807/konica-retrofit (annotated excerpts inline above).
