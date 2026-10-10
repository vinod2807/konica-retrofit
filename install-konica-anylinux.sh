#!/usr/bin/env bash
#
# install-konica-anylinux.sh
#
# Distro-agnostic installer for the Konica Minolta 206 retrofit.
# Rebuilds the working "konica206uri" PAPPL + CUPS setup on a fresh Linux
# machine, reading all required files from this repository (clone it to the
# target first). Tested layout targets: Debian/Ubuntu, Fedora/RHEL, Arch,
# openSUSE; any glibc distro with bash, gcc and libusb-1.0.
#
# Run as root:  sudo ./install-konica-anylinux.sh
#
# Optional:  sudo ./install-konica-anylinux.sh --serial <SERIAL>
#            sudo ./install-konica-anylinux.sh --no-source-build
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BK="$REPO_DIR/backup"                      # extracted backup tree lives here

KONICA_SERIAL="${KONICA_SERIAL:-}"
DO_SOURCE_BUILD=1
SERVER_PORT="${SERVER_PORT:-8000}"

PRINTER_NAME="konica206uri"

# Paper handling. A4 + one-sided (simplex) are the queue defaults; duplex
# stays available via -o sides=two-sided-long-edge / -o sides=two-sided-short-edge.
#
# DRIVER_MATCH selects which retrofit PPD drives the Printer Application, and
# it MUST be the full-page-geometry one ("full-bleed-retrofit"). This is not
# about aesthetics -- it is a correctness requirement:
#
#   * 245igdirf always declares the FULL sheet in PJL:
#     PAPERWIDTH=4958, PAPERLENGTH=7016 (595.0 x 841.9 pt at 600dpi).
#   * The raster it receives is sized from the media collection's imageable
#     area, which comes from the PPD's *ImageableArea.
#   * With an inset *ImageableArea (the real-margin PPD, "6 12 589 830") the
#     raster is 4860 x 6816 -- 200px (2.9%) short of the declared canvas. The
#     printer then renders the image into the wrong vertical extent and
#     repeats already-decoded scanlines, which shows up as a "ghost" band
#     across the lower part of the sheet. Measured on real documents:
#       real-margin PPD -> raster 4860 x 6816 -> GHOSTS (simplex AND duplex)
#       full-page  PPD  -> raster 4961 x 7016 -> clean  (matches canvas)
#   * The classic CUPS queue honours the PPD's *ImageableArea directly, which
#     is why the vendor's full-page value keeps that path correct.
#
# So: any *ImageableArea that is not the full page breaks output on this
# printer. Keep *ImageableArea byte-identical to *PaperDimension per size
# (e.g. both "595 842" for A4) -- mismatched rounding makes PAPPL compute a
# negative margin and reject the driver with
# "Invalid driver left/right margins value -N".
DRIVER_MATCH="${DRIVER_MATCH:-full-bleed-retrofit}"
# NB: non-suffixed form on purpose -- `add` rejects the "-user-added-en" name.
DRIVER_NAME="${DRIVER_NAME:-konica-minolta--206--${DRIVER_MATCH}-en}"
PAPPL_PPD_DIR="/var/lib/legacy-printer-app/ppd"
BACKEND_DIR="/usr/local/libexec/konica-backend"
DRIVER_HOME="/usr/local/lib/konica/KonicaMinolta/245igdi"
ENSURE_BIN="/usr/local/bin/ensure-konica206uri.sh"
MEDIA_TEST_DIR="/usr/local/share/konica206uri"
# The CUPS-facing PPD. Left empty on purpose: create_queues() fills it with
# the driverless shim PPD it generates, which already carries every paper
# size, real (non-borderless) ImageableArea entries and correct
# *cupsFilter2 pass-through lines. Do NOT point this at
# KonicaMinolta-206-real-margins.ppd -- that is the PAPPL *driver* PPD and
# its "*cupsFilter: ... 245igdirf" makes CUPS run the GDI filter locally,
# so PAPPL receives application/vnd.printer-specific instead of raster and
# the job aborts.
PPD_QUEUE_FILE="${PPD_QUEUE_FILE:-}"
# Classic USB queue: the only path where duplex renders correctly.
DUPLEX_QUEUE="${DUPLEX_QUEUE:-KONICA_MINOLTA_206}"
DEFAULT_MEDIA="${DEFAULT_MEDIA:-iso_a4_210x297mm}"
DEFAULT_SIDES="${DEFAULT_SIDES:-one-sided}"
IPP_ENDPOINT="http://localhost:${SERVER_PORT}/ipp/print/${PRINTER_NAME}"

# Paper-size names that must never be offered. Deliberately NOT a blanket
# line filter: the default driver is the full-page-geometry ("full-bleed")
# PPD, so the word can legitimately appear in driver metadata. Only size
# declaration lines are considered, and only when the NAME contains one of
# these tokens.
BORDERLESS_RE='([Ff]ull-?[Bb]leed|[Bb]orderless)'

log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Robust "is printer registered" check: `printers` output is
# distro/build-dependent ("name" on some, "name - printer - ipp://..." on
# others), so match the leading printer name token only.
printer_exists() {  # printer_exists <name>
    legacy-printer-app printers 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    echo
    echo "Options:"
    echo "  --serial <SERIAL>    printer serial (default: autodetect, else A8A6041029423)"
    echo "  --no-source-build    never try to build pappl-retrofit from source"
    echo "  --help               this help"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --serial)    KONICA_SERIAL="";; # consumed below (2-arg form)
        --no-source-build) DO_SOURCE_BUILD=0;;
        --help)      usage;;
    esac
done
if [ "$#" -ge 2 ] && [ "$1" = "--serial" ]; then KONICA_SERIAL="$2"; fi

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

# ---------------------------------------------------------------------------
# 1. Distro detection
# ---------------------------------------------------------------------------
DISTRO=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "$ID" in
        debian)                 DISTRO=debian;;
        ubuntu)                 DISTRO=ubuntu;;
        fedora|rhel|centos|rocky|almalinux) DISTRO=fedora;;
        arch|manjaro|endeavouros) DISTRO=arch;;
        opensuse*|sles)         DISTRO=opensuse;;
        *)                      DISTRO="$ID";;
    esac
fi
log "Distro: ${DISTRO:-unknown}"
[ -n "$DISTRO" ] || warn "unrecognized distro; will still install the portable parts"

# ---------------------------------------------------------------------------
# 2. Locate the printer on USB
# ---------------------------------------------------------------------------
detect_serial() {
    local s=""
    if command -v lsusb >/dev/null 2>&1 && lsusb -d 132b:232b >/dev/null 2>&1; then
        s="$(lsusb -v -d 132b:232b 2>/dev/null | awk '/iSerial/{print $NF; exit}')"
    fi
    [ -n "$s" ] || s="${KONICA_SERIAL:-A8A6041029423}"
    printf '%s' "$s"
}
SERIAL="$(detect_serial)"
if [ -n "$KONICA_SERIAL" ]; then SERIAL="$KONICA_SERIAL"; fi
log "Printer serial: $SERIAL (interface 1, bulk OUT 0x01)"

# ---------------------------------------------------------------------------
# 3. Package helpers
# ---------------------------------------------------------------------------
install_pkgs() {  # install_pkgs <names...> (best effort)
    case "$DISTRO" in
        debian|ubuntu)  apt-get update -qq;  apt-get install -y "$@" ;;
        fedora)  dnf install -y "$@" ;;
        arch)    pacman -S --noconfirm --needed "$@" ;;
        opensuse) zypper --non-interactive install "$@" ;;
        *)       warn "cannot auto-install on '$DISTRO'; install manually: $*"; return 1;;
    esac
}

# ---------------------------------------------------------------------------
# 4. Install legacy-printer-app / pappl-retrofit
# ---------------------------------------------------------------------------
# Source-build fallback is pinned to pappl-retrofit 1.0b2 / 77233b6.

install_pappl() {
    if command -v legacy-printer-app >/dev/null 2>&1; then
        log "legacy-printer-app already installed: $(command -v legacy-printer-app)"
        return 0
    fi
    log "Installing legacy-printer-app (pappl-retrofit)..."
    case "$DISTRO" in
        debian|ubuntu)
            if apt-get install -y legacy-printer-app 2>/dev/null; then return 0; fi
            # Fallback: bundled Ubuntu amd64 .debs (works on Debian/Ubuntu amd64)
            if [ "$(uname -m)" = "x86_64" ] && [ -d "$BK/debs" ]; then
                log "Package not in repo; installing bundled .debs..."
                apt-get install -y "$BK"/debs/*.deb
                return 0
            fi
            ;;
        fedora)
            dnf install -y legacy-printer-app pappl-retrofit 2>/dev/null && return 0
            ;;
        arch)
            if command -v paru >/dev/null 2>&1; then paru -S --noconfirm pappl-retrofit && return 0; fi
            if command -v yay >/dev/null 2>&1; then yay -S --noconfirm pappl-retrofit && return 0; fi
            ;;
        opensuse)
            zypper --non-interactive install pappl-retrofit 2>/dev/null && return 0
            ;;
    esac

    if [ "$DO_SOURCE_BUILD" -eq 0 ]; then
        warn "pappl-retrofit not found and source build disabled. Aborting."
        return 1
    fi

    log "pappl-retrofit not packaged here; building from OpenPrinting source..."
    local deps
    case "$DISTRO" in
        debian|ubuntu)  deps="git autoconf automake libtool make gcc g++ pkg-config libcups2-dev libcupsfilters-dev libppd-dev libpappl1-dev libusb-1.0-0-dev libcupsimage2-dev";;
        fedora)  deps="git autoconf automake libtool make gcc gcc-c++ pkgconfig libcups-devel libcupsfilters-devel libppd-devel pappl-devel libusb1-devel";;
        arch)    deps="git autoconf automake libtool make gcc pkg-config cups libcupsfilters libppd pappl libusb";;
        opensuse)deps="git autoconf automake libtool make gcc gcc-c++ pkg-config libcups2-devel libcupsfilters-devel libppd-devel pappl-devel libusb-1_0-devel";;
        *)       warn "unknown distro for build deps; please install them manually";;
    esac
    install_pkgs $deps || warn "build dependency install incomplete"

    # Reproducible source-build fallback:
    # pappl-retrofit 1.0b2 is the known released version used by the current
    # distro packages, and its upstream release commit is 77233b6.
    local pappl_retrofit_tag="1.0b2"
    local pappl_retrofit_commit="77233b6"
    local src=/tmp/pappl-retrofit-src
    rm -rf "$src"

    git clone --depth 1 --branch "$pappl_retrofit_tag" \
        https://github.com/OpenPrinting/pappl-retrofit "$src" \
        || die "source build: clone of pappl-retrofit $pappl_retrofit_tag failed"

    local actual_commit
    actual_commit="$(git -C "$src" rev-parse HEAD)"
    case "$actual_commit" in
        "$pappl_retrofit_commit"|"$pappl_retrofit_commit"*) ;;
        *) die "source build: pappl-retrofit tag $pappl_retrofit_tag resolved to $actual_commit, expected $pappl_retrofit_commit" ;;
    esac
    log "Using pappl-retrofit $pappl_retrofit_tag ($actual_commit)"

    (cd "$src" && ./autogen.sh) \
        || die "source build: autogen.sh failed"
    (cd "$src" && ./configure --enable-legacy-printer-app-as-daemon) \
        || die "source build: configure failed"
    make -C "$src" -j"$(nproc)" \
        || die "source build: compile failed"
    make -C "$src" install \
        || die "source build: install failed"
}

# ---------------------------------------------------------------------------
# 5. Install the vendor driver tree (apt-immune, /usr/local)
# ---------------------------------------------------------------------------
install_driver() {
    log "Installing vendor 245igdi driver under $DRIVER_HOME..."
    [ -d "$BK/usr/local/lib/konica/KonicaMinolta/245igdi" ] || \
        die "driver tree missing in repo ($BK/usr/local/lib/konica/KonicaMinolta/245igdi)"
    install -d "$(dirname "$DRIVER_HOME")"
    rm -rf "$DRIVER_HOME"
    cp -r "$BK/usr/local/lib/konica/KonicaMinolta/245igdi" "$DRIVER_HOME"
    chmod 755 "$DRIVER_HOME/Filters/245igdirf"

    # 245igdirf resolves <basename>.ocm relative to its own directory.
    # Make the OCM configuration resolvable from both the relocated driver
    # tree and the legacy /usr/lib/cups/filter path used by CUPS/PAPPL.
    ln -sf "$DRIVER_HOME/Filters/mtorf.ocm"         "$DRIVER_HOME/Filters/245igdirf.ocm"
    # The PPD's *OCM_resourceDir points at the legacy /usr/lib/cups/filter
    # tree, so point the whole tree at the relocated driver (keeps Colorworlds,
    # Halftones, Profiles, Filters and the OCM config resolvable under CUPS/PAPPL).
    if [ -d "$DRIVER_HOME" ] && [ -d /usr/lib/cups/filter ]; then
        install -d /usr/lib/cups/filter/KonicaMinolta
        rm -rf /usr/lib/cups/filter/KonicaMinolta/245igdi
        ln -sf "$DRIVER_HOME" /usr/lib/cups/filter/KonicaMinolta/245igdi
    fi

    vendor_libcups
}

# ---------------------------------------------------------------------------
# 5b. Vendor libcups.so.2 + libcupsimage.so.2 for the closed-source 245igdirf
#     binary (apt-immune, same pattern as the driver relocation). This is the
#     libcups3/CUPS-3.0 workaround: the vendor binary is hard-linked against
#     the CLASSIC libcups.so.2 ABI and will never be ported. CUPS 3.0 removes
#     libcups2 from the distro but does NOT prevent it from coexisting
#     privately (different SONAME than libcups3), so we extract libcups2 +
#     libcupsimage2 from the archived .debs into a private lib dir and point
#     245igdirf at it via patchelf --set-rpath. This makes the driver
#     immune to the host's libcups version forever, closing the one real
#     unresolved risk in this setup.
# ---------------------------------------------------------------------------
vendor_libcups() {
    local bin="$DRIVER_HOME/Filters/245igdirf"
    local libdir="/usr/local/lib/konica/lib"
    local cups_deb="$BK/debs/libcups2t64_2.4.16-1ubuntu1.3_amd64.deb"
    local cupsimage_deb="$BK/debs/libcupsimage2t64_2.4.16-1ubuntu1.3_amd64.deb"

    if [ -f "$libdir/libcups.so.2" ] && [ -f "$libdir/libcupsimage.so.2" ]; then
        log "Vendored libcups already present at $libdir; skipping re-extract."
    else
        log "Vendoring libcups.so.2 + libcupsimage.so.2 (CUPS-3.0-proofing 245igdirf)..."
        [ -f "$cups_deb" ]      || die "missing $cups_deb (needed to vendor libcups2)"
        [ -f "$cupsimage_deb" ] || die "missing $cupsimage_deb (needed to vendor libcupsimage2)"
        command -v dpkg-deb >/dev/null 2>&1 || install_pkgs dpkg

        local tmp; tmp="$(mktemp -d)"
        dpkg-deb -x "$cups_deb" "$tmp"
        dpkg-deb -x "$cupsimage_deb" "$tmp"

        install -d "$libdir"
        local libarch
        libarch="$(find "$tmp/usr/lib" -maxdepth 1 -type d -name '*-linux-gnu*' | head -n1)"
        [ -n "$libarch" ] || libarch="$tmp/usr/lib/x86_64-linux-gnu"
        cp -r "$libarch"/libcups.so.2* "$libdir/" 2>/dev/null || die "libcups.so.2 not found in $cups_deb"
        cp -r "$libarch"/libcupsimage.so.2* "$libdir/" 2>/dev/null || die "libcupsimage.so.2 not found in $cupsimage_deb"
        rm -rf "$tmp"
    fi

    if ! command -v patchelf >/dev/null 2>&1; then
        install_pkgs patchelf || warn "could not install patchelf; falling back to a wrapper script"
    fi

    if command -v patchelf >/dev/null 2>&1; then
        patchelf --set-rpath "$libdir" "$bin" \
            || die "patchelf failed to set rpath on $bin"
        log "245igdirf now privately linked to $libdir (host libcups version no longer matters)."
    else
        # Fallback: wrap the binary instead of patching it. Rename the real
        # binary aside once, install a shim in its place that sets
        # LD_LIBRARY_PATH and execs it. Idempotent (checks for .real first).
        if [ ! -f "${bin}.real" ]; then
            mv "$bin" "${bin}.real"
            cat > "$bin" <<EOF
#!/bin/sh
# Auto-generated wrapper: points 245igdirf at its private, vendored
# libcups.so.2 / libcupsimage.so.2 so it survives CUPS 3.0's libcups3-only
# host libraries. See vendor_libcups() in install-konica-anylinux.sh.
LD_LIBRARY_PATH="$libdir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" exec "${bin}.real" "\$@"
EOF
            chmod 755 "$bin" "${bin}.real"
        fi
        log "245igdirf wrapped with LD_LIBRARY_PATH=$libdir (patchelf unavailable)."
    fi

    # Final check: the binary must now resolve libcups.so.2 + libcupsimage.so.2
    # from the private dir, independent of whatever CUPS the host ships.
    if command -v ldd >/dev/null 2>&1; then
        local real_bin="$bin"; [ -f "${bin}.real" ] && real_bin="${bin}.real"
        if ! LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
                ldd "$real_bin" 2>/dev/null | grep -q "libcups.so.2 => $libdir"; then
            warn "Could not confirm 245igdirf resolves libcups.so.2 from $libdir."
            warn "Run: ldd $real_bin | grep libcups   — and check the rpath/wrapper manually."
        fi
    fi
}

# ---------------------------------------------------------------------------
# 6. Build the self-contained chunked USB backend
# ---------------------------------------------------------------------------
build_backend() {
    log "Building the chunked USB backend..."
    command -v gcc >/dev/null 2>&1 || install_pkgs gcc
    command -v pkg-config >/dev/null 2>&1 || install_pkgs pkg-config
    pkg-config --exists libusb-1.0 || install_pkgs libusb-1.0-0-dev
    local src="$BK/source/konica-usb-backend/konica-usb-backend.c"
    [ -f "$src" ] || die "backend source missing: $src"
    install -d "$BACKEND_DIR"
    gcc -O2 -Wall -o "$BACKEND_DIR/usb" "$src" \
        $(pkg-config --cflags --libs libusb-1.0) || die "backend build failed"
    chmod 755 "$BACKEND_DIR/usb"
}

# ---------------------------------------------------------------------------
# 7. Install PPDs, ensure script, media-default helper
# ---------------------------------------------------------------------------
install_ppds() {
    log "Installing retrofit PPDs into $PAPPL_PPD_DIR..."
    install -d "$PAPPL_PPD_DIR"
    cp "$BK/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd" "$PAPPL_PPD_DIR/"
    cp "$BK/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-real-margins.ppd" "$PAPPL_PPD_DIR/"
    cp "$BK/var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd" "$PAPPL_PPD_DIR/"

    # The 206 has a working duplexer, but the vendor PPD ships
    # "*DefaultDuplexer: false" (i.e. "not installed"). Combined with the
    # PPD's own "*UIConstraints: *Duplexer false <-> *Duplex DuplexNoTumble"
    # rules that makes GUI apps hide/drop the Duplex choice even though the
    # hardware does duplex. Advertise the unit as installed while keeping
    # "*DefaultDuplex: None" so the queue still DEFAULTS to simplex.
    # Normalise geometry: force EVERY size's *ImageableArea to the full page.
    #
    # The shipped retrofit PPDs are inconsistent -- in
    # KonicaMinolta-206-fullbleed.ppd only A4 and Letter are full-page, while
    # the other 15 sizes still carry a 6pt/12pt inset. Any inset size ghosts,
    # because 245igdirf declares the full sheet in PJL (see the DRIVER_MATCH
    # note above). So rewrite each *ImageableArea to "0 0 <W> <H>" using that
    # size's *PaperDimension.
    normalise_geometry() {
        local p="$1"
        python3 - "$p" <<'PY' || warn "geometry normalisation failed for $p"
import re, sys
path = sys.argv[1]
lines = open(path, encoding='latin-1').read().split('\n')
pd = {}
for ln in lines:
    m = re.match(r'\*PaperDimension\s+([^:]+):\s*"?([\d.]+)\s+([\d.]+)', ln)
    if m:
        pd[m.group(1)] = (m.group(2), m.group(3))
changed = 0
for i, ln in enumerate(lines):
    m = re.match(r'(\*ImageableArea\s+)([^:]+)(:\s*)"[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+"\s*$', ln)
    if not m:
        continue
    d = pd.get(m.group(2))
    if not d:
        continue
    want = '%s%s%s"0 0 %s %s"' % (m.group(1), m.group(2), m.group(3), d[0], d[1])
    if want != ln.rstrip():
        lines[i] = want
        changed += 1
open(path, 'w', encoding='latin-1').write('\n'.join(lines))
print("normalised %d *ImageableArea entries to full page" % changed)
PY
    }

    local p
    for p in "$PAPPL_PPD_DIR/KonicaMinolta-206-real-margins.ppd" \
             "$PAPPL_PPD_DIR/KonicaMinolta-206-fullbleed.ppd"; do
        [ -f "$p" ] || continue
        sed -i -E 's/^\*DefaultDuplexer:[[:space:]]*false/*DefaultDuplexer: true/;
                   s/^\*DefaultDuplex:[[:space:]]*.*/*DefaultDuplex: None/' "$p"
        normalise_geometry "$p"
    done
    log "PPDs: $(ls "$PAPPL_PPD_DIR" | tr '\n' ' ')"
    log "PAPPL driver PPD geometry: $(grep -c '^\*ImageableArea' "$PAPPL_PPD_DIR/KonicaMinolta-206-fullbleed.ppd") sizes, $(grep -c '^\*ImageableArea.*"0 0 ' "$PAPPL_PPD_DIR/KonicaMinolta-206-fullbleed.ppd") full-page"

    # Guard rail: the driver's *ImageableArea MUST equal *PaperDimension for
    # every size. An inset value makes the raster smaller than the canvas
    # 245igdirf declares in PJL, which ghosts the output; a value that is even
    # slightly LARGER makes PAPPL compute a negative margin and refuse the
    # driver ("Invalid driver left/right margins value -N").
    local driver_ppd="$PAPPL_PPD_DIR/KonicaMinolta-206-fullbleed.ppd"
    if [ -f "$driver_ppd" ]; then
        local mismatch
        mismatch="$(python3 - "$driver_ppd" <<'PY'
import re, sys
pd, ia, mism = {}, {}, []
for line in open(sys.argv[1], encoding='latin-1'):
    m = re.match(r'\*PaperDimension\s+([^:]+):\s*"?([\d.]+)\s+([\d.]+)', line)
    if m: pd[m.group(1)] = (float(m.group(2)), float(m.group(3)))
    m = re.match(r'\*ImageableArea\s+([^:]+):\s*"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)"', line)
    if m: ia[m.group(1)] = tuple(float(m.group(i)) for i in (2,3,4,5))
for k, (w, h) in pd.items():
    b = ia.get(k)
    if not b: continue
    if abs(b[0]) > 0.001 or abs(b[1]) > 0.001 or abs(b[2]-w) > 0.001 or abs(b[3]-h) > 0.001:
        mism.append(f"{k}: ImageableArea {b} != full page 0 0 {w} {h}")
print("\n".join(mism))
PY
)"
        if [ -n "$mismatch" ]; then
            warn "driver PPD has non-full-page *ImageableArea -- output WILL ghost:"
            echo "$mismatch" | sed 's/^/    /' >&2
        else
            log "Geometry check OK: all *ImageableArea match *PaperDimension (full page)."
        fi
    fi
}

install_ensure_script() {
    log "Installing persistence helper ($ENSURE_BIN) with serial $SERIAL..."
    install -d "$(dirname "$ENSURE_BIN")" "$MEDIA_TEST_DIR"
    cat > "$ENSURE_BIN" <<EOF
#!/bin/bash
# ensure-konica206uri.sh (generated by install-konica-anylinux.sh)
URI='cups:usb://KONICA%20MINOLTA/206?serial=${SERIAL}&interface=1'
DRIVER='${DRIVER_NAME}'
IPP='ipp://localhost:${SERVER_PORT}/ipp/print/${PRINTER_NAME}'
# (legacy; the shim PPD below is what the CUPS queues use)
# ensure 245igdirf.ocm config is resolvable alongside the filter (runs every invocation)
# The PPD's *OCM_resourceDir points at the legacy /usr/lib/cups/filter/KonicaMinolta
# tree, so point the whole tree at the relocated driver (keeps Colorworlds, Halftones,
# Profiles, Filters and the OCM config resolvable under CUPS/PAPPL).
OCM_DST=/usr/lib/cups/filter/KonicaMinolta/245igdi
if [ -d ${DRIVER_HOME} ]; then
  mkdir -p "\$(dirname "\$OCM_DST")"
  rm -rf "\$OCM_DST"
  ln -sf ${DRIVER_HOME} "\$OCM_DST"
fi
# ensure CUPS queues exist (guarded; lpadmin -P is unsupported on CUPS 3.0)
SHIM_PPD='${MEDIA_TEST_DIR}/${PRINTER_NAME}-driverless.ppd'
DUPLEX_QUEUE='${DUPLEX_QUEUE}'
DUPLEX_PPD='${PAPPL_PPD_DIR}/KonicaMinolta-206-fullbleed.ppd'
USB_URI='usb://KONICA%20MINOLTA/206?serial=${SERIAL}&interface=1'
if command -v lpadmin >/dev/null 2>&1 && command -v lpstat >/dev/null 2>&1; then
  # primary: shim-PPD IPP queue so GUI apps see every paper size.
  # Re-attach the shim PPD when we have it; fall back to PPD-less.
  if [ -f "\$SHIM_PPD" ]; then
    lpadmin -p ${PRINTER_NAME} -v "\$IPP" -P "\$SHIM_PPD" -E 2>/dev/null || \\
      lpadmin -p ${PRINTER_NAME} -v "\$IPP" -E 2>/dev/null || true
  else
    lpadmin -p ${PRINTER_NAME} -v "\$IPP" -E 2>/dev/null || true
  fi
  # secondary/compat queue: same shim PPD (it already carries all media
  # sizes, real margins and Duplex). Re-point it if the PPD changed.
  if [ -f "\$SHIM_PPD" ]; then
    lpadmin -p ${PRINTER_NAME}-ppd -v "\$IPP" -P "\$SHIM_PPD" -E 2>/dev/null || true
    lpadmin -p ${PRINTER_NAME}-ppd -o sides-default=${DEFAULT_SIDES} 2>/dev/null || true
    lpadmin -p ${PRINTER_NAME}-ppd -o media-default=${DEFAULT_MEDIA} 2>/dev/null || true
    lpadmin -p ${PRINTER_NAME}-ppd -o PageSize-default=A4 2>/dev/null || true
  fi
  # restore A4 + simplex defaults on the primary queue
  lpadmin -p ${PRINTER_NAME} -o sides-default=${DEFAULT_SIDES} 2>/dev/null || true
  lpadmin -p ${PRINTER_NAME} -o media-default=${DEFAULT_MEDIA} 2>/dev/null || true
  lpadmin -p ${PRINTER_NAME} -o PageSize-default=A4 2>/dev/null || true

  # classic USB queue: the one that does duplex correctly (see create_queues)
  if [ -f "\$DUPLEX_PPD" ]; then
    lpadmin -p ${DUPLEX_QUEUE} -v "\$USB_URI" -P "\$DUPLEX_PPD" -E 2>/dev/null || true
    lpadmin -p ${DUPLEX_QUEUE} -o sides-default=${DEFAULT_SIDES} 2>/dev/null || true
    lpadmin -p ${DUPLEX_QUEUE} -o media-default=${DEFAULT_MEDIA} 2>/dev/null || true
    lpadmin -p ${DUPLEX_QUEUE} -o PageSize-default=A4 2>/dev/null || true
    lpadmin -d ${DUPLEX_QUEUE} 2>/dev/null || true
  else
    lpadmin -d ${PRINTER_NAME} 2>/dev/null || true
  fi
fi
# Wine-Adobe PS routing guard: self-heal a missing rule file only.
# (File present but chain still wrong means upstream MIME behavior changed;
# leave that for a human.)
if command -v check-wineps-route.sh >/dev/null 2>&1; then
  if [ ! -f /etc/cups/wineps.convs ]; then
    printf '%s\n' 'application/vnd.adobe-reader-postscript application/postscript 0 -' > /etc/cups/wineps.convs 2>/dev/null || true
    chmod 0644 /etc/cups/wineps.convs 2>/dev/null || true
  fi
  check-wineps-route.sh >/dev/null 2>&1 || echo "WARN: Wine-Adobe PS routing check failed; run check-wineps-route.sh" >&2 || true
fi
for i in \$(seq 1 30); do
  if legacy-printer-app printers 2>/dev/null | awk '{print \$1}' | grep -qx '${PRINTER_NAME}'; then
    exit 0
  fi
  sleep 1
done
legacy-printer-app delete -d ${PRINTER_NAME} 2>/dev/null
legacy-printer-app add -d ${PRINTER_NAME} -v "\$URI" -m "\$DRIVER" 2>&1
if legacy-printer-app printers 2>/dev/null | awk '{print \$1}' | grep -qx '${PRINTER_NAME}'; then
  # Fix PPD ownership — legacy-printer-app may create it as _chrony or root;
  # CUPS filters need it readable by lp.
  chown lp:lp /etc/cups/ppd/${PRINTER_NAME}.ppd 2>/dev/null || true
  if [ -f "${MEDIA_TEST_DIR}/set-media-default.test" ]; then
    ipptool -tv "http://localhost:${SERVER_PORT}/ipp/print/${PRINTER_NAME}" \
      "${MEDIA_TEST_DIR}/set-media-default.test" >/dev/null 2>&1
  fi
  exit 0
fi
exit 1
EOF
    chmod 755 "$ENSURE_BIN"
    install -m 644 "$BK/source/konica-debian13-setup/scripts/set-media-default.test" \
        "$MEDIA_TEST_DIR/set-media-default.test"
}

# ---------------------------------------------------------------------------
# 8. Konica USB presence watcher (udev + boot check + cron guard)
# Hardened 2026-10-08: MARKER reason, settle, foreign-pause guard, logging.
# See INVESTIGATION-2026-10-08-konica206uri-disable.md.
# Works on systemd AND non-systemd (Puppy) hosts.
# ---------------------------------------------------------------------------
install_usb_queue_watch() {
    log "Installing Konica USB queue watcher..."

    install -d /usr/local/bin /etc/udev/rules.d

    install -m 755 "$REPO_DIR/konica-cups-watch.sh" /usr/local/bin/konica-cups-watch.sh
    install -m 644 "$REPO_DIR/99-konica206uri-cups.rules" /etc/udev/rules.d/99-konica206uri-cups.rules

    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules || warn "could not reload udev rules"
    fi

    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        install -d /etc/systemd/system
        install -m 644 "$REPO_DIR/konica-cups-watch.service" /etc/systemd/system/konica-cups-watch.service
        systemctl daemon-reload || warn "could not reload systemd manager"
        # The queues are created before this function is called. The boot check
        # therefore reconciles the actual queue state with USB presence.
        systemctl enable --now konica-cups-watch.service \
            || warn "could not enable/start konica-cups-watch.service"
    else
        # Puppy / sysvinit: boot-time reconcile via /root/Startup + cron guard.
        if [ -d /root/Startup ]; then
            install -m 755 "$REPO_DIR/konica-cups-watch-boot.sh" /root/Startup/konica-cups-watch-boot.sh
        fi
    fi

    # Cron self-heal every 5 min (reconciles against real USB state; lost or
    # reordered udev events recover automatically). Idempotent.
    if command -v crontab >/dev/null 2>&1; then
        tmpcron="$(mktemp)"
        crontab -l 2>/dev/null > "$tmpcron" || true
        if ! grep -q "konica-cups-watch.sh check" "$tmpcron"; then
            echo "*/5 * * * * /usr/local/bin/konica-cups-watch.sh check" >> "$tmpcron"
            crontab "$tmpcron" || warn "could not install cron guard"
        fi
        rm -f "$tmpcron"
    fi

    /usr/local/bin/konica-cups-watch.sh check >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 8. systemd unit (drop-in) + start the app
# ---------------------------------------------------------------------------
install_systemd() {
    local unit=/etc/systemd/system/legacy-printer-app.service.d/override.conf
    if [ ! -d /run/systemd/system ]; then
        warn "systemd not detected; starting the app manually instead."
        nohup legacy-printer-app server -o log-level=info \
            -o backend-directory="$BACKEND_DIR" \
            -o server-port="$SERVER_PORT" \
            >/var/log/legacy-printer-app.log 2>&1 &
        return 0
    fi
    log "Installing systemd drop-in..."
    install -d "$(dirname "$unit")"
    cat > "$unit" <<EOF
[Unit]
After=avahi-daemon.service
Wants=avahi-daemon.service

[Service]
Environment=PPD_PATHS=${PAPPL_PPD_DIR}:/usr/share/cups/model:/usr/lib/cups/driver
ExecStart=
ExecStart=legacy-printer-app server -o log-level=debug -o backend-directory=${BACKEND_DIR} -o server-port=${SERVER_PORT}
ExecStartPost=${ENSURE_BIN}
EOF
    # PAPPL registers itself with Avahi (mDNS/DNS-SD) at startup and ABORTS if
    # Avahi is not running ("Unable to register system, is the Avahi daemon
    # running?" -> exit 1). On a fresh/minimal install avahi-daemon is often
    # installed but not enabled, which makes the Printer Application fail to
    # start with no hint about the real cause.
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1; then
        log "Enabling avahi-daemon.service (required by the Printer Application)..."
        systemctl enable --now avahi-daemon.service || \
            warn "could not start avahi-daemon; the Printer Application will not start"
    fi
    systemctl daemon-reload
    systemctl enable --now legacy-printer-app.service
}

wait_for_app() {
    log "Waiting for the Printer Application..."
    # Wait for the SERVER to be ready, not for the queue: the queue is created
    # by create_queues() below, so requiring it here deadlocks on a fresh
    # machine (wait always times out and queue creation is skipped).
    local i
    for i in $(seq 1 30); do
        if legacy-printer-app status 2>/dev/null | grep -q '^Running'; then
            log "Printer Application is up."
            return 0
        fi
        sleep 1
    done
    warn "Printer Application did not report 'Running' within 30s."
    return 1
}

# ---------------------------------------------------------------------------
# Fedora/RHEL: SELinux (enforcing) can block custom binaries from /usr/local
# ---------------------------------------------------------------------------
fix_contexts() {
    # Capability-based (not distro-based): no-op wherever SELinux is absent.
    command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled || return 0
    command -v restorecon >/dev/null 2>&1 || {
        warn "SELinux enabled but restorecon missing; install policycoreutils"
        return 0
    }
    # Files copied/extracted from temp dirs can carry stale contexts
    # (e.g. user_tmp_t), which confining policies deny to cupsd.
    if restorecon -R /usr/local/lib/konica /usr/local/libexec/konica-backend \
                   /usr/local/share/konica206uri 2>/dev/null; then
        log "SELinux contexts normalized under /usr/local"
    fi
    warn "If printing still fails with AVC denials (ausearch -m avc | tail):"
    warn "  sudo ausearch -m avc | audit2allow -M konica && sudo semodule -i konica.pp"
}

# ---------------------------------------------------------------------------
# 9a. Wine-Adobe PostScript MIME fix
#
# Wine/Acrobat output containing an embedded Adobe block is classified by
# CUPS as application/vnd.adobe-reader-postscript, which has no direct
# to-PDF rule, so CUPS forces it through
# pstops -> gstoraster -> rastertopwg -> pwgtopdf and the job dies with
# "Ghostscript stopped status 255 / ioerror (-12) on closing pdfwrite".
# Retyping it to plain application/postscript restores the working gstopdf
# path (same chain plain-PS Job 22 and native-PDF jobs use). Verified on
# paper (Jobs 23/24); native-PDF jobs are unaffected. Classic-queue Wine jobs
# take one extra PDF roundtrip (dry-run only, not yet paper-confirmed).
# ---------------------------------------------------------------------------
install_wineps_convs() {
    local convs=/etc/cups/wineps.convs
    log "Installing Wine-Adobe PS MIME rule ($convs)..."
    printf '%s\n' 'application/vnd.adobe-reader-postscript application/postscript 0 -' > "$convs"
    chmod 0644 "$convs"
    cupsd -t || warn "cupsd -t reported problems; continuing"
    restart_cups || true
}

restart_cups() {  # robust across systemd and sysvinit (e.g. Puppy)
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl restart cups 2>/dev/null && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service cups restart 2>/dev/null && return 0
    fi
    if [ -x /etc/init.d/cups ]; then
        /etc/init.d/cups restart 2>/dev/null && return 0
    fi
    warn "could not restart CUPS; restart it manually"
    return 1
}

# ---------------------------------------------------------------------------
# 9b. Wine-Adobe PS routing guard + upgrade hooks
#
# The /etc/cups/wineps.convs retype rule (see install_wineps_convs) is
# load-bearing: a cups-filters update could rename the MIME type, change
# detection in cupsfilters.types, or change how /etc/cups/*.convs loads,
# and the old gstoraster failure would return silently. The guard verifies
# the resolved chain read-only; the hooks below and the ensure script run
# it automatically after relevant changes.
# ---------------------------------------------------------------------------
install_wineps_guard() {
    log "Installing Wine-Adobe PS routing guard..."
    install -d /usr/local/share/konica-retrofit /usr/local/sbin
    install -m 644 "$REPO_DIR/tests/min-ar.ps" /usr/local/share/konica-retrofit/min-ar.ps
    install -m 755 "$REPO_DIR/check-wineps-route.sh" /usr/local/sbin/check-wineps-route.sh
    # Debian/Ubuntu: run the (fast, read-only) guard after dpkg operations.
    # Capability-gated on the apt config dir so non-apt hosts skip it.
    if [ -d /etc/apt/apt.conf.d ]; then
        cat > /etc/apt/apt.conf.d/99konica-wineps-guard <<'EOF'
# Konica retrofit: verify the Wine-Adobe PS routing after package changes.
# Read-only check; always exits 0 so it never blocks apt.
DPkg::Post-Invoke { "[ -x /usr/local/sbin/check-wineps-route.sh ] && /usr/local/sbin/check-wineps-route.sh >/dev/null 2>&1 || true"; };
EOF
        chmod 644 /etc/apt/apt.conf.d/99konica-wineps-guard
    fi
    # Arch: pacman hook on the printing stack. Written only where pacman
    # hooks are supported.
    if [ -d /etc/pacman.d/hooks ]; then
        cat > /etc/pacman.d/hooks/99-konica-wineps-guard.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = cups
Target = cups-filters
Target = ghostscript

[Action]
Description = Verify Konica Wine-Adobe PS routing
When = PostTransaction
Exec = /bin/sh -c '/usr/local/sbin/check-wineps-route.sh >/dev/null 2>&1 || true'
EOF
        chmod 644 /etc/pacman.d/hooks/99-konica-wineps-guard.hook
    fi
    # Fedora/openSUSE: no clean per-package hook available; the ensure-script
    # self-heal below plus manual runs cover those hosts.
}

# ---------------------------------------------------------------------------
# 9. Create the PAPPL queue + CUPS passthrough queue
# ---------------------------------------------------------------------------
create_queues() {
    log "Creating the PAPPL queue ($PRINTER_NAME)..."

    # Resolve the driver name against what this PAPPL build actually
    # advertises. The generated name carries build-dependent affixes (e.g.
    # "-user-added", "-en"), so match on the stable middle token instead of
    # hardcoding a name that silently rots across pappl-retrofit versions.
    #
    # NOTE: `legacy-printer-app drivers` LISTS user-added PPDs with an extra
    # "-user-added" token inserted before the "-en" language suffix
    # (e.g. "...--real-margin-retrofit-user-added-en"), but
    # `legacy-printer-app add -m` only ACCEPTS the plain name
    # ("...--real-margin-retrofit-en") and rejects the suffixed one with
    # "Driver '...' cannot be used with this printer." Strip just the
    # "-user-added" token and keep the language suffix.
    local resolved
    resolved="$(legacy-printer-app drivers 2>/dev/null \
        | awk -v m="$DRIVER_MATCH" '$1 ~ m {print $1}' | head -1)"
    if [ -n "$resolved" ]; then
        DRIVER_NAME="${resolved/-user-added/}"
        log "Resolved driver: '${resolved}' -> add with '${DRIVER_NAME}'"
    fi

    legacy-printer-app delete -d "$PRINTER_NAME" 2>/dev/null || true
    legacy-printer-app add -d "$PRINTER_NAME" \
        -v "cups:usb://KONICA%20MINOLTA/206?serial=${SERIAL}&interface=1" \
        -m "$DRIVER_NAME" || {
        warn "driver '$DRIVER_NAME' unknown to this build; available drivers:"
        legacy-printer-app drivers 2>/dev/null | grep -i konica
        warn "set DRIVER_MATCH (currently '$DRIVER_MATCH') to the token you want."
        return 1
    }

    # Set A4 as the PAPPL media default (ipptool is optional)
    if command -v ipptool >/dev/null 2>&1; then
        ipptool -tv "$IPP_ENDPOINT" "$MEDIA_TEST_DIR/set-media-default.test" >/dev/null 2>&1 || true
    fi

    if command -v lpadmin >/dev/null 2>&1; then
        log "Creating the CUPS passthrough queue for GUI apps..."
        # Preferred: generate a driverless shim PPD from the Printer
        # Application so the queue advertises ALL media sizes to GUI apps
        # (LibreOffice/WPS read the queue's PPD; a PPD-less queue shows no
        # sizes at all). Fall back to a PPD-less IPP queue when the driverless
        # tool is unavailable -- that is exactly the model CUPS 3.0 uses.
        DRIVERLESS_PPD="$MEDIA_TEST_DIR/${PRINTER_NAME}-driverless.ppd"
        DRIVERLESS_TOOL=""
        for t in driverless /usr/lib/cups/driver/driverless \
                 /usr/libexec/cups/driver/driverless; do
            if command -v "$t" >/dev/null 2>&1; then
                DRIVERLESS_TOOL="$t"
                break
            fi
        done

        if [ -n "$DRIVERLESS_TOOL" ]; then
            log "Generating driverless shim PPD from the Printer Application..."
            if "$DRIVERLESS_TOOL" "ipp://localhost:${SERVER_PORT}/ipp/print/$PRINTER_NAME" \
                    > "$DRIVERLESS_PPD.raw" 2>/dev/null && \
               grep -q '^\*PageSize' "$DRIVERLESS_PPD.raw" 2>/dev/null; then
                sanitize_shim_ppd "$DRIVERLESS_PPD.raw" "$DRIVERLESS_PPD"
                log "Shim PPD: $(grep -c '^\*PageSize ' "$DRIVERLESS_PPD") paper sizes, default $(sed -n 's/^\*DefaultPageSize:[[:space:]]*//p' "$DRIVERLESS_PPD")"
                log "Attaching driverless shim PPD (all media sizes) to $PRINTER_NAME"
                lpadmin -p "$PRINTER_NAME" \
                    -v "ipp://localhost:${SERVER_PORT}/ipp/print/$PRINTER_NAME" \
                    -P "$DRIVERLESS_PPD" -E || {
                    warn "lpadmin -P failed; falling back to PPD-less queue"
                    lpadmin -p "$PRINTER_NAME" \
                        -v "ipp://localhost:${SERVER_PORT}/ipp/print/$PRINTER_NAME" -E
                }
            else
                warn "driverless PPD generation failed; using PPD-less queue"
                lpadmin -p "$PRINTER_NAME" \
                    -v "ipp://localhost:${SERVER_PORT}/ipp/print/$PRINTER_NAME" -E
            fi
        else
            warn "driverless tool not found; using PPD-less queue"
            lpadmin -p "$PRINTER_NAME" \
                -v "ipp://localhost:${SERVER_PORT}/ipp/print/$PRINTER_NAME" -E
        fi

        # Defaults: A4 + one-sided (simplex). Duplex remains selectable via
        # -o sides=two-sided-long-edge / two-sided-short-edge.
        set_queue_defaults "$PRINTER_NAME"

        # ------------------------------------------------------------------
        # Classic USB queue -- THIS is the queue that does duplex correctly.
        #
        # Duplex on the Printer Application queue (konica206uri) produces a
        # ghost: libpappl always reports a 4pt/12pt-inset *ImageableArea
        # (it ignores the PPD's value), while 245igdirf declares the full
        # sheet in PJL (PAPERWIDTH/PAPERLENGTH). The printer then lays the
        # inset raster onto a full-size page and the never-initialised edge
        # strip renders as leftover data from the previous page. Verified
        # reproducible on both queues; not fixable via PPD/queue options
        # (tested cupsBackSide Rotated/Normal, resolution, IMAGELEN framing).
        #
        # The classic queue honours the PPD's *ImageableArea, so with the
        # vendor's full-page value ("0 0 595 842") the raster matches the
        # declared sheet exactly and duplex comes out clean.
        # ------------------------------------------------------------------
        local usb_uri="usb://KONICA%20MINOLTA/206?serial=${SERIAL}&interface=1"
        local duplex_ppd="$PAPPL_PPD_DIR/KonicaMinolta-206-fullbleed.ppd"
        if [ -f "$duplex_ppd" ]; then
            # Simplex is the default; duplex stays selectable.
            sed -i -E 's/^\*DefaultDuplexer:[[:space:]]*false/*DefaultDuplexer: true/;
                       s/^\*DefaultDuplex:[[:space:]]*.*/*DefaultDuplex: None/' "$duplex_ppd"
            log "Creating the classic USB queue ($DUPLEX_QUEUE) for duplex..."
            lpadmin -p "$DUPLEX_QUEUE" -v "$usb_uri" -E 2>/dev/null || true
            lpadmin -p "$DUPLEX_QUEUE" -P "$duplex_ppd" -E 2>/dev/null ||
                warn "could not attach the duplex PPD to $DUPLEX_QUEUE"
            set_queue_defaults "$DUPLEX_QUEUE"
            # This queue is the one that handles simplex AND duplex, so it
            # becomes the default. konica206uri stays as the CUPS-3.0-proof
            # queue (simplex-only in practice).
            lpadmin -d "$DUPLEX_QUEUE"
            lpoptions -d "$DUPLEX_QUEUE" 2>/dev/null || true
        else
            warn "duplex PPD not found ($duplex_ppd); $DUPLEX_QUEUE not created"
            lpadmin -d "$PRINTER_NAME"
            lpoptions -d "$PRINTER_NAME" 2>/dev/null || true
        fi

        # Optional classic-PPD queue kept under the historical name for
        # compatibility (skipped silently on CUPS 3.0 where -P is
        # unsupported). It uses the SAME driverless shim PPD: that already
        # exposes all media sizes plus Duplex, so this queue is only a
        # second name for GUI apps that insist on their own PPD.
        if [ -f "$DRIVERLESS_PPD" ]; then
            PPD_QUEUE_FILE="$DRIVERLESS_PPD"
            if ! lpstat -p "${PRINTER_NAME}-ppd" >/dev/null 2>&1; then
                lpadmin -p "${PRINTER_NAME}-ppd" \
                    -v "ipp://localhost:${SERVER_PORT}/ipp/print/$PRINTER_NAME" \
                    -P "$PPD_QUEUE_FILE" -E 2>/dev/null || \
                    warn "could not create ${PRINTER_NAME}-ppd queue (CUPS 3.0?)"
            else
                # keep the existing queue pointed at the current shim PPD
                lpadmin -p "${PRINTER_NAME}-ppd" -P "$PPD_QUEUE_FILE" -E 2>/dev/null || true
            fi
            set_queue_defaults "${PRINTER_NAME}-ppd"
        fi
        restart_cups || true
    else
        warn "lpadmin not found (CUPS 3.0?). Skipping CUPS queue."
        warn "Point GUI apps directly at: $IPP_ENDPOINT"
        warn "Duplex needs CUPS 2.x + the classic usb:// queue on this printer."
    fi
}

# ---------------------------------------------------------------------------
# 9b. Shim PPD post-processing
#
# `driverless` mirrors whatever the Printer Application advertises. This
# retrofit tree also ships a full-bleed (borderless) PPD, so drop any
# borderless entries the shim may have picked up, and pin the defaults to
# A4 / one-sided. Also relaxes the duplex UIConstraints so a driverless
# shim (which advertises every size, including envelopes) doesn't get its
# duplex choices silently stripped by CUPS' constraint engine.
# ---------------------------------------------------------------------------
sanitize_shim_ppd() {  # sanitize_shim_ppd <in> <out>
    local in="$1" out="$2"
    # Drop only *PageSize/*PageRegion/*ImageableArea/*PaperDimension lines
    # whose SIZE NAME contains a borderless token, plus any UIConstraints that
    # would then dangle. Everything else passes through untouched.
    sed -E "/^\*(PageSize|PageRegion|ImageableArea|PaperDimension|DefaultImageableArea|DefaultPageSize|DefaultPageRegion)\b.*${BORDERLESS_RE}/d;
            /UIConstraints:.*${BORDERLESS_RE}/d" "$in" > "$out"
    # Pin defaults: first PageSize keyword after DefaultPageSize is the default.
    local def
    def="$(sed -n 's/^\*DefaultPageSize:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$out" | head -1)"
    [ -n "$def" ] || def="A4"
    if ! grep -q "^\*PageSize ${def}/" "$out"; then def="A4"; fi
    sed -i -E "s/^\\*DefaultPageSize:.*/*DefaultPageSize: ${def}/" "$out"
    # Advertise the duplexer as installed and default to one-sided.
    sed -i -E 's/^\*DefaultDuplexer:.*/*DefaultDuplexer: true/' "$out"
    sed -i -E 's/^\*DefaultDuplex:.*/*DefaultDuplex: None/' "$out"
    rm -f "$in"
}

set_queue_defaults() {  # set_queue_defaults <queue>
    local q="$1"
    lpadmin -p "$q" -o sides-default=one-sided 2>/dev/null || true
    lpadmin -p "$q" -o media-default="$DEFAULT_MEDIA" 2>/dev/null || true
    lpadmin -p "$q" -o PageSize-default=A4 2>/dev/null || true
    lpadmin -p "$q" -o print-color-mode=monochrome 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 10. Verify
# ---------------------------------------------------------------------------
verify() {
    echo
    echo "=== Verification ==="
    echo "--- Printer Application ---"
    legacy-printer-app printers 2>/dev/null
    echo "--- CUPS ---"
    if command -v lpstat >/dev/null 2>&1; then
        lpstat -p "$PRINTER_NAME" 2>/dev/null
        lpstat -d
    fi
    echo "--- Backend discovery (should list the printer) ---"
    if command -v legacy-printer-app >/dev/null 2>&1; then
        sudo env DEVICE_URI="" "$BACKEND_DIR/usb" 2>/dev/null || true
    fi
    echo
    echo "Test print (A4, simplex -- the default):"
    echo "  lp -d $DUPLEX_QUEUE <file.pdf>"
    echo
    echo "Test print (A4, duplex long edge -- use the CLASSIC queue, see note below):"
    echo "  lp -d $DUPLEX_QUEUE -o sides=two-sided-long-edge <file.pdf>"
    echo
    echo "NOTE: both queues now render simplex AND duplex correctly."
    echo "      The critical invariant is that the driver's *ImageableArea equals"
    echo "      *PaperDimension for every size -- 245igdirf declares the full sheet"
    echo "      in PJL, so any inset *ImageableArea leaves the raster shorter than"
    echo "      the canvas and the page gains a 'ghost' band across the bottom."
    echo "      install_ppds() enforces this; if you ever edit a retrofit PPD by"
    echo "      hand, re-run this installer."
    echo
    echo "      '$DUPLEX_QUEUE' uses the classic usb:// backend and breaks under"
    echo "      CUPS 3.0; '$PRINTER_NAME' is the CUPS-3.0-proof path. Prefer the"
    echo "      latter when it is available."
}

# ---------------------------------------------------------------------------
main() {
    install_pappl
    install_driver
    build_backend
    install_ppds
    install_ensure_script
    install_systemd
    if wait_for_app; then
        create_queues || warn "queue creation incomplete (see messages above)"
    else
        warn "Printer Application did not come up; check journalctl -u legacy-printer-app"
    fi
    install_wineps_convs
    install_wineps_guard
    install_usb_queue_watch
    fix_contexts
    verify
}
main "$@"
