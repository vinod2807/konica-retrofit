#!/bin/bash
URI='cups:usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1'
DRIVER='konica-minolta--206--full-bleed-retrofit-en'
for i in $(seq 1 30); do
  if legacy-printer-app printers 2>/dev/null | grep -q '^konica206uri$'; then
    exit 0
  fi
  sleep 1
done
legacy-printer-app delete -d konica206uri 2>/dev/null
legacy-printer-app add -d konica206uri -v "$URI" -m "$DRIVER" 2>&1
if legacy-printer-app printers 2>/dev/null | grep -q '^konica206uri$'; then
  ipptool -tv "http://localhost:8000/ipp/print/konica206uri" /tmp/set-media-default.test >/dev/null 2>&1
  exit 0
fi
exit 1
