#!/bin/bash
#
# setup-konica-debian13.sh
#
# Install and configure the Konica Minolta 206 retrofit on Debian 13 (Trixie).
# Replicates the working Ubuntu 26.04 configuration:
#   - legacy-printer-app (pappl-retrofit) exposes an IPP queue "konica206uri"
#   - rendering by the vendor 245igdi driver (bundled in this kit)
#   - device scheme "cups:" -> self-contained chunked USB backend (libusb only)
#   - CUPS passthrough queue "konica206uri" for GUI apps (Atril etc.)
#
# Run as root:  sudo ./setup-konica-debian13.sh
#
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRINTER_NAME="konica206uri"
DRIVER_NAME="konica-minolta--206--full-bleed-retrofit-en"
URI="cups:usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1"
PAPPL_PPD_DIR="/var/lib/legacy-printer-app/ppd"
BACKEND_DIR="/usr/local/libexec/konica-backend"
IPP_ENDPOINT="http://localhost:8000/ipp/print/${PRINTER_NAME}"

log()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run as root (sudo)"

log "Checking OS..."
. /etc/os-release
[ "$ID" = "debian" ] || log "NOTE: not Debian ($PRETTY_NAME); continuing anyway"

log "Installing required packages..."
apt-get update
apt-get install -y \
    cups \
    cups-client \
    gcc \
    libusb-1.0-0-dev \
    ipptool \
    || true

# legacy-printer-app may or may not be in the Debian repo. Try it.
if ! apt-get install -y legacy-printer-app 2>/dev/null; then
    log "WARNING: 'legacy-printer-app' not found in Debian repos."
    log "         Install it manually (build pappl-retrofit from source, or"
    log "         add a repo providing it), then re-run this script."
    log "         See README-debian13.md for the source-build path."
fi

command -v legacy-printer-app >/dev/null 2>&1 || \
    fail "legacy-printer-app binary missing after install."

log "Installing the vendor 245igdi driver (from this kit)..."
install -d /usr/share/cups/model/KonicaMinolta
cp -r "$KIT_DIR/packages/usr/share/cups/model/KonicaMinolta/." \
      /usr/share/cups/model/KonicaMinolta/
install -d /usr/lib/cups/filter/KonicaMinolta/245igdi
cp -r "$KIT_DIR/packages/usr/lib/cups/filter/KonicaMinolta/245igdi/." \
      /usr/lib/cups/filter/KonicaMinolta/245igdi/
chmod 755 /usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf

log "Installing retrofit PPDs into the Printer Application PPD dir..."
install -d "$PAPPL_PPD_DIR"
cp "$KIT_DIR/ppds/KonicaMinolta-206-fullbleed.ppd" "$PAPPL_PPD_DIR/"
cp "$KIT_DIR/ppds/KonicaMinolta-206-real-margins.ppd" "$PAPPL_PPD_DIR/"
cp "$KIT_DIR/ppds/konica206-pdf-fullbleed.ppd" "$PAPPL_PPD_DIR/"

log "Building the self-contained chunked USB backend..."
install -d "$BACKEND_DIR"
gcc -O2 -Wall -o "$BACKEND_DIR/usb" "$KIT_DIR/src/konica-usb-backend.c" \
    -I/usr/include/libusb-1.0 -lusb-1.0
chown root:root "$BACKEND_DIR/usb"
chmod 755 "$BACKEND_DIR/usb"

log "Installing the ensure/persistence helper..."
install -d /usr/local/bin
install -m 755 "$KIT_DIR/scripts/ensure-konica206uri.sh" /usr/local/bin/ensure-konica206uri.sh
install -d /usr/local/share/konica206uri
install -m 644 "$KIT_DIR/scripts/set-media-default.test" /usr/local/share/konica206uri/set-media-default.test

log "Installing the systemd drop-in..."
install -d /etc/systemd/system/legacy-printer-app.service.d
cat > /etc/systemd/system/legacy-printer-app.service.d/override.conf <<EOF
[Service]
Environment=PPD_PATHS=${PAPPL_PPD_DIR}:/usr/share/cups/model:/usr/lib/cups/driver
ExecStart=
ExecStart=legacy-printer-app server -o log-level=debug -o backend-directory=${BACKEND_DIR}
ExecStartPost=/usr/local/bin/ensure-konica206uri.sh
EOF
systemctl daemon-reload
systemctl enable --now legacy-printer-app.service

log "Waiting for the Printer Application to come up..."
for i in $(seq 1 30); do
    legacy-printer-app printers 2>/dev/null | grep -q "^$PRINTER_NAME$" && break
    sleep 1
done

log "Creating/repairing the Printer Application queue..."
legacy-printer-app delete -d "$PRINTER_NAME" 2>/dev/null || true
legacy-printer-app add -d "$PRINTER_NAME" -v "$URI" -m "$DRIVER_NAME"

log "Setting A4 as the PAPPL media default..."
ipptool -tv "$IPP_ENDPOINT" "$KIT_DIR/scripts/set-media-default.test" >/dev/null 2>&1 || true

log "Creating the CUPS passthrough queue for GUI apps..."
lpadmin -p "$PRINTER_NAME" -v "ipp://localhost:8000/ipp/print/$PRINTER_NAME" \
    -P "$PAPPL_PPD_DIR/konica206-pdf-fullbleed.ppd" -E

log "Setting $PRINTER_NAME as the system default printer..."
lpadmin -d "$PRINTER_NAME"
lpoptions -d "$PRINTER_NAME" 2>/dev/null || true

log "Restarting CUPS so print-color-mode-supported is advertised..."
systemctl restart cups

log "Done."
echo
echo "Verification:"
echo "  systemctl status legacy-printer-app"
echo "  lpstat -p $PRINTER_NAME"
echo "  lpstat -d"
echo "  legacy-printer-app printers"
echo
echo "Test print (A4, 2-sided):"
echo "  lp -d $PRINTER_NAME -o media=iso_a4_210x297mm -o sides=two-sided-long-edge <file.pdf>"