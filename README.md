# Konica Minolta 206 — CUPS/PAPPL Retrofit Backup

Complete, self-contained backup and restore kit for the permanent dual-queue
printing setup for the **Konica Minolta 206** GDI laser printer on this
machine (Ubuntu 26.04, `legacy-printer-app` 1.0~b2-0ubuntu8, CUPS 2.4.16).

Captured: **2026-08-18**. The repository retains the 2026-08-16 snapshot as a
historical reference, and now includes the current **Option A** recovery snapshot
from the working Arch Linux system at:
`/home/vinod/konica-pappl-backup-20260818-1532/`.

---

## 0. Quick start — the installer

The one-click, distro-agnostic installer is at the **root of this repository**:

- **`install-konica-anylinux.sh`**
- On GitHub: `https://github.com/vinod2807/konica-retrofit` (root), or direct
  download:
  `https://raw.githubusercontent.com/vinod2807/konica-retrofit/main/install-konica-anylinux.sh`

**How to use it on a fresh Linux machine** (Debian/Ubuntu, Fedora/RHEL, Arch,
openSUSE — any glibc Linux with bash, gcc, and libusb-1.0):

```bash
git clone https://github.com/vinod2807/konica-retrofit
cd konica-retrofit
sudo ./install-konica-anylinux.sh
```

The script will:
- detect the distro and install `legacy-printer-app` (pappl-retrofit) — via its
  package manager, the bundled `.debs`, or an OpenPrinting source build
- auto-detect your printer's serial number on USB (`lsusb`)
- install the vendor driver under `/usr/local` (apt-immune)
- build the chunked USB backend from source (`gcc` + `libusb-1.0`)
- install the PPDs, systemd drop-in, and persistence helper
- create the PAPPL queue `konica206uri` + CUPS passthrough queue, set A4 and
  the system default, then verify

If your printer's serial differs, pass it explicitly:
```bash
sudo ./install-konica-anylinux.sh --serial <SERIAL>
```

If the distro ships CUPS 3.0 (no `lpadmin`), the script skips the CUPS queue and
prints the raw IPP endpoint for GUI apps to use directly.

**Fedora / RHEL specifics:** `legacy-printer-app` and `pappl-retrofit` are
official Fedora packages (maintained by Red Hat's printing team), so the
installer uses `dnf install legacy-printer-app pappl-retrofit` directly. Current
Fedora ships CUPS 2.4.x with `libcups.so.2`, so the vendor driver and the
classic fallback queue both work. Two caveats:

- **SELinux (enforcing)** may deny the custom backend/filter running from
  `/usr/local`. The installer prints guidance; a quick fix is
  `sudo ausearch -m avc | audit2allow -M konica && sudo semodule -i konica.pp`
  (or `sudo setenforce 0` to confirm the cause).
- If a future Fedora release switches to CUPS 3.0, the classic queue breaks (as
  designed) and the installer automatically exposes the raw IPP endpoint
  (`http://localhost:8000/ipp/print/konica206uri`).

> Restoring just the configuration on an already-set-up machine is covered in
> §3; a full manual Debian/Ubuntu kit is under `backup/.../source/konica-debian13-setup/`.

---

## 1. What this setup is

Two independent printing queues that both drive the same physical printer over
USB:

| Queue | Scheduler | How it talks to the printer | Status |
|---|---|---|---|
| `KONICA_MINOLTA_206` | classic CUPS | `/usr/lib/cups/backend/usb` (classic, needs `libcups.so.2`) | **default queue** — the only one where duplex renders correctly (§5.2); **breaks under CUPS 3.0** |
| `konica206uri` | `legacy-printer-app` (PAPPL) | own filter chain → self-contained libusb backend | **CUPS-3.0-proof**; correct for simplex + duplex once PPD geometry is full-page (§5.2) |

Both queues default to **A4 + one-sided (simplex)** and both render simplex and
duplex correctly. `konica206uri` is the CUPS-3.0-proof path and is preferred;
`KONICA_MINOLTA_206` uses the classic usb backend and breaks under CUPS 3.0.

### Architecture (the PAPPL path)

```
GUI app / lp
    │  PDF over IPP
    ▼
CUPS (passthrough queue "konica206uri")
    │  IPP
    ▼
legacy-printer-app (PAPPL, ipp://localhost:8000)
    │  application/vnd.cups-raster
    ▼
245igdirf   (vendor GDI driver, relocated to /usr/local — see §4)
    │  raw printer stream
    ▼
cups: subprocess mechanism
    ▼
/usr/local/libexec/konica-backend/usb   (self-contained chunked USB backend)
    │  libusb-1.0 only (NO libcups)
    ▼
Konica Minolta 206  (USB serial A8A6041029423, VID 132b / PID 232b, intf 1)
```

---

## 2. Repository / backup contents

```
README.md
install-konica-anylinux.sh                    # distro-agnostic installer (Debian/Ubuntu/Fedora/Arch/openSUSE)
backup/
├── konica-pappl-backup-20260818-1532.tar.gz     # current Option A restore snapshot (3.6 MB)
├── konica-pappl-backup-20260818-1532/            # same current snapshot, extracted
├── konica-pappl-backup-20260816-1050.tar.gz     # historical snapshot
└── (historical 2026-08-16 extracted snapshot at backup root)
    ├── SHA256SUMS                               # checksums of every file (verified)
    ├── queue-snapshot.txt                       # lpstat/lpoptions/URI snapshot
    ├── etc/
    │   ├── systemd/system/legacy-printer-app.service.d/override.conf
    │   └── cups/ppd/                            # konica206uri.ppd(+.O), KONICA_MINOLTA_206.ppd
    ├── var/lib/legacy-printer-app/
    │   ├── legacy-printer-app.state             # PAPPL printer config
    │   ├── legacy-printer-app.state.bak-pappl-usb
    │   └── ppd/                                 # all retrofit PPDs (fullbleed, real-margins, passthrough)
    ├── usr/local/
    │   ├── lib/konica/KonicaMinolta/245igdi/    # RELOCATED vendor driver tree (apt-immune)
    │   ├── libexec/konica-backend/usb           # self-contained chunked USB backend
    │   └── bin/ensure-konica206uri.sh           # persistence helper
    ├── debs/                                    # offline reinstall .debs
    │   ├── legacy-printer-app_1.0~b2-0ubuntu8_amd64.deb
    │   ├── libpappl-retrofit1_1.0~b2-0ubuntu8_amd64.deb
    │   ├── libpappl1t64_1.4.9-0ubuntu2_amd64.deb
    │   ├── libcups2t64_2.4.16-1ubuntu1.3_amd64.deb
    │   └── libcupsimage2t64_2.4.16-1ubuntu1.3_amd64.deb
    ├── dpkg-info/                               # driver package metadata (deb not in repos)
    ├── source/
    │   ├── konica-usb-backend/                  # C source + built binary of the backend
    │   └── konica-debian13-setup/               # ready-to-run Debian 13 install kit
    └── docs/
        ├── KONICA_206_RETROFIT_DOCUMENTATION.md # full design doc (issues 1–11, CUPS 3.0 §8)
        └── KONICA_PAPPL_RETROFIT_INVESTIGATION.md  # round-by-round debugging log (through Round 9)
```

> The vendor driver `.deb` (`konica-minolta-245igdi-cups`) is **not** in this
> backup because it is no longer obtainable from current Ubuntu sources
> (`apt-cache madison` returns nothing). Its entire installed tree is preserved
> under `usr/local/lib/konica/...` and its package metadata under `dpkg-info/`,
> which is sufficient for restore.

---

## Current Option A recovery snapshot (2026-08-18)

The current recovery snapshot was captured after the `patchelf`/vendored-CUPS
change was tested with a successful duplex print on Arch Linux. It contains:

- patched `245igdirf`: SHA-256 `0548f3f3e20fae1e604e3bbe5464aedf5fbd8ff283f8173359f56153ce98a4d3`
- pristine vendor `245igdirf.pristine`: SHA-256 `0faf0a69aa772805423a9c4c1e5bb20f74d0bf43daeee676d4fa7c658377380d`
- private `libcups.so.2` and `libcupsimage.so.2` under `/usr/local/lib/konica/lib/`
- retrofit PPDs pointing directly to `/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf`
- the custom USB backend and the service/persistence configuration

The snapshot's own `SHA256SUMS` was verified successfully before the archive was
created. Archive SHA-256:
`afbf81f9820621f8f1963e44f595f7080a26ec4fff178090059bd906a8e9c05b`.

## 3. How to restore

### 3a. Restore the printer setup on this machine (files only)

Restores config + binaries + state. The PAPPL app must be installed (see §3b
for that).

```bash
cd /home/vinod/konica-pappl-backup-20260818-1532
sudo sha256sum -c SHA256SUMS          # verify integrity first (all lines must be OK)

sudo cp -a etc/systemd/system/legacy-printer-app.service.d /etc/systemd/system/
sudo cp -a etc/cups/ppd/.          /etc/cups/ppd/
sudo cp -a var/lib/legacy-printer-app  /var/lib/
sudo cp -a usr/local/.             /usr/local/
sudo systemctl daemon-reload
sudo systemctl restart legacy-printer-app
sudo systemctl restart cups
```

Then verify:

```bash
legacy-printer-app printers          # must list: konica206uri
lpstat -p konica206uri               # idle/enabled
lpstat -d                            # system default: konica206uri
```

### 3b. Reinstall the printer application (packages)

If `legacy-printer-app` / `libpappl-retrofit1` / `libpappl1t64` were lost
(e.g. dropped during a release upgrade), reinstall from the archived debs:

```bash
cd backup/debs
sudo apt-get install -y ./legacy-printer-app_1.0~b2-0ubuntu8_amd64.deb \
                        ./libpappl-retrofit1_1.0~b2-0ubuntu8_amd64.deb \
                        ./libpappl1t64_1.4.9-0ubuntu2_amd64.deb
# libcups2t64 / libcupsimage2t64 only needed if the distro removed them
sudo apt-get install -y ./libcups2t64_*.deb ./libcupsimage2t64_*.deb
```

Then restore as in §3a (the `/usr/local/lib/konica` driver and the backend
don't need any package).

### 3c. Restore on a NEW machine (any glibc Linux — Debian/Ubuntu/Fedora/Arch/openSUSE)

Use the **distro-agnostic installer** at the repo root. Clone the repo to the
target, then:

```bash
git clone https://github.com/vinod2807/konica-retrofit
cd konica-retrofit
sudo ./install-konica-anylinux.sh            # autodetects the printer serial
# or, if the printer's serial differs:
sudo ./install-konica-anylinux.sh --serial <SERIAL>
```

What it does automatically:
- detects the distro and installs `legacy-printer-app` (pappl-retrofit) via its
  package manager, the bundled `.debs`, or an OpenPrinting source build
- detects the Konica 206 on USB (serial, interface 1)
- installs the vendor driver under `/usr/local/lib/konica/...` (apt-immune)
- builds the chunked USB backend from `source/` with `gcc` + `libusb-1.0`
- installs PPDs, the systemd drop-in, and the persistence helper
- creates the PAPPL queue `konica206uri` and the CUPS passthrough queue (with a
  driverless PPD so all media sizes are visible in GUI apps), sets A4 + system
  default, and verifies

> If the distro ships **CUPS 3.0** (no `lpadmin`/PPD support), the script skips
> the CUPS passthrough queue and prints the raw IPP endpoint to point GUI apps at.

There is also a Debian/Ubuntu-specific kit for a fully manual install:
`backup/.../source/konica-debian13-setup/` (see its `README-debian13.md`).

---

## 4. Key design decisions (why it looks this way)

1. **`cups:` URI scheme** — the PAPPL printer uses
   `cups:usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1`, so PAPPL
   runs a backend subprocess (the classic CUPS USB backend used to do this).
2. **Self-contained chunked USB backend** (`/usr/local/libexec/konica-backend/usb`)
   — replaces the classic backend in the subprocess. It depends **only on
   libusb-1.0 + libc** (no `libcups.so.2`), writes in **≤8192-byte chunks**
   (mirrors the classic backend's behavior, which fixed the printer dropping off
   USB / kernel `usb disconnect` wedge), and matches the printer by serial.
3. **Driver relocated to `/usr/local`** — the vendor `245igdi` tree now lives at
   `/usr/local/lib/konica/KonicaMinolta/245igdi/`; the retrofit PPDs'
   `*cupsFilter` and `*OCM_resourceDir` point there. `/usr/local` is never
   touched by `apt`, so rendering survives removal of the
   `konica-minolta-245igdi-cups` package (already absent from current repos).
4. **`*DefaultOCM_TonerSave: TRUE`** in both retrofit PPDs — this was the
   **black-page fix**; without it the driver prints solid-black pages.
5. **A4 default, monochrome, one-sided (simplex)**, with **duplex available**.
   The CUPS passthrough queue uses a **driverless shim PPD** generated from the
   Printer Application (`driverless ipp://localhost:8000/...`), so GUI apps see
   **all** media sizes the printer supports (A3–A6, B4–B6, Letter, Legal,
   envelopes, ...), not just A4.

   Two deliberate deviations from the original 2026-08 snapshot, both driven by
   the requirement for **normal (non-borderless) sizes with A4 + simplex as the
   default**:

   - **Rendering driver is `real-margin`, not `full-bleed`.**
     `konica-minolta--206--real-margin-retrofit-en` gives
     `*ImageableArea A4: "6 12 589 830"` (real 6pt/12pt margins) instead of the
     full-bleed `"0 0 595 842"`. PAPPL rejects the vendor PPD's zero-margin
     geometry anyway (see Issue 2 in the design doc). Both variants carry the
     same 24 paper sizes and the same three duplex choices.
   - **Simplex is the queue default; duplex is opt-in** via
     `-o sides=two-sided-long-edge` / `-o sides=two-sided-short-edge`.

   The driverless shim PPD is post-processed by `sanitize_shim_ppd()`: any
   borderless entry is stripped, defaults are pinned to A4 / `None` /
   duplexer-installed, and the shim keeps its `*cupsFilter2` pass-through lines
   so CUPS never runs the GDI filter locally.

   > The CUPS-facing queues use the **shim PPD**, *not*
   > `KonicaMinolta-206-real-margins.ppd`. That file is the PAPPL *driver* PPD
   > and its `*cupsFilter: ... 245igdirf` makes CUPS run the vendor GDI filter
   > locally, so PAPPL then receives `application/vnd.printer-specific` instead
   > of raster and the job aborts. `PPD_QUEUE_FILE` therefore defaults to empty
   > and `create_queues()` points both queues at the generated shim.

6. **`*DefaultDuplexer: true` forced on the retrofit PPDs.** The vendor PPD
   ships `false` ("not installed"), and its own
   `*UIConstraints: *Duplexer false <-> *Duplex DuplexNoTumble` rules then make
   GUI apps hide the Duplex choice even though the 206's duplexer works. The
   installer rewrites `*DefaultDuplexer` to `true` while leaving
   `*DefaultDuplex: None` so the queue still defaults to simplex.
7. **Package holds — optional, not currently applied.** Holds on
   `legacy-printer-app`, `libpappl-retrofit1`, `libpappl1t64`,
   `konica-minolta-245igdi-cups` were tested during hardening but **removed at
   the owner's request** (2026-08-16). They're unnecessary here: the driver is
   apt-immune under `/usr/local` and the debs + driver tree are archived for
   offline restore, so the packages can track distro updates normally.

### CUPS 3.0 outlook

- `libcups3` is **not a blocker**. OpenPrinting added libcups3 support to
  pappl-retrofit, libppd, and libcupsfilters; the app builds with either
  libcups2 or libcups3. libcups 3.0.2 was released 2026-06-05.
- The PAPPL path and the custom backend **survive CUPS 3.0** (pure IPP +
  libusb-only backend).
- Only the **classic queue** (`KONICA_MINOLTA_206`) breaks under CUPS 3.0 — it
  needs `/usr/lib/cups/backend/usb` + `libcups.so.2`. This is expected and
  documented.
- The single migration item at distro transition time: upgrade
  `legacy-printer-app` to a newer pappl-retrofit build linked against the
  libcups3/libppd/libcupsfilters stack (a normal package migration).
- **`245igdirf`'s libcups2 dependency is now closed, not just documented**
  (see §5.1). The installer vendors `libcups.so.2` + `libcupsimage.so.2`
  privately via `patchelf --set-rpath`, so the driver no longer cares what
  CUPS version the host ships, on any distro.

---

## 5. Known limitations

- **Banner/test-page PDFs** (`application/vnd.cups-pdf-banner`, e.g. CUPS test
  pages, `job-sheets`) still wedge the printer through the PAPPL queue. Use the
  classic queue for those, and power-cycle the printer to recover from a wedge.
- The classic queue doesn't survive CUPS 3.0 (by design; keep it only as a
  fallback on CUPS 2.x systems).

### 5.1 `245igdirf`'s libcups2 dependency — solved via vendoring (2026-08-18)

The closed-source vendor binary `245igdirf` is hard-linked against the
**classic** `libcups.so.2` + `libcupsimage.so.2` ABI and will never be ported
to libcups3 (no source, vendor-abandoned). Previously this was an open risk:
if a distro ever dropped libcups2 entirely, the driver would stop working
with no fix available short of replacing it.

`install-konica-anylinux.sh` now closes this automatically
(`vendor_libcups()`, called from `install_driver()`): it copies
`libcups.so.2` + `libcupsimage.so.2` into a private directory
(`/usr/local/lib/konica/lib/`) and uses `patchelf --set-rpath` to point
`245igdirf` at that private copy instead of the system one. The driver is
then permanently immune to whatever CUPS the host ships, on any distro,
forever — the same pattern already used to relocate the driver tree itself
out of `apt`'s reach (§4.3).

Two libraries needed vendoring, not one — `245igdirf` links both
`libcups.so.2` **and** `libcupsimage.so.2`; vendoring only the former leaves
the latter still resolving from the system path.

Where the libraries come from depends on distro:
- **Debian/Ubuntu**: extracted from this repo's archived, version-pinned
  `debs/libcups2t64_*.deb` + `debs/libcupsimage2t64_*.deb` via `dpkg-deb -x`.
- **Arch / Fedora / openSUSE (or Debian without the bundled `.deb`s)**: copied
  directly from whatever the host currently has installed (checks
  `/usr/lib`, `/usr/lib64`, `/usr/lib/x86_64-linux-gnu`, `/lib`, `/lib64`,
  falling back to `ldconfig -p`). This is a **snapshot of the live system's
  libs, not a pinned archived version** — worth knowing if a future
  regression needs bisecting.

Applied and verified on both machines this repo tracks:
- **Ubuntu 26.04**: real, present risk at time of patching — `konica-minolta-245igdi-cups`
  was already gone from Ubuntu's repos and the driver already relocated to
  `/usr/local` out of necessity (§4.3). Vendoring closes an active gap.
- **Arch Linux**: `libcups`/`libcupsimage` were still current, live, and
  `pacman`-tracked at time of patching (Arch hasn't split or deprecated the
  classic ABI the way Ubuntu has) — so this was **preventive hardening**, not
  a fix for something broken. The vendor binary on this machine lives at
  `/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf` (not under
  `/usr/local` — unowned by any pacman package, confirmed via `pacman -Qo`),
  a different layout than Ubuntu's `/usr/local/lib/konica/...` retrofit tree.
  Patched in place with `patchelf`; confirmed via `ldd` and a real duplex
  print job.

One caveat this doesn't change: the vendored libs stop tracking security
updates once copied (they're outside `apt`/`pacman`'s management by design —
that's the whole point). Re-run the installer's `vendor_libcups()` step (or
delete `/usr/local/lib/konica/lib/` and re-run the installer) to refresh
them from a newer system/archived copy if that's ever a concern.

---

### 5.2 Ghosting on the Printer Application queue — root-caused and fixed

**Symptom.** Pages printed via `konica206uri` carried a **ghost**: a band across
the lower part of the sheet repeating content that should not be there. It
affected simplex and duplex alike.

**Root cause.** `245igdirf` always declares the **full** sheet in PJL
(`PAPERWIDTH=4958`, `PAPERLENGTH=7016` = 595.0 × 841.9 pt at 600 dpi), but the
raster it receives is sized from the media collection's imageable area, which
comes from the driver PPD's `*ImageableArea`. An inset value makes the raster
**shorter than the canvas**, so the image is rendered into the wrong vertical
extent and already-decoded scanlines reappear lower down.

Measured by instrumenting the filter and reading the real raster geometry:

| Path | Raster fed to `245igdirf` | PJL canvas | Result |
|---|---|---|---|
| PAPPL, inset `*ImageableArea` | **4860 × 6816** | 4958 × 7016 | **ghost** (height 200px / 2.9% short) |
| PAPPL, full-page `*ImageableArea` | **4961 × 7016** | 4958 × 7016 | **clean** |
| Classic CUPS, full-page `*ImageableArea` | **4961 × 7016** | 4958 × 7016 | **clean** |

The job's own `media-col` shows the mechanism exactly:

```
media-size 21000 x 29700 (1/100mm), margins left/right=212, top/bottom=423
→ imageable 20576 x 28854 (1/100mm) = 8.101 x 11.361 in → 4860 x 6816 px @600dpi
```

`212`/`423` (1/100 mm) are exactly the `6 pt`/`12 pt` inset from the real-margin
retrofit PPD.

**Fix.** Force `*ImageableArea` to equal `*PaperDimension` for **every** size in
the PAPPL driver PPD. `install_ppds()` does this and then verifies it. Note the
shipped retrofit PPDs are **internally inconsistent** — only A4 and Letter were
full-page, the other 15 sizes were inset and would have ghosted, so an A4-only
test would have looked like a pass.

Two traps worth knowing:

- **`*ImageableArea` must match `*PaperDimension` byte-for-byte** (both
  `"595 842"` for A4). `595.276` vs `595` makes PAPPL reject the driver with
  `Invalid driver left/right margins value -9` — the same class of failure as the
  `-70` error in the original design doc.
- **Size keys can contain spaces** (`FLS_8D125X13D25/FLS 8 1/8 x 13 1/4`), so
  geometry-matching regexes need `[^:]+`, not `\S+`.

**A red herring, recorded so it is not repeated.** The Printer Application stores
a `media-col-default` in `legacy-printer-app.state` with the cups-filters default
margins (`bottom="423" left="141"` = 12 pt / 4 pt). That value never changes —
not on restart, not on delete-and-re-add — and it is **not** what sizes the
raster. Only the per-job `media-col`, which follows the PPD, matters. An earlier
revision of this document wrongly concluded from it that libpappl "hardcoded"
the inset.

Full write-up with measurements and reproduction steps:
`INVESTIGATION-2026-10-03-PAPPL-Ghosting-Bug.md`.

## 6. Verification hashes

| Artifact | SHA-256 |
|---|---|
| Correct gray output (dense A4, PAPPL path) | `bfcaa12f891a0e2d13a9ea29ae6b6fa8186b1717c1cc0fcc838abaf65c7a6a96` |
| Classic USB backend (pristine) | `1ebbe1e68d3f1ffbab2cc0f5a0dc2c0c8393dcb3ea47df74416e73147947dc3f` |
| Vendor driver `245igdirf` (pristine) | `0faf0a69aa772805423a9c4c1e5bb20f74d0bf43daeee676d4fa7c658377380d` |
| Custom chunked backend binary | `d76e61bc...` (see backup `SHA256SUMS`) |
| Current Option A backup tarball | `afbf81f9820621f8f1963e44f595f7080a26ec4fff178090059bd906a8e9c05b` |
| Historical 2026-08-16 backup tarball | `ffd619371c0f685a57efbf6502446c358da45b665938bec3d1f9c83676affda8` |

Every file in the current `backup/konica-pappl-backup-20260818-1532/` snapshot is covered by its own
`SHA256SUMS` manifest (verified on capture). The 2026-08-16 snapshot is retained as historical reference.

---

## 7. Environment reference

- Host: Ubuntu 26.04, CUPS 2.4.16 (.deb, no snap), kernel recent.
- Printer: Konica Minolta 206, USB serial `A8A6041029423`, VID `132b`, PID
  `232b`, USB device uses interface 1 / bulk OUT endpoint `0x01`.
- `legacy-printer-app` 1.0~b2-0ubuntu8 (pappl-retrofit), `libpappl1t64` 1.4.9,
  driver `konica-minolta-245igdi-cups` 2.01.
- PAPPL printer driver name: `konica-minolta--206--full-bleed-retrofit-en`
  (full-page geometry is a correctness requirement, not a cosmetic choice — §5.2).
- Default printer: `KONICA_MINOLTA_206` (system + user). Both queues default to
  A4 + one-sided (simplex) and both handle simplex and duplex; see §5.2 for why
  the PPD geometry is the critical variable, and note `konica206uri` is the
  CUPS-3.0-proof path while `KONICA_MINOLTA_206` needs CUPS 2.x.
- `avahi-daemon` is a hard dependency of the Printer Application — see §7.1.

### 7.1 Installer bugs found and fixed on a fresh Ubuntu 26.04 machine

Found while deploying this repo from scratch on 2026-10-03. All four are fixed
in `install-konica-anylinux.sh`.

1. **`avahi-daemon` not started → Printer Application aborts.**
   PAPPL registers with mDNS/DNS-SD at startup and exits 1 with
   `Unable to register system, is the Avahi daemon running?`. On a minimal
   install Avahi is present but not enabled, so the failure looks unrelated.
   The installer now enables/starts `avahi-daemon.service` and the systemd
   drop-in gained `After=`/`Wants=avahi-daemon.service`.

2. **`wait_for_app()` deadlocked on a fresh machine.** It waited for the
   *queue* to exist, but the queue is created later by `create_queues()` — so
   on a machine with no pre-existing `konica206uri` queue it always timed out
   and silently skipped queue creation. It now waits for the *server*
   (`legacy-printer-app status` reporting `Running`).

3. **Hardcoded driver name was wrong.** The old default
   `konica-minolta--206--full-bleed-retrofit-en` no longer matches what the
   build advertises. Worse, `legacy-printer-app drivers` **lists** user-added
   PPDs with an extra `-user-added` token (`...-retrofit-user-added-en`) while
   `legacy-printer-app add -m` only **accepts** the plain name
   (`...-retrofit-en`) and rejects the suffixed one with
   `Driver '...' cannot be used with this printer.` The installer now resolves
   the name at runtime from `legacy-printer-app drivers` (matching on
   `DRIVER_MATCH`, default `real-margin-retrofit`) and strips only the
   `-user-added` token, keeping the `-en` language suffix.

4. **`konica206uri-ppd` aborted every job.** It was pointed at
   `KonicaMinolta-206-real-margins.ppd`, which is the PAPPL *driver* PPD; its
   `*cupsFilter: ... 245igdirf` made CUPS run the vendor GDI filter locally, so
   PAPPL received `application/vnd.printer-specific` instead of raster and the
   job aborted (`[Job N] Aborted, job-impressions-completed=0`). Both CUPS
   queues now use the generated driverless shim PPD, whose `*cupsFilter2`
   lines pass documents straight through to PAPPL.

### 7.2 Verified working on this machine (2026-10-03)

All of these were confirmed **on paper** by the owner. Note the lesson: every
defect found here was invisible in the job data stream (`DUPLEX=ON`, correct
page count, filter exit 0 all looked perfect while the paper was wrong).

| Check | Queue | Result |
|---|---|---|
| Duplex long-edge, A4 | `konica206uri` | clean |
| Simplex, real quotation PDF, pure defaults | `konica206uri` | clean |
| Duplex long-edge, real 2-page .docx | `KONICA_MINOLTA_206` | clean |
| Simplex, real quotation PDF | `KONICA_MINOLTA_206` | clean |
| Shim PPD | `konica206uri` | 24 standard sizes, A4, `*DefaultDuplex: None`, 0 borderless refs |
| PPD geometry | driver PPD | 24/24 sizes full-page, guard check OK |
| `systemctl restart cups legacy-printer-app` | both | queues, PPDs and defaults survive |

Not verified on paper: non-A4 sizes — only A4 is loaded in the machine and the
printer reports a page-size error otherwise.

## 8. Related local files (this machine)

- Current Option A backup: `/home/vinod/konica-pappl-backup-20260818-1532/` and
  `/home/vinod/konica-pappl-backup-20260818-1532.tar.gz`
- Historical backup: `/home/vinod/konica-pappl-backup-20260816-1050.tar.gz`
- Earlier snapshot: `/home/vinod/konica-printer-backup-20260807-153913/`
- Design doc: `/home/vinod/KONICA_206_RETROFIT_DOCUMENTATION.md`
- Investigation log: `/home/vinod/KONICA_PAPPL_RETROFIT_INVESTIGATION.md`
- Root-cause analysis: `/home/vinod/KONICA_ARCH_VS_UBUNTU_ROOTCAUSE.md`
