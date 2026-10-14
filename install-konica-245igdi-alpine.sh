#!/bin/sh
# Install the Konica Minolta 245i GDI filter (245igdirf) on Alpine Linux (musl),
# for a bizhub 206.
#
# Tested: Alpine 3.21.3 x86_64, musl 1.2.5, CUPS 2.4.x, cups-filters 2.x.
# See https://github.com/vinod2807/ubuntu-printing for the glibc-host reference.
#
# ===========================================================================
# STATUS: LOADS BUT DOES NOT PRINT. DO NOT EXPECT A WORKING QUEUE.
# ===========================================================================
# Real-hardware test 2026-10-14 (Alpine 3.21.3 chroot, bizhub 206 over USB):
#
#   Works on musl: cupsd, pdftopdf, pdftoraster, and the usb backend - which
#                  correctly discovers the printer
#                  (MDL:206;CLS:PRINTER;CID:KONICA MINOLTA206) and opens it.
#   FAILS:         245igdirf exits non-zero before emitting any device data,
#                  so the backend logs "Sent 0 bytes". No page prints.
#
# Why: 245igdirf is a glibc binary and gcompat is an ~83 KB shim, not a libc.
# All 13 CUPS symbols it needs are UNVERSIONED and do resolve, so this is NOT
# a missing-symbol problem - it is that the raster/PPD/colour work behind those
# symbols runs against a libc the process is not really using. Observed: the
# loader re-reads one ELF header from an inherited fd 20 times with musl libcups;
# substituting a glibc-built libcups moves the failure from status 2 to status 9
# - behaviour changes, output never appears.
#
# Everything below still matters for packaging/diagnosis, but this is NOT a
# working printing stack on musl. For a musl target, port konica206-native (your
# own C source) instead - it links cleanly and bypasses the vendor binary.
#
# Alpine-specific gotchas from that test, beyond the shims below:
#   * ghostscript 10.05.1's "cups" device fails on EVERY page here
#     ("Page drawing error occurred" -> 0-byte raster). Install poppler-utils
#     and disable the gstoraster -> cups-raster MIME lines, as section 2 of the
#     ubuntu-printing README describes; pdftoraster then works.
#   * Use the FULL-BLEED 206 PPD. The real-margins PPD feeds HWMargins into
#     setpagedevice and makes this look like a driver bug.
#
# USAGE
#   ./install-konica-245igdi-alpine.sh <BH225iGDILinux_201MU.zip> [patched-245igdirf]
#
#   arg2 is OPTIONAL: the PATCHED filter from the glibc host, i.e.
#     /usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf
#   plus mtorf.ocm beside it. The zip only contains the STOCK filter, and the
#   stock one is NOT what is known to work on the 206 - always pass it if you
#   have it.
#
# WHY SHIMS ARE NEEDED
#   245igdirf is a 2013 glibc binary needing only GLIBC_2.3.2. On musl:
#
#     1. gcompat      -> ld-linux-x86-64.so.2, libc.so.6, libm.so.6,
#                         libpthread.so.0
#     2. libdl.so.2   -> gcompat does NOT ship it. 245igdirf DT_NEEDEDs it but
#                         imports only dlopen/dlsym/dlclose/dlerror, all merged
#                         into libc since glibc 2.34. An empty stub is enough.
#
#   libcups.so.2 / libcupsimage.so.2: Alpine's OWN musl builds are used and work.
#   They resolve all 13 imported symbols, all UNVERSIONED:
#     libcups.so.2      cupsGetOption cupsParseOptions cupsMarkOptions
#                        ppdOpenFile ppdClose ppdFindAttr ppdFindMarkedChoice
#                        ppdIsMarked ppdMarkDefaults ppdPageSize
#     libcupsimage.so.2 cupsRasterOpen cupsRasterReadHeader cupsRasterReadPixels
#   Do NOT drop a glibc-built libcups in here; the musl one works and a second
#   libc in a gcompat process is needless risk.
#
# PPD NOTES (learned the hard way on the Ubuntu host)
#   * Use a 206 retrofit PPD, NOT the shipped 205/225/245i ones.
#   * The PPD must contain ZERO *cupsICCProfile lines. Ghostscript is built
#     without ICC support; if those lines are present CUPS passes
#     -sOutputICCProfile= and every job dies in gstoraster with
#     "undefined in .putdeviceprops" (status 255), and then 245igdirf gets a
#     0-byte raster and exits 7/9.
#   * Keep "*cupsBackSide: Rotated" or duplex prints at the wrong edge.
#   * PPD comments must start with "*" (use *%). A leading "#" makes CUPS reject
#     the file with "Missing asterisk in column 1".
#
set -eu

ZIP="${1:-}"
PATCHED="${2:-}"
[ -n "$ZIP" ] || { echo "usage: $0 <zip> [patched-245igdirf]" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "not found: $ZIP" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

VENDOR=/usr/local/lib/konica/KonicaMinolta/245igdi
DEST=$VENDOR/Filters
log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ packages
log "Installing packages"
apk add --no-cache gcompat cups cups-client cups-filters cups-dev ghostscript build-base

# ------------------------------------------------------------------ driver
log "Extracting $ZIP"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unzip -qo "$ZIP" 'BH225iGDILinux_201MU/For_x86_64/*' -d "$TMP"
DEB=$(find "$TMP" -name '*.deb' | head -1)
[ -n "$DEB" ] || die "no x86_64 .deb inside $ZIP"

mkdir -p "$TMP/x"
( cd "$TMP/x" && ar x "$DEB" )
DATA=$(ls "$TMP"/x/data.tar.* 2>/dev/null | head -1)
[ -n "$DATA" ] || die "no data.tar.* in $DEB"
tar -xf "$DATA" -C /            # PPDs + Profiles/Colorworlds/Halftones

# Reproduce the WORKING layout: everything under /usr/local/lib/konica, so the
# 206 retrofit PPD works verbatim with no path rewriting.
mkdir -p "$VENDOR"
cp -a /usr/lib/cups/filter/KonicaMinolta/245igdi/. "$VENDOR/"
rm -rf "$VENDOR/Filters/245igdirf.orig" "$VENDOR/Filters/245igdirf.orig2"

if [ -n "$PATCHED" ]; then
  [ -f "$PATCHED" ] || die "patched filter not found: $PATCHED"
  log "Installing PATCHED filter from $PATCHED"
  cp -f "$PATCHED" "$DEST/245igdirf"
else
  log "WARNING: using the STOCK filter from the zip."
  log "         The stock filter is not the known-good one for the 206."
  log "         Pass it as arg 2 if you have the patched copy."
fi
chmod 755 "$DEST/245igdirf"

# mtorf.ocm must sit beside the filter; the filter enumerates *.ocm in its own
# directory at runtime.
[ -f "$DEST/mtorf.ocm" ] || die "mtorf.ocm missing"
ln -sf "$DEST/mtorf.ocm" "$DEST/245igdirf.ocm"

# ------------------------------------------------------------------ libdl
if [ ! -e /lib/libdl.so.2 ] && [ ! -e /usr/lib/libdl.so.2 ]; then
  log "gcompat has no libdl.so.2 - building empty stub"
  printf 'int _konica_dl_stub;\n' > "$TMP/dl.c"
  gcc -shared -fPIC -o /lib/libdl.so.2 "$TMP/dl.c"
  chmod 755 /lib/libdl.so.2
fi

# ------------------------------------------------------------------ verify
log "Verifying: 245igdirf resolves its libraries"
ldd "$DEST/245igdirf" 2>&1 | grep 'not found' && die "unresolved libraries (above)" || true
ldd "$DEST/245igdirf" | sed 's/^/    /'

log "Verifying: filter starts under gcompat"
"$DEST/245igdirf" >/dev/null 2>&1 || true   # exits 4 with no job context; normal

log "Verifying: CUPS resolves the PPD filter"
PPD=""
for c in /usr/share/ppd/KonicaMinolta-206-*.ppd /var/lib/legacy-printer-app/ppd/KonicaMinolta-206-*.ppd; do
  [ -f "$c" ] && { PPD="$c"; break; }
done
if [ -n "$PPD" ]; then
  n=$(grep -c cupsICCProfile "$PPD" || true)
  [ "$n" = 0 ] || die "$PPD still has $n *cupsICCProfile lines - remove them"
  printf '%%%%!PS-Adobe-3.0\nshowpage\n' > "$TMP/t.ps"
  cupsfilter -m application/vnd.cups-raster -p "$PPD" "$TMP/t.ps" > "$TMP/t.ras" 2>"$TMP/t.log" || true
  if grep -q 'Last filter determined by the PPD: 245igdirf' "$TMP/t.log"; then
    log "OK - CUPS resolved 245igdirf as the terminal filter for $PPD"
  else
    die "CUPS did not resolve the PPD filter; see $TMP/t.log"
  fi
else
  log "No 206 PPD found - copying one in is a manual step (see header notes)"
fi

cat <<EOF

Installed.

  filter : $DEST/245igdirf        ($(stat -c%s "$DEST/245igdirf") bytes)
  ocm    : $DEST/mtorf.ocm  (+ 245igdirf.ocm symlink)

Queue (classic CUPS path):
  lpadmin -p KONICA_MINOLTA_206 \\
    -v "usb://KONICA%20MINOLTA/206?serial=<SERIAL>&interface=1" \\
    -P <206-retrofit.ppd> -D "KONICA MINOLTA 206" -L "USB" -E

Duplex is per-job, not from the PPD:
  lp -d KONICA_MINOLTA_206 -o media=A4 -o sides=one-sided            file.pdf
  lp -d KONICA_MINOLTA_206 -o media=A4 -o sides=two-sided-long-edge  file.pdf
(Only print on one queue at a time - they share the USB device.)

VERIFIED: loads under gcompat, 13/13 CUPS symbols resolve, patched filter runs,
CUPS resolves the PPD filter. NOT VERIFIED: real raster->device output, which
needs a live queue on real hardware.
EOF