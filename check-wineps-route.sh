#!/bin/sh
# check-wineps-route.sh -- read-only regression guard for the Wine-Adobe PS
# routing fix (see docs-Wine-Adobe-PS-Fix.md).
#
# Verifies that:
#   1. /etc/cups/wineps.convs retypes
#      application/vnd.adobe-reader-postscript -> application/postscript, and
#   2. cupsfilter resolves the fixture to the gstopdf path (no gstoraster).
#
# First output word is OK, SKIP: <reason>, or FAIL: <reason>.
# Exit status: 0 = pass or skip, 1 = FAIL, 2 = could not run the check.
# Never edits config, restarts CUPS, or prints. No systemd needed.
# Intentionally POSIX sh (no set -e): exit codes are the interface.
#
# Env override for testing: KONICA_PPD (default
# /etc/cups/ppd/konica206uri.ppd).

PPD="${KONICA_PPD:-/etc/cups/ppd/konica206uri.ppd}"
CONVS=/etc/cups/wineps.convs
FIXTURE=/usr/local/share/konica-retrofit/min-ar.ps
if [ ! -f "$FIXTURE" ]; then
    D=$(dirname "$0" 2>/dev/null) || D=.
    FIXTURE="$D/tests/min-ar.ps"
fi

say() { # say <WORD> <message...>
    w="$1"; shift
    echo "$w: $*"
    if [ "$w" = FAIL ]; then
        echo "$w: $*" >&2
    fi
    if command -v logger >/dev/null 2>&1; then
        logger -t konica-wineps "$w: $*" 2>/dev/null || true
    fi
}

command -v cupsfilter >/dev/null 2>&1 || { say SKIP "cupsfilter not installed"; exit 0; }
command -v cupsd >/dev/null 2>&1 || { say SKIP "cupsd not installed"; exit 0; }
[ -f "$PPD" ] || { say SKIP "queue PPD $PPD missing (queue not set up)"; exit 0; }
[ -f "$FIXTURE" ] || { say FAIL "fixture $FIXTURE missing"; exit 2; }

if ! grep -q '^application/vnd[.]adobe-reader-postscript[[:space:]][[:space:]]*application/postscript[[:space:]]' "$CONVS" 2>/dev/null; then
    say FAIL "rule missing in $CONVS; recreate with: printf '%s\n' 'application/vnd.adobe-reader-postscript application/postscript 0 -' > $CONVS && chmod 0644 $CONVS (or re-run install-konica-anylinux.sh)"
    exit 1
fi

chain=$(cupsfilter --list-filters -p "$PPD" -m application/pdf "$FIXTURE" 2>/dev/null) || { say FAIL "cupsfilter failed"; exit 2; }
case "$chain" in
    *gstoraster*|*rastertopwg*|*pwgtopdf*)
        say FAIL "wrong chain (gstoraster path): $chain"
        exit 1
        ;;
esac
case "$chain" in
    *gstopdf*)
        say OK "adobe-reader-postscript routes via gstopdf: $chain"
        exit 0
        ;;
    *)
        say FAIL "unexpected chain (no gstopdf): $chain"
        exit 1
        ;;
esac
