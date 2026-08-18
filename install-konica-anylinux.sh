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

PRINTER_NAME="konica206uri"
DRIVER_NAME="${DRIVER_NAME:-konica-minolta--206--full-bleed-retrofit-en}"
PAPPL_PPD_DIR="/var/lib/legacy-printer-app/ppd"
BACKEND_DIR="/usr/local/libexec/konica-backend"
DRIVER_HOME="/usr/local/lib/konica/KonicaMinolta/245igdi"
ENSURE_BIN="/usr/local/bin/ensure-konica206uri.sh"
MEDIA_TEST_DIR="/usr/local/share/konica206uri"
IPP_ENDPOINT="http://localhost:8000/ipp/print/${PRINTER_NAME}"

KONICA_SERIAL="${KONICA_SERIAL:-}"
DO_SOURCE_BUILD=1

log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

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
        debian|ubuntu)          DISTRO=debian;;
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
        debian)  apt-get update -qq;  apt-get install -y "$@" ;;
        fedora)  dnf install -y "$@" ;;
        arch)    pacman -S --noconfirm --needed "$@" ;;
        opensuse) zypper --non-interactive install "$@" ;;
        *)       warn "cannot auto-install on '$DISTRO'; install manually: $*"; return 1;;
    esac
}

# ---------------------------------------------------------------------------
# 4. Install legacy-printer-app / pappl-retrofit
# ---------------------------------------------------------------------------
install_pappl() {
    if command -v legacy-printer-app >/dev/null 2>&1; then
        log "legacy-printer-app already installed: $(command -v legacy-printer-app)"
        return 0
    fi
    log "Installing legacy-printer-app (pappl-retrofit)..."
    case "$DISTRO" in
        debian)
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
        debian)  deps="git cmake make gcc g++ pkg-config libcups2-dev libcupsfilters-dev libppd-dev libpappl1-dev libusb-1.0-0-dev libcupsimage2-dev";;
        fedora)  deps="git cmake make gcc gcc-c++ pkgconfig libcups-devel libcupsfilters-devel libppd-devel pappl-devel libusb1-devel";;
        arch)    deps="git cmake make gcc pkg-config cups libcupsfilters libppd pappl libusb";;
        opensuse)deps="git cmake make gcc gcc-c++ pkg-config libcups2-devel libcupsfilters-devel libppd-devel pappl-devel libusb-1_0-devel";;
        *)       warn "unknown distro for build deps; please install them manually";;
    esac
    install_pkgs $deps || warn "build dependency install incomplete"

    local src=/tmp/pappl-retrofit-src
    rm -rf "$src"
    git clone --depth 1 https://github.com/OpenPrinting/pappl-retrofit "$src" \
        || die "source build: clone failed"
    cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release \
        || die "source build: cmake configure failed"
    cmake --build "$src/build" -j"$(nproc)" || die "source build: compile failed"
    (cd "$src/build" && make install) || die "source build: install failed"
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
        install -d "$libdir"

        if [ "$DISTRO" = "debian" ] && [ -f "$cups_deb" ] && [ -f "$cupsimage_deb" ]; then
            # Debian/Ubuntu: extract from the archived .debs (these preserve
            # the exact pinned version this repo was built/tested against).
            command -v dpkg-deb >/dev/null 2>&1 || install_pkgs dpkg
            local tmp; tmp="$(mktemp -d)"
            dpkg-deb -x "$cups_deb" "$tmp"
            dpkg-deb -x "$cupsimage_deb" "$tmp"
            local libarch
            libarch="$(find "$tmp/usr/lib" -maxdepth 1 -type d -name '*-linux-gnu*' | head -n1)"
            [ -n "$libarch" ] || libarch="$tmp/usr/lib/x86_64-linux-gnu"
            cp -a "$libarch"/libcups.so.2* "$libdir/" 2>/dev/null || die "libcups.so.2 not found in $cups_deb"
            cp -a "$libarch"/libcupsimage.so.2* "$libdir/" 2>/dev/null || die "libcupsimage.so.2 not found in $cupsimage_deb"
            rm -rf "$tmp"
        else
            # Non-Debian (Arch, Fedora, openSUSE) or no bundled .debs: no
            # archived copy to extract from, so vendor straight from THIS
            # machine's currently-installed libcups (e.g. Arch's own
            # `libcups` package, which at install time is still live and
            # pacman-tracked — see konica-retrofit README Arch addendum).
            # This is a snapshot of "whatever the host has right now", not a
            # pinned version, which is the best available source on distros
            # that don't ship an archived classic-ABI package in this repo.
            local src=""
            for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu /lib /lib64; do
                if [ -f "$d/libcups.so.2" ] && [ -f "$d/libcupsimage.so.2" ]; then
                    src="$d"; break
                fi
            done
            if [ -z "$src" ] && command -v ldconfig >/dev/null 2>&1; then
                src="$(ldconfig -p 2>/dev/null | awk '/libcups\.so\.2 /{print $NF; exit}' | xargs dirname 2>/dev/null)"
            fi
            [ -n "$src" ] || die "libcups.so.2/libcupsimage.so.2 not found anywhere on this system — install the distro's classic libcups package first (e.g. 'pacman -S libcups'), or supply them manually in $libdir"
            cp -a "$src/libcups.so.2"* "$libdir/" || die "failed copying libcups.so.2 from $src"
            cp -a "$src/libcupsimage.so.2"* "$libdir/" || die "failed copying libcupsimage.so.2 from $src"
            log "Vendored from live system libs at $src (not a pinned archive — see README caveat)."
        fi
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
}

install_ensure_script() {
    log "Installing persistence helper ($ENSURE_BIN) with serial $SERIAL..."
    install -d "$(dirname "$ENSURE_BIN")" "$MEDIA_TEST_DIR"
    cat > "$ENSURE_BIN" <<EOF
#!/bin/bash
# ensure-konica206uri.sh (generated by install-konica-anylinux.sh)
URI='cups:usb://KONICA%20MINOLTA/206?serial=${SERIAL}&interface=1'
DRIVER='${DRIVER_NAME}'
for i in \$(seq 1 30); do
  if legacy-printer-app printers 2>/dev/null | grep -q '^konica206uri$'; then
    exit 0
  fi
  sleep 1
done
legacy-printer-app delete -d konica206uri 2>/dev/null
legacy-printer-app add -d konica206uri -v "\$URI" -m "\$DRIVER" 2>&1
if legacy-printer-app printers 2>/dev/null | grep -q '^konica206uri$'; then
  if [ -f "${MEDIA_TEST_DIR}/set-media-default.test" ]; then
    ipptool -tv "http://localhost:8000/ipp/print/konica206uri" \
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
# 8. systemd unit (drop-in) + start the app
# ---------------------------------------------------------------------------
install_systemd() {
    local unit=/etc/systemd/system/legacy-printer-app.service.d/override.conf
    if [ ! -d /run/systemd/system ]; then
        warn "systemd not detected; starting the app manually instead."
        nohup legacy-printer-app server -o log-level=info \
            -o backend-directory="$BACKEND_DIR" \
            >/var/log/legacy-printer-app.log 2>&1 &
        return 0
    fi
    log "Installing systemd drop-in..."
    install -d "$(dirname "$unit")"
    cat > "$unit" <<EOF
[Service]
Environment=PPD_PATHS=${PAPPL_PPD_DIR}:/usr/share/cups/model:/usr/lib/cups/driver
ExecStart=
ExecStart=legacy-printer-app server -o log-level=debug -o backend-directory=${BACKEND_DIR}
ExecStartPost=${ENSURE_BIN}
EOF
    systemctl daemon-reload
    systemctl enable --now legacy-printer-app.service
}

wait_for_app() {
    log "Waiting for the Printer Application..."
    local i
    for i in $(seq 1 30); do
        legacy-printer-app printers 2>/dev/null | grep -q "^$PRINTER_NAME$" && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Fedora/RHEL: SELinux (enforcing) can block custom binaries from /usr/local
# ---------------------------------------------------------------------------
check_selinux() {
    [ "$DISTRO" = "fedora" ] || return 0
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0
    warn "SELinux is Enforcing. The custom backend and vendor filter run from"
    warn "/usr/local and may be denied by the targeted policy (cupsd_t / initrc_t)."
    warn "If the test print below fails or you see AVC denials (ausearch -m avc | tail):"
    warn "  1) temporary permissive:      sudo setenforce 0"
    warn "  2) proper policy module:      sudo ausearch -m avc | audit2allow -M konica && sudo semodule -i konica.pp"
}

# ---------------------------------------------------------------------------
# 9. Create the PAPPL queue + CUPS passthrough queue
# ---------------------------------------------------------------------------
create_queues() {
    log "Creating the PAPPL queue ($PRINTER_NAME)..."
    legacy-printer-app delete -d "$PRINTER_NAME" 2>/dev/null || true
    legacy-printer-app add -d "$PRINTER_NAME" \
        -v "cups:usb://KONICA%20MINOLTA/206?serial=${SERIAL}&interface=1" \
        -m "$DRIVER_NAME" || {
        warn "driver '$DRIVER_NAME' unknown to this build; listing available PPDs:"
        ls "$PAPPL_PPD_DIR"
        warn "edit DRIVER_NAME in this script to the matching driver and re-run."
        return 1
    }

    # Set A4 as the PAPPL media default (ipptool is optional)
    if command -v ipptool >/dev/null 2>&1; then
        ipptool -tv "$IPP_ENDPOINT" "$MEDIA_TEST_DIR/set-media-default.test" >/dev/null 2>&1 || true
    fi

    if command -v lpadmin >/dev/null 2>&1; then
        log "Creating the CUPS passthrough queue for GUI apps..."
        lpadmin -p "$PRINTER_NAME" \
            -v "ipp://localhost:8000/ipp/print/$PRINTER_NAME" \
            -P "$PAPPL_PPD_DIR/konica206-pdf-fullbleed.ppd" -E
        lpadmin -d "$PRINTER_NAME"
        lpoptions -d "$PRINTER_NAME" 2>/dev/null || true
        systemctl restart cups 2>/dev/null || true
    else
        warn "lpadmin not found (CUPS 3.0?). Skipping CUPS queue."
        warn "Point GUI apps directly at: $IPP_ENDPOINT"
    fi
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
    echo "Test print (A4, 2-sided):"
    echo "  lp -d $PRINTER_NAME -o media=iso_a4_210x297mm -o sides=two-sided-long-edge <file.pdf>"
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
    check_selinux
    verify
}
main "$@"
