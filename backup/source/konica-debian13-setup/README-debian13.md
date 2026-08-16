# Konica Minolta 206 — Debian 13 Setup Kit

This kit installs the working Konica 206 retrofit (the same configuration verified
on Ubuntu 26.04) on **Debian 13 (Trixie)**.

## What this kit contains

```
konica-debian13-setup/
├── packages/                          # Vendor 245igdi driver (PPDs + filter tree)
│   └── usr/{share/cups/model/KonicaMinolta, lib/cups/filter/KonicaMinolta/245igdi}
├── ppds/
│   ├── KonicaMinolta-206-fullbleed.ppd      # PAPPL driver PPD (active, TonerSave TRUE)
│   ├── KonicaMinolta-206-real-margins.ppd   # PAPPL driver PPD (alternate)
│   └── konica206-pdf-fullbleed.ppd          # CUPS passthrough PPD (GUI apps)
├── src/konica-usb-backend.c          # Self-contained chunked USB backend (libusb only)
├── scripts/
│   ├── setup-konica-debian13.sh      # One-shot installer (run as root)
│   ├── ensure-konica206uri.sh        # ExecStartPost persistence helper
│   └── set-media-default.test        # ipptool Set-Printer-Attributes (A4 default)
└── README-debian13.md                # This guide
```

## Quick start

```bash
# copy the kit to the Debian 13 machine (it has the printer attached)
scp -r konica-debian13-setup user@debian13:~/konica-debian13-setup

# on the Debian 13 machine:
cd ~/konica-debian13-setup
sudo ./scripts/setup-konica-debian13.sh
```

The script installs dependencies, the vendor driver, the retrofit PPDs, builds
and installs the chunked USB backend at `/usr/local/libexec/konica-backend/usb`,
configures `legacy-printer-app` via a systemd drop-in, creates the PAPPL queue
`konica206uri` (device URI `cups:usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1`),
adds the CUPS passthrough queue for GUI apps, sets A4 as media default, and makes
it the default printer.

## Prerequisites

- Debian 13 with the Konica 206 plugged in via USB (serial `A8A6041029423`).
- Root access.
- The vendor driver in `packages/` is the **same binary** as the Ubuntu driver.
  It is model-specific (shared 205i/225i/245i family) but works with the 206.
- The script expects the printer to answer at the same USB serial. If your
  printer's serial differs, edit the `URI` in `setup-konica-debian13.sh` and in
  `ensure-konica206uri.sh`.

## Known issue: `legacy-printer-app` package availability

Debian 13 may not ship `legacy-printer-app` in its repositories. The installer
attempts `apt-get install legacy-printer-app` and continues if it fails, but you
**must** provide the binary yourself before it can proceed. Options:

1. **Build from source (recommended):**
   ```bash
   sudo apt-get install -y build-essential autoconf automake libtool pkg-config \
     libcups2-dev libcupsfilters-dev libppd-dev libpappl-dev libusb-1.0-0-dev
   git clone https://github.com/OpenPrinting/pappl-retrofit.git
   cd pappl-retrofit
   ./autogen.sh && ./configure --enable-legacy-printer-app-as-daemon
   make && sudo make install
   ```
   (Requires `libpappl-dev` from the Debian repos; install it with apt.)

2. **Grab the Ubuntu `.deb`** (`legacy-printer-app_1.0~b2-*_amd64.deb` +
   `libpappl-retrofit1_1.0~b2-*_amd64.deb` from the `universe` pocket) and install
   with `dpkg -i`. This is what the kit's scripts were validated against.

After installing the binary, re-run `sudo ./scripts/setup-konica-debian13.sh`.

## Verify

```bash
systemctl status legacy-printer-app      # active (running)
lpstat -p konica206uri                    # enabled / idle
lpstat -d                                 # default: konica206uri
legacy-printer-app printers               # konica206uri
```

Print a test (A4, 2-sided):

```bash
lp -d konica206uri -o media=iso_a4_210x297mm -o sides=two-sided-long-edge <file.pdf>
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Queue not created | `sudo journalctl -u legacy-printer-app -n 50`; confirm driver name and device URI |
| `Unable to open device` | The device URI must be exactly `cups:usb://KONICA%20MINOLTA/206?serial=<serial>&interface=1` |
| Black pages | Confirm `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd` has `*DefaultOCM_TonerSave: TRUE` |
| Printer wedges in "data receiving" | Power-cycle the printer; large single USB writes are prevented by the chunked backend |
| Banner/test pages wedge | Known limitation — use the classic queue or a non-banner PDF |
| Atril says unsupported media | Confirm the passthrough PPD declares A4 as `595.28 841.89 pt` and CUPS was restarted |
| Atril color rejected | CUPS must advertise `print-color-mode-supported = monochrome` (restart cups after PPD install) |

## Notes

- The `cups:` device scheme runs `/usr/local/libexec/konica-backend/usb`, a
  libusb-only backend, so it is **CUPS 3.0-proof** (no dependency on classic CUPS
  backends or `libcups`).
- The classic CUPS path (`KONICA_MINOLTA_206`) is deliberately not created by this
  kit; it does not survive CUPS 3.0 and is only needed as a banner/test-page
  fallback on CUPS 2.x. If you want it, create it with `lpadmin` using the vendor
  `245igdi.ppd` and URI `usb://KONICA%20MINOLTA/206?serial=<serial>&interface=1`.
- Full background and root causes are in
  `KONICA_206_RETROFIT_DOCUMENTATION.md` on the source Ubuntu machine.