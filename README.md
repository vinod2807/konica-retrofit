# Konica Minolta 206 — CUPS/PAPPL Retrofit Backup

Complete, self-contained backup and restore kit for the permanent dual-queue
printing setup for the **Konica Minolta 206** GDI laser printer on this
machine (Ubuntu 26.04, `legacy-printer-app` 1.0~b2-0ubuntu8, CUPS 2.4.16).

Captured: **2026-08-16**. This repository is a mirror of the local backup at
`/home/vinod/konica-pappl-backup-20260816-1050/` plus this documentation.

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

> Restoring just the configuration on an already-set-up machine is covered in
> §3; a full manual Debian/Ubuntu kit is under `backup/.../source/konica-debian13-setup/`.

---

## 1. What this setup is

Two independent printing queues that both drive the same physical printer over
USB:

| Queue | Scheduler | How it talks to the printer | Status |
|---|---|---|---|
| `KONICA_MINOLTA_206` | classic CUPS | `/usr/lib/cups/backend/usb` (classic, needs `libcups.so.2`) | works today; **breaks under CUPS 3.0** (kept only as fallback) |
| `konica206uri` | `legacy-printer-app` (PAPPL) | own filter chain → self-contained libusb backend | **primary queue**, CUPS-3.0-proof |

The PAPPL queue is the one GUI applications use (Atril, etc.) via the CUPS
passthrough queue `konica206uri` → `ipp://localhost:8000/ipp/print/konica206uri`.

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
├── konica-pappl-backup-20260816-1050.tar.gz     # single-file backup (6.9 MB)
└── konica-pappl-backup-20260816-1050/           # same backup, extracted
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

## 3. How to restore

### 3a. Restore the printer setup on this machine (files only)

Restores config + binaries + state. The PAPPL app must be installed (see §3b
for that).

```bash
cd /home/vinod/konica-pappl-backup-20260816-1050
sha256sum -c SHA256SUMS          # verify integrity first (all lines must be OK)

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
cd backup/konica-pappl-backup-20260816-1050/debs
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
- creates the PAPPL queue `konica206uri` and the CUPS passthrough queue, sets
  A4 + system default, and verifies

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
5. **A4, monochrome, 2-sided** are the supported options (the passthrough PPD is
   `ColorModel Gray` only, A4 default, `konica206-pdf-fullbleed.ppd`).
6. **Package holds — optional, not currently applied.** Holds on
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

---

## 5. Known limitations

- **Banner/test-page PDFs** (`application/vnd.cups-pdf-banner`, e.g. CUPS test
  pages, `job-sheets`) still wedge the printer through the PAPPL queue. Use the
  classic queue for those, and power-cycle the printer to recover from a wedge.
- The classic queue doesn't survive CUPS 3.0 (by design; keep it only as a
  fallback on CUPS 2.x systems).
- The vendor driver `245igdirf` links `libcups.so.2`, so if the distro ever
  removes `libcups2` entirely the driver must run under a libcups2-compat
  environment or be replaced (the archived `libcups2t64` deb covers reinstalls).

---

## 6. Verification hashes

| Artifact | SHA-256 |
|---|---|
| Correct gray output (dense A4, PAPPL path) | `bfcaa12f891a0e2d13a9ea29ae6b6fa8186b1717c1cc0fcc838abaf65c7a6a96` |
| Classic USB backend (pristine) | `1ebbe1e68d3f1ffbab2cc0f5a0dc2c0c8393dcb3ea47df74416e73147947dc3f` |
| Vendor driver `245igdirf` (pristine) | `0faf0a69aa772805423a9c4c1e5bb20f74d0bf43daeee676d4fa7c658377380d` |
| Custom chunked backend binary | `d76e61bc...` (see backup `SHA256SUMS`) |
| Backup tarball | `ffd619371c0f685a57efbf6502446c358da45b665938bec3d1f9c83676affda8` |

Every file in `backup/konica-pappl-backup-20260816-1050/` is covered by its own
`SHA256SUMS` manifest (verified on capture).

---

## 7. Environment reference

- Host: Ubuntu 26.04, CUPS 2.4.16 (.deb, no snap), kernel recent.
- Printer: Konica Minolta 206, USB serial `A8A6041029423`, VID `132b`, PID
  `232b`, USB device uses interface 1 / bulk OUT endpoint `0x01`.
- `legacy-printer-app` 1.0~b2-0ubuntu8 (pappl-retrofit), `libpappl1t64` 1.4.9,
  driver `konica-minolta-245igdi-cups` 2.01.
- PAPPL printer driver name: `konica-minolta--206--full-bleed-retrofit-en`.
- Default printer: `konica206uri` (system + user).

---

## 8. Related local files (this machine)

- Full backup: `/home/vinod/konica-pappl-backup-20260816-1050/` and
  `/home/vinod/konica-pappl-backup-20260816-1050.tar.gz`
- Earlier snapshot: `/home/vinod/konica-printer-backup-20260807-153913/`
- Design doc: `/home/vinod/KONICA_206_RETROFIT_DOCUMENTATION.md`
- Investigation log: `/home/vinod/KONICA_PAPPL_RETROFIT_INVESTIGATION.md`
- Root-cause analysis: `/home/vinod/KONICA_ARCH_VS_UBUNTU_ROOTCAUSE.md`
