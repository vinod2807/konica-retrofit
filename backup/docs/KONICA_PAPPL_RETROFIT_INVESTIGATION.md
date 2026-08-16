# Konica Minolta PAPPL Retrofit Investigation

Date: 2026-08-07

## Purpose

This document records the attempt to expose the working Konica Minolta CUPS
driver through OpenPrinting's `pappl-retrofit` Legacy Printer Application.
The goal was to preserve the existing working CUPS queue while testing a
separate PAPPL/IPP queue using the same PPD with its incompatible ICC profile
entries removed.

## Existing Printer Setup

The printer is physically identified as a Konica Minolta model 206:

```text
Printer queue:       KONICA_MINOLTA_206
Device:              USB
Device URI:          usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1
System default:      KONICA_MINOLTA_206
Status before test:  idle and enabled
```

The installed vendor package is:

```text
konica-minolta-245igdi-cups
```

The package supplies PPDs for 205i, 225i, and 245i models, but not a native
206 PPD. The active queue uses the 205i-derived PPD together with the shared
Konica 245igdi filter.

Important driver files:

```text
/etc/cups/ppd/KONICA_MINOLTA_206.ppd
/usr/share/cups/model/KonicaMinolta/245igdi.ppd
/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf
```

The active PPD contains this CUPS filter entry:

```text
*cupsFilter: "application/vnd.cups-raster 0 /usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf"
```

The active PPD has no remaining `cupsICCProfile` entries. Those entries were
previously removed because Ubuntu's `gstoraster` path passed the Konica ICC
profile to Ghostscript 10.06.0, producing:

```text
Unrecoverable error: undefined in .putdeviceprops
gstoraster filter failed
```

Removing the ICC directives was already confirmed to restore normal printing.

## Backup Created

Before installing or changing the retrofit application, a complete backup was
created at:

```text
/home/vinod/konica-printer-backup-20260807-153913
```

The backup contains:

```text
current-cups-konica-setup.tar.gz
package-versions.txt
lpstat-printer.txt
lpstat-device.txt
lpoptions.txt
SHA256SUMS
```

The archive includes:

```text
/etc/cups/
/usr/share/cups/model/KonicaMinolta/245igdi.ppd
/usr/lib/cups/filter/KonicaMinolta/
/usr/lib/cups/backend/usb
```

The archive checksum was verified after rollback:

```text
/home/vinod/konica-printer-backup-20260807-153913/current-cups-konica-setup.tar.gz: OK
```

The backup was created with ownership, ACL, and extended-attribute preservation:

```bash
sudo tar --xattrs --acls -czf \
  /home/vinod/konica-printer-backup-20260807-153913/current-cups-konica-setup.tar.gz \
  /etc/cups \
  /usr/share/cups/model/KonicaMinolta/245igdi.ppd \
  /usr/lib/cups/filter/KonicaMinolta \
  /usr/lib/cups/backend/usb
```

## Package Installation

Ubuntu Resolute provided the package from the `universe` repository:

```text
legacy-printer-app 1.0~b2-0ubuntu8
libpappl-retrofit1 1.0~b2-0ubuntu8
libpappl1t64 1.4.9-0ubuntu2
```

The package was installed with:

```bash
sudo apt-get update
sudo apt-get install -y legacy-printer-app
```

The package installed and enabled:

```text
legacy-printer-app.service
```

The application initially ran on:

```text
http://localhost:8000/
```

Avahi-related messages appeared because Avahi service browsing/registration
was unavailable:

```text
[Device] Unable to create service browser.
Unable to register system, is the Avahi daemon running?
```

These messages did not prevent the local web interface or USB device listing
from working.

## Retrofit PPD Preparation

The active ICC-free PPD was copied into the Legacy Printer Application's
user-PPD directory:

```text
/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-no-icc.ppd
```

The original active PPD was used as the source. It retained the proprietary
filter entry and contained no `cupsICCProfile` lines.

To make it appear as a distinct user-added driver, the following metadata was
temporarily adjusted in a working copy:

```text
*ModelName:       "KONICA MINOLTA 206 (ICC-free retrofit)"
*NickName:        "KONICA MINOLTA 206 (ICC-free retrofit)"
*Product:         "(KONICA MINOLTA 206)"
*ShortNickName:   "KONICA MINOLTA 206"
*1284DeviceID:    "MFG:KONICA MINOLTA;CMD:GDI,XPS;MDL:206;PRINTER"
```

The PPD was then visible in the driver list as:

```text
konica-minolta--206-icc-free-retrofit--user-added-en
```

Before the model metadata was corrected, it appeared as a 205i-derived
user-added driver:

```text
konica-minolta--205-i-icc-free-retrofit--user-added-en
```

The original vendor PPD also had all `ImageableArea` values set to the full
page, for example:

```text
*ImageableArea A4/A4: "0 0 595 842"
```

The working retrofit copy temporarily enabled the vendor PPD's existing
commented hardware-margin hint:

```text
*HWMargins: 18 18 18 18
```

This was an experiment only. It was not applied to the active CUPS PPD.

## Legacy Printer Application Configuration

The Ubuntu package's systemd service did not include the user PPD path in its
environment. A temporary systemd drop-in was therefore created:

```text
/etc/systemd/system/legacy-printer-app.service.d/override.conf
```

Its content was:

```ini
[Service]
Environment=PPD_PATHS=/var/lib/legacy-printer-app/ppd:/usr/share/cups/model:/usr/lib/cups/driver
```

After restarting the service, the custom PPD appeared in the driver list.

The original CUPS queue was never deleted, modified, or disabled. The retrofit
application was intended to use a separate printer name and the same USB
device.

## Attempts to Add the Printer

The retrofit CLI syntax was investigated using:

```bash
legacy-printer-app --help
legacy-printer-app add --help
```

The relevant options were:

```text
-d PRINTER       Specify printer
-m DRIVER-NAME   Specify driver
-v DEVICE-URI    Specify socket: or usb: device
```

Several CLI attempts were made using separate test names. The application
reported different validation errors depending on the PPD metadata and device
URI form. The local web interface was also tested using its `/addprinter`
form, which exposed the USB device as:

```text
usb://KONICA%20MINOLTA/206?serial=A8A6041029423|MFG:KONICA MINOLTA;CMD:GDI,XPS;MDL:206;CLS:PRINTER;CID:KONICA MINOLTA206;
```

The application could discover the device and load the PPD, but it did not
retain a usable configured queue.

## Failure Diagnosis

The decisive error was recorded in the service journal:

```text
[Printer konica206retrofit] Invalid driver left/right margins value -70.
```

This occurred even after enabling:

```text
*HWMargins: 18 18 18 18
```

The likely cause is the vendor PPD's full-page, zero-margin `ImageableArea`
definitions. PAPPL/libpappl-retrofit performs stricter margin and media
validation than the classic CUPS path. The original vendor PPD was accepted by
CUPS because the proprietary filter and PPD were designed for that legacy
pipeline, but PAPPL rejected the geometry while building its IPP printer
attributes.

This was not the original Ghostscript ICC failure. It occurred earlier during
PAPPL driver setup, before a print test could be safely submitted.

Other observed messages included:

```text
Automatic printer driver selection ... with device ID "(null)" failed.
Unable to use that driver.
Driver 'generic--ipp-everywhere-printer--en' cannot be used with this printer.
```

The generic driver error was expected and not relevant to the proprietary
Konica filter. The important blocker was the invalid PPD margin geometry.

## Rollback Performed

The experiment was stopped before printing through the retrofit queue.

The following cleanup was performed:

```bash
sudo systemctl disable --now legacy-printer-app.service
sudo rm -f /etc/systemd/system/legacy-printer-app.service.d/override.conf
sudo rm -f /var/lib/legacy-printer-app/ppd/KonicaMinolta-206-no-icc.ppd
sudo rmdir /etc/systemd/system/legacy-printer-app.service.d
sudo systemctl daemon-reload
```

The `legacy-printer-app` package itself remains installed, but its service is
disabled and inactive. It does not interfere with the ordinary CUPS setup.

Temporary test files and the working PPD copy were removed. The backup was not
removed.

## Post-Rollback Verification

The original CUPS service is active:

```text
cups: active
```

The original queue is unchanged and healthy:

```text
printer KONICA_MINOLTA_206 is idle
enabled
system default destination: KONICA_MINOLTA_206
```

There are no queued jobs for the Konica printer.

The active PPD still contains its proprietary filter:

```text
*cupsFilter: "application/vnd.cups-raster 0 /usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf"
```

The active PPD still contains no `cupsICCProfile` entries.

The retrofit service state after rollback is:

```text
disabled
inactive
```

## Current Final State

The machine is back to the previously working configuration:

```text
Classic CUPS:          active
Konica CUPS queue:     enabled and idle
Konica queue default:  yes
ICC workaround:        retained
Legacy Printer App:    installed, disabled, inactive
Retrofit queue:        not retained
Backup:                verified
```

## Recommended Future Investigation

Do not alter the active PPD first. Work only with a copy and preserve the
backup.

1. Install or enable Avahi if network/service discovery is required:

   ```bash
   systemctl status avahi-daemon
   ```

2. Re-enable the retrofit service only for testing:

   ```bash
   sudo systemctl enable --now legacy-printer-app.service
   ```

3. Reinstall the temporary `PPD_PATHS` drop-in and copy the ICC-free PPD into
   `/var/lib/legacy-printer-app/ppd/`.

4. Resolve the PPD geometry issue in a test copy. The likely work is to replace
   the zero-margin `ImageableArea` values with realistic printable margins for
   each supported media size, not merely to add `HWMargins`.

5. Confirm that the retrofit driver still calls the proprietary filter:

   ```text
   /usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf
   ```

6. Confirm that the generated temporary PPD used by PAPPL has no
   `cupsICCProfile` directives.

7. Add a separate test queue through the web interface at:

   ```text
   http://localhost:8000/addprinter
   ```

8. Test with a one-page, low-risk document only after the queue reports valid
   media and margins.

9. Check the application journal during setup and printing:

   ```bash
   sudo journalctl -u legacy-printer-app.service -f
   ```

10. If PAPPL still rejects the PPD, report the PPD geometry and proprietary
    filter combination upstream to `pappl-retrofit`. The driver is a genuine
    legacy CUPS driver with a binary filter, which is exactly the type of driver
    the Legacy Printer Application is intended to retrofit, but this particular
    vendor PPD has not been validated by PAPPL.

## Important Safety Notes

- Never replace `/etc/cups/ppd/KONICA_MINOLTA_206.ppd` during testing.
- Never delete `KONICA_MINOLTA_206` until a separate retrofit print has been
  confirmed.
- Keep the ICC-free PPD copy separate from the vendor-installed model PPD.
- Do not restore the `cupsICCProfile` lines unless Ghostscript and the profile
  compatibility issue have been independently resolved.
- The model mismatch remains a separate long-term risk: the printer is a 206,
  while the vendor package and active filter are based on the 245igdi family.
- The retrofit attempt did not prove that the proprietary filter is unusable;
  it stopped at PAPPL's PPD margin validation stage.

## Margin-Fix Follow-up Test

The proposed margin-fix test plan was executed on 2026-08-07 using only copied
files. The active CUPS PPD was never edited.

### Test Artifacts

The original copied PPD and the margin-fixed test PPD remain available for
future investigation:

```text
/home/vinod/konica-206-retrofit-original.ppd
/home/vinod/konica-206-retrofit-fix.ppd
/tmp/konica-cupstestppd.log
```

The fixed PPD retained the ICC-free configuration and proprietary filter:

```text
*cupsFilter: "application/vnd.cups-raster 0 /usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf"
```

It contained no `cupsICCProfile` entries.

### PPD Transformation

The test copy enabled the existing hardware margin hint:

```text
*HWMargins: 18 18 18 18
```

All 24 full-bleed `ImageableArea` entries matching the form `"0 0 W H"`
were rewritten to:

```text
"18 18 W-18 H-18"
```

For example, A4 became:

```text
*ImageableArea A4/A4: "18 18 577.00 824.00"
```

The working copy's `ModelName` and `NickName` were also labeled as a 206
margin-fixed retrofit so the driver could be distinguished in PAPPL's driver
list. The vendor's original 205i device ID was otherwise retained for the
shared driver relationship.

The transformation was performed programmatically and the diff showed only
the expected `ImageableArea` changes, the `HWMargins` activation, and the
temporary identifying metadata changes.

### Offline Validation

The command used was:

```bash
cupstestppd -W all /home/vinod/konica-206-retrofit-fix.ppd
```

There were no reported `ImageableArea`, `HWMargins`, or `PaperDimension`
geometry warnings. The command returned exit status `4` because the vendor PPD
has many pre-existing translation warnings and this warning:

```text
DefaultUseHWMargins has no corresponding options.
```

Those warnings were unrelated to the page geometry change.

### PAPPL Setup Result

The fixed PPD was temporarily installed at:

```text
/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-margin-fixed.ppd
```

A temporary systemd drop-in set:

```ini
[Service]
Environment=PPD_PATHS=/var/lib/legacy-printer-app/ppd:/usr/share/cups/model:/usr/lib/cups/driver
```

The driver appeared in the running application as:

```text
konica-minolta--205-i--margin-fixed-retrofit--user-added-en
```

The separate retrofit queue was successfully created:

```text
konica206marginfix
```

Most importantly, the previous error did not recur:

```text
Invalid driver left/right margins value -70
```

The queue reached an idle state during setup. This confirms that rewriting the
`ImageableArea` entries consistently with the 18-point margins resolves the
PAPPL driver-setup margin blocker.

The application still logged:

```text
Unable to create service browser.
Unable to register system, is the Avahi daemon running?
[Printer konica206marginfix] Unable to register printer, is the Avahi daemon running?
```

This is an Avahi discovery/advertising problem, separate from PPD validation.
The local PAPPL queue was nevertheless created and visible to the application.

### Print Attempt

Before printing, the fixed PPD was checked again for the proprietary filter and
absence of ICC directives. A single built-in PAPPL test page was submitted with
a 60-second safety timeout:

```bash
timeout 60s legacy-printer-app submit \
  -d konica206marginfix \
  -n 1 \
  /usr/share/legacy-printer-app/testpage.pdf
```

The command returned:

```text
submit_exit=124
```

No corresponding print-start or filter error appeared in the service journal.
The printer output was therefore treated as **unverified**. No retry was made
against the hardware.

The PAPPL CLI also timed out while querying options/status for the USB-backed
test queue. This suggests a separate issue in the PAPPL command/control path or
USB backend handling, but it does not invalidate the successful PPD margin
validation result.

### Follow-up Rollback

The PAPPL service became stuck in `deactivating` because its configured
`ExecStop` shutdown command timed out. Its server process was terminated, and
all temporary service and queue state was removed:

```bash
sudo systemctl disable --now legacy-printer-app.service
sudo kill -TERM <legacy-printer-app-pid>
sudo kill -KILL <legacy-printer-app-pid>
sudo rm -f /etc/systemd/system/legacy-printer-app.service.d/override.conf
sudo rm -f /var/lib/legacy-printer-app/ppd/KonicaMinolta-206-margin-fixed.ppd
sudo rm -f /var/lib/legacy-printer-app/legacy-printer-app.state
sudo rmdir /etc/systemd/system/legacy-printer-app.service.d
sudo systemctl daemon-reload
```

The final state was verified as:

```text
legacy-printer-app.service: disabled, inactive
KONICA_MINOLTA_206: enabled, idle, system default
Classic CUPS queue jobs: none
Backup checksum: OK
```

The classic CUPS queue remained untouched throughout the follow-up test. The
margin-fixed PPD copy and its validation log were deliberately retained in
`/home/vinod` as future investigation artifacts.

### Updated Conclusion

The proposed margin correction successfully removed the PAPPL `-70` setup
blocker and allowed a separate retrofit queue to be created. It did not yet
establish successful printing because the one-page submission timed out and
there was no confirmed printer output. The next investigation should focus on
the PAPPL USB backend/control timeout and Avahi environment, not on the
previous margin validation error.

## USB Hang Diagnostic Follow-up

A safer USB diagnostic round was run on 2026-08-07. The test did not clear the
kernel log and did not unbind or rebind `usblp`.

### USB Ownership

The printer was detected as:

```text
Bus 002 Device 003: ID 132b:232b Konica Minolta KONICA MINOLTA 206
Manufacturer: KONICA MINOLTA
Product:      KONICA MINOLTA 206
Serial:       A8A6041029423
```

It exposes two interfaces:

```text
Interface 0: vendor-specific, Driver=(none)
Interface 1: printer class,   Driver=(none)
```

No `usblp` driver owns either printer interface. The USB device is attached
only to the generic kernel USB driver, so no unbind operation was attempted.

### Submission Trace

The margin-fixed PPD was temporarily installed and a separate queue was
created:

```text
konica206usbdiag
```

The bounded client trace was:

```bash
timeout -k 5s 60s sudo strace -f -tt -s 256 \
  -o /tmp/legacy-submit-strace.log \
  legacy-printer-app submit \
  -d konica206usbdiag \
  -n 1 \
  /usr/share/legacy-printer-app/testpage.pdf
```

This run completed successfully:

```text
konica206usbdiag-1
submit_strace_exit=0
```

The client trace shows that both IPP requests were successfully posted to the
local PAPPL server:

```text
POST /ipp/print/konica206usbdiag
ipp://localhost/ipp/print/konica206usbdiag
```

The client then exited normally. No `/dev/bus/usb`, CUPS backend, or
`245igdirf` activity appeared in the client trace.

### PAPPL Job State

The job remained stuck in:

```text
1 processing root testpage.pdf
```

The service journal contained no filter-start, Ghostscript, USB, or Konica
driver error for this job.

The PAPPL server and worker were traced separately. The observed blocking calls
were `poll()`/`restart_syscall()` and `wait4()`; no USB device file, CUPS
backend, or proprietary filter syscall was observed:

```text
poll([{fd=3, events=POLLIN}, {fd=4, events=POLLIN}, {fd=12, events=POLLIN}], ...)
restart_syscall(<... resuming interrupted poll ...>)
wait4(-1 <unfinished ...>
```

Diagnostic artifacts were preserved at:

```text
/home/vinod/konica-pappl-usb-diagnostic-20260807/
```

The directory contains the client, server, and worker traces plus before/after
kernel-log captures.

### Updated Diagnosis

The client-side PAPPL command is not blocked on USB: it successfully submits
the IPP job and exits. The server-side job remains `processing` before any
observable USB access, CUPS backend execution, or `245igdirf` invocation.

The leading diagnosis is now a PAPPL/libpappl-retrofit job-processing or worker
synchronization problem, rather than `usblp` ownership or a direct USB
transport block. Avahi registration remains a separate service-advertising
problem, although upstream investigation should verify whether the installed
PAPPL version incorrectly waits on registration or device callbacks.

### Final Cleanup

The stuck PAPPL processes were terminated after the bounded diagnostic. The
temporary queue, PPD, systemd drop-in, and generated PAPPL state were removed.
The service was disabled and its failed state was reset.

Final verification:

```text
legacy-printer-app.service: disabled and inactive
KONICA_MINOLTA_206: enabled and idle
System default: KONICA_MINOLTA_206
Classic CUPS jobs: none
Backup checksum: OK
```

No `usblp` unbind/rebind operation was performed, and the live CUPS PPD was not
edited.

## Round 2 Full Job-Lifecycle Capture

The revised USB diagnostic plan's Round 2 was executed on 2026-08-07. This
round attached `strace` to the long-lived PAPPL service before submitting the
job, rather than tracing only the short-lived submit client.

### Queue and Job

The temporary queue was:

```text
konica206lifecycle
```

The fixed PPD was the same validated ICC-free, margin-adjusted copy used in the
previous round. One test page was submitted:

```text
konica206lifecycle-1
```

The PAPPL journal eventually reported:

```text
cfFilterExternal (245igdirf): Filter (PID 80609) stopped with status 2
cfFilterChain: 245igdirf (PID 80607) stopped with status 1
```

### Definitive USB Evidence

The lifecycle trace proves that the PAPPL retrofit path did reach the USB
device and the proprietary Konica filter. The relevant sequence was:

```text
openat(..., "/dev/bus/usb/002/003", O_RDWR|O_CLOEXEC) = 15
ioctl(15, USBDEVFS_GET_CAPABILITIES, ...) = 0
ioctl(15, USBDEVFS_CLAIMINTERFACE, ...) = 0
ioctl(15, USBDEVFS_SUBMITURB, ...) = 0
```

The proprietary filter was launched:

```text
execve("/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf", ...)
```

The filter generated the expected Konica/PJL output and wrote it into the
backend pipeline. The trace includes data beginning with:

```text
\33%-12345X@PJL
@PJL SET COMPRESS=JBIG
@PJL SET PAGESTATUS=START
```

The USB handling thread then submitted another URB and waited:

```text
ioctl(15, USBDEVFS_SUBMITURB, ...) = 0
poll([{fd=8, events=POLLIN}, {fd=9, events=POLLIN},
      {fd=15, events=POLLOUT}], 3, 60000)
```

That poll timed out after approximately 60 seconds. The filter eventually
exited with status 2 and PAPPL reported the filter-chain failure.

### Revised Root Cause

The USB hang is now confirmed to occur downstream of PAPPL job dispatch and
inside the actual USB/filter transmission path:

```text
PAPPL IPP submission       successful
PAPPL job dispatch         successful
245igdirf filter           launched
USB device open            successful
USB interface claim        successful
USB URB submission         accepted by kernel
USB URB completion         does not arrive before timeout
Filter                      exits status 2
PAPPL job                   remains/ends failed
```

This rules out:

- The original PPD margin validation error.
- The original ICC/Ghostscript `.putdeviceprops` error.
- `usblp` interface contention.
- A PAPPL client-side IPP submission hang.
- A failure to launch `245igdirf`.

The remaining problem is a USB protocol/device-response incompatibility during
or after transmission of the Konica proprietary output. The printer may accept
some bulk transfers but fail to provide the completion/status response expected
by the CUPS/PAPPL USB backend, or the backend may be waiting for a response that
this GDI device does not provide.

### Round 2 Artifacts

The complete lifecycle trace and journal are preserved at:

```text
/home/vinod/konica-pappl-usb-diagnostic-20260807/legacy-lifecycle-round2-strace.log
/home/vinod/konica-pappl-usb-diagnostic-20260807/legacy-lifecycle-round2-journal.log
```

The trace is large because it follows Ghostscript, the proprietary filter, the
USB backend thread, and all forked processes.

### Final Round 2 Cleanup

The temporary PAPPL queue, fixed PPD deployment, service drop-in, and generated
PAPPL state were removed. No USB driver was unbound or rebound.

Final verification:

```text
legacy-printer-app.service: disabled and inactive
KONICA_MINOLTA_206: enabled and idle
System default: KONICA_MINOLTA_206
Classic CUPS jobs: none
Backup checksum: OK
Live CUPS PPD: unchanged
```

### Recommended Next Step

Do not retry PAPPL printing repeatedly against this printer. The evidence is
now sufficient for an upstream report containing the exact USB URB timeout and
filter failure. If another local test is desired, the next useful experiment is
to compare the successful classic CUPS path and PAPPL path at the USB backend
level, or to test whether a backend option disables status/completion polling.
Any such test should remain isolated from the working CUPS queue.

## Round 3 USBMon Capture

The third diagnostic plan was executed on 2026-08-07 using the already
validated margin-fixed PPD and a new isolated queue named
`konica206usbmon`. The `usbmon` kernel module was loaded only for tracing; no
USB interface was unbound or rebound.

### Existing Trace Analysis

The Round 2 lifecycle trace contained one `USBDEVFS_SUBMITURB` for the raw USB
writer and no `USBDEVFS_REAPURBNDELAY` completion for that writer process:

```text
submit_urbs=1
reap_urbs=0
```

That established that a transfer was queued but did not identify its USB
direction. A bus-level capture was therefore performed.

### USBMon Result

Capture source:

```text
/sys/kernel/debug/usb/usbmon/2u
```

The captured traffic is preserved at:

```text
/home/vinod/konica-pappl-usb-diagnostic-20260807/usbmon-round3-2u.log
```

The printer first responded normally to control transfers, including device-ID
requests:

```text
C Ci:2:003:0 0 75 = 004b4d46 473a4b4f 4e494341 204d494e4f4c5441 ...
```

The first print-data transfer was then submitted to interface 1 as a bulk-out
request:

```text
S Bo:2:003:1 -115 4096 = 1b252d31323334355840504a4c ...
```

The data begins with the expected PJL header. Crucially, the capture contains
no matching completion record:

```text
C Bo:2:003:1 ...
```

There were also no bulk-IN/status transactions after the bulk-out submission.
The capture ended while the outbound transfer was still pending.

### Definitive Interpretation

The Konica printer answers control/device-ID requests, but does not complete
the first bulk print-data transfer submitted by the PAPPL retrofit path. No
interleaved bulk-IN/status request occurs during the stall.

This confirms the suspected protocol behavior at the wire level:

```text
Control/device ID requests: successful
Bulk OUT print transfer:    submitted, never completed
Bulk IN/status traffic:     absent during stall
PAPPL job:                  remains processing/fails later
```

The likely incompatibility is that the PAPPL retrofit USB writer submits the
Konica GDI stream without the bidirectional/status handling required by this
printer, while the classic CUPS USB path uses a different communication
sequence that is known to work. This is no longer a speculative job-dispatch
diagnosis.

### Round 3 Cleanup

After the one bounded capture, the temporary PAPPL service, queue, PPD, drop-in,
and generated state were removed. The `usbmon` module may remain loaded, but it
does not alter the printer queue or USB bindings.

Final verification:

```text
legacy-printer-app.service: disabled and inactive
KONICA_MINOLTA_206: enabled and idle
System default: KONICA_MINOLTA_206
Classic CUPS jobs: none
Backup checksum: OK
Live CUPS PPD: unchanged
```

No additional PAPPL print retries should be performed. The combined strace and
usbmon evidence is sufficient for an upstream `pappl-retrofit` report.

## Round 4 — Claude-Supplied PPD Test (2026-08-16)

A third PPD variant was supplied: `KonicaMinolta-206-real-margins-retrofit.ppd`
(ICC-free, real margins). Tested in a separate PAPPL queue (`konica206claude`)
with the standard production CUPS queue untouched.

### PPD Validation

`cupstestppd -W all` exit 4 (only non-fatal warnings):

- Real margins: `*ImageableArea A4: "6 12 589 830"` vs working CUPS full-bleed
  `"0 0 595 842"` — left/right 6pt, top/bottom 12pt.
- `*1284DeviceID: "MFG:KONICA MINOLTA;CMD:GDI,XPS;MDL:206;PRINTER"`
- `*HWMargins`/`DefaultUseHWMargins` present.
- `*cupsFilter` unchanged (`245igdirf`).
- Warnings: `DefaultOCM_Collate` required missing, `Bad ModelName` ("(" not
  allowed), translation strings, `DefaultUseHWMargins`/`DefaultOCMCollate` no
  corresponding options — all tolerated by PAPPL.
- Driver discovered as `konica-minolta--206--real-margin-retrofit-en` in the
  PAPPL add-printer form.

### Result — PAPPL-Side "Unable to open device", No Filter

- Queue `konica206claude` created OK, reached idle.
- `legacy-printer-app submit` returned job ID immediately (exit 0).
- PAPPL paused the queue with:
  `[Printer konica206claude] Unable to open device 'usb://...&interface=1',
  pausing queue until printer becomes available.`
- No `245igdirf` filter process was ever spawned (strace shows zero `execve`).
- A device-monitor thread repeatedly opened `/dev/bus/usb/002/003`,
  `USBDEVFS_CLAIMINTERFACE` = 0, and completed probe URBs, yet the open was
  still classified as failed (log-level decision inside PAPPL's USB path).
- No kernel USB reset/stall/timeout messages during the window — the printer
  remained responsive: `sudo /usr/lib/cups/backend/usb` immediately returned
  the device with correct ID, exit 0.
- A repeat attempt after cancelling stuck jobs and `legacy-printer-app resume`
  failed identically.

### Interpretation

The PPD is not the problem — PAPPL accepted the real-margin PPD and the queue
was created. The failure is again in `libpappl`'s raw USB transport: even
before any print data is written, PAPPL's device-open/claim logic reports the
device as unavailable for this GDI printer, whereas classic CUPS's `usb`
backend opens and reads the same device fine.

This is a stricter failure than Round 2 (where the filter ran and a data URB
stalled): with this PPD path PAPPL fails at device-open time, before the
filter chain. Either way, the retrofit USB stack is not compatible with this
printer's USB behavior.

### Round 4 Cleanup

All PAPPL state rolled back and verified: service disabled/inactive, drop-in
and PPD removed, `legacy-printer-app.state` and `/var/lib/legacy-printer-app`
removed, `KONICA_MINOLTA_206` still enabled/idle/default, live CUPS PPD
unchanged (0 `cupsICCProfile` lines), backup SHA256SUMS OK, no leftover
processes.

Traces preserved:
- `konica-pappl-usb-diagnostic-20260807/legacy-claude-lifecycle-strace.log`
- `konica-pappl-usb-diagnostic-20260807/legacy-claude-clean-strace.log`

Conclusion: the Claude-supplied PPD is valid and margin-correct for PAPPL, but
does not change the underlying `pappl-retrofit` USB transport incompatibility;
printing through `legacy-printer-app` remains non-functional for this Konica
GDI printer.

## Round 5 — URI Fix: SUCCESS (2026-08-16)

Followed `/home/vinod/Downloads/KONICA_PAPPL_ROUND5_URI_FIX.md`. Root cause of
Round 4's "Unable to open device": `pappl_usb_find()` builds its own device URI
internally and NEVER includes CUPS's `interface=` query parameter; the open
callback does a plain `strcmp` against that URI. Passing the URI exactly as
PAPPL generates it makes the match succeed.

### Confirmed URI

```text
PAPPL device:  usb://KONICA%20MINOLTA/206?serial=A8A6041029423   (no interface=)
```

Verified via `legacy-printer-app devices` and the `smi55357-device-uri` value in
the debug journal.

### What Worked

- Queue `konica206uri` added with the corrected URI + real-margin PPD driver
  (`konica-minolta--206--real-margin-retrofit-en`).
- Filter chain ran completely: pdfinfo -> bannertopdf/pdftopdf -> ghostscript
  (A4 595x842, `.HWMargins[6.009449 11.990551...]`) -> 245igdirf -> USB backend.
- USB backend opened `/dev/bus/usb/002/003`, claimed interface, submitted URBs,
  and all bulk-OUT transfers COMPLETED (usbmon: `S Bo` -> `C Bo` for 4096 +
  61782 + 5035 bytes, all status 0). No 60s poll timeout.
- Backend exited status 0; job completed; queue returned to idle.

### The Media-Size Trap

- Job 1 defaulted to `na_letter_8.5x11in` (PAPPL PPD default). Printer (A4 tray)
  parsed the PJL and raised a size error — proof the transport was already
  working, but the wrong media was sent.
- Jobs 2-3 were sent with A4 while the printer was still holding the size error,
  so it sat in "data receiving" without printing.
- After power-cycling the printer, job 4 with `-o media=iso_a4_210x297mm`
  printed correctly: **A4 page, proper content and margins confirmed by user.**

### Requirement for Printing via PAPPL

1. Queue device URI must be exactly `usb://KONICA%20MINOLTA/206?serial=A8A6041029423`
   (no `interface=1`).
2. Media must be specified as A4 (`-o media=iso_a4_210x297mm`) — PAPPL's PPD
   default is Letter and the printer rejects it.
3. If the printer ever gets stuck in "data receiving" after a bad job, a power
   cycle clears it.

### Round 5 Cleanup

All PAPPL state removed and verified: service disabled/inactive, drop-in,
PPD, state file, `/var/lib/legacy-printer-app` gone; `KONICA_MINOLTA_206` still
enabled/idle/system-default with live PPD unchanged (0 cupsICCProfile lines);
backup SHA256SUMS OK; no leftover processes.

Evidence preserved in `konica-pappl-usb-diagnostic-20260807/`:
- `round5-execve.log`, `round5-a4-execve.log`, `round5-a4-retry-execve.log`,
  `round5-clean-a4-execve.log` (strace)
- `round5-clean-a4-usbmon.log` (wire-level proof of completed bulk-OUT transfers)

Conclusion: the URI fix resolves the retrofit transport incompatibility. With
the corrected URI and A4 media, `legacy-printer-app` prints successfully to the
Konica Minolta 206. The original classic CUPS queue remains untouched and
functional.

## Permanent Installation (2026-08-16)

Both systems now coexist permanently; the classic CUPS queue is untouched.

### PAPPL (legacy-printer-app)

- Service: `legacy-printer-app.service` enabled at boot, active.
- Drop-in `/etc/systemd/system/legacy-printer-app.service.d/override.conf`:
  `Environment=PPD_PATHS=/var/lib/legacy-printer-app/ppd:/usr/share/cups/model:/usr/lib/cups/driver`
- PPD installed at `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-real-margins.ppd`
- Queue `konica206uri`:
  - Device URI: `usb://KONICA%20MINOLTA/206?serial=A8A6041029423` (NO `interface=`)
  - Driver: `konica-minolta--206--real-margin-retrofit-en`
  - Default media set to A4 via IPP `Set-Printer-Attributes`:
    `media-default = iso_a4_210x297mm` (avoids the Letter size-error trap)
- Endpoint: `http://localhost:8000/ipp/print/konica206uri`

### Classic CUPS (untouched)

- `KONICA_MINOLTA_206` still enabled/idle/system default, live PPD unchanged
  (0 cupsICCProfile lines), backup SHA256SUMS OK.
- Device URI remains `usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1`

### Verified

- 2 test pages printed correctly (A4, proper margins).
- `legacy-printer-app jobs` shows completed; queue returns to idle.
- Boot persistence: `systemctl is-enabled legacy-printer-app.service` = enabled.
- Note: Avahi errors in journal are cosmetic (no Avahi daemon installed).

## Round 6 — Full-Bleed + Duplex Fix; CUPS GUI Integration (2026-08-16)

### CUPS integration (GUI apps like Atril)

- Avahi absent -> PAPPL not auto-discoverable; added an explicit CUPS queue:
  `konica206uri` (same name) with URI `ipp://localhost:8000/ipp/print/konica206uri`
  using a **PDF-passthrough PPD** so CUPS sends `application/pdf` unchanged and
  PAPPL does the rendering. CUPS PPD:
  `/var/lib/legacy-printer-app/ppd/konica206-pdf-fullbleed.ppd`
  (`cupsFilter2: "application/pdf application/pdf 0 -"`).
- The passthrough PPD must expose `*Duplexer`/`*Duplex` (with
  `*DefaultDuplexer: true`, `*DefaultDuplex: DuplexNoTumble`) so GUI apps like
  Atril offer 2-sided printing; without them Atril shows no duplex option.
  Verified: `lp -o sides=two-sided-long-edge` printed a 2-page doc on 2 sides.
- **Atril media-col rejection (fixed):** Atril derives media size from the PPD's
  A4 points and sends a `media-col` collection. With A4 declared as `595 842 pt`
  it converted to `20990x29704` (0.01mm units) which PAPPL strictly rejects
  ("Unsupported media-col collection value", backend ipp status 5). Declaring A4
  as `595.28 841.89 pt` makes it convert to exactly `21000x29700`, matching
  PAPPL's supported A4. Both the `*PageSize`/`*PageRegion`/`*PaperDimension`
  and `*ImageableArea` A4 values must be updated. Verified: Atril-style
  `media-col` jobs now print (2 pages, duplex).
- **Atril print-color-mode rejection (fixed):** Atril sent
  `print-color-mode=color` but PAPPL supports only `monochrome`, so PAPPL
  rejected jobs ("Unsupported print-color-mode keyword value"). The passthrough
  PPD has no `*ColorModel` option, so CUPS advertised no
  `print-color-mode-supported` values and Atril defaulted to `color`. Adding
  `*OpenUI *ColorModel/Color Model` with only `*ColorModel Gray` makes CUPS
  advertise `print-color-mode-supported = monochrome` (requires CUPS restart),
  so Atril sends `monochrome`. Verified: CUPS now reports
  `print-color-mode-supported = monochrome` and Atril-style jobs pass
  validation. CUPS must be restarted (`systemctl restart cups`) after editing
  the PPD for `print-color-mode-supported` to appear.
- Other attempts FAILED and were removed:
  - Raw queue (`-m raw`): CUPS sends PDF as octet-stream -> PAPPL relays raw
    bytes -> printer wedges in "data receiving".
  - PPD with real `245igdirf` cupsFilter on the CUPS queue: CUPS renders and
    sends PJL as octet-stream -> PAPPL aborts
    `Unable to process job with format 'application/octet-stream'`.

### Render-architecture fact

- The CUPS-side PPD only controls CUPS preprocessing. PAPPL renders with ITS OWN
  driver PPD (the one selected at `legacy-printer-app add -m ...`). Render-critical
  settings must live in the PAPPL driver PPD.

### Full-bleed + duplex driver PPD

- Created `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd`
  (driver `konica-minolia--206--full-bleed-retrofit-en`):
  - `*ImageableArea A4: "0 0 595 842"` (full-bleed), Letter `"0 0 612 792"`.
  - `*DefaultDuplexer: true`, `*DefaultDuplex: DuplexNoTumble` so gs emits
    `-dDuplex` and 245igdirf emits `@PJL SET DUPLEX=ON` + `BINDING=SHORTEDGE`,
    matching the classic working output.

### Raster is identical; PJL IMAGELEN differs

- Tee-wrapped `245igdirf` on both paths: the CUPS raster fed to 245igdirf is
  **byte-identical** (34808176 bytes) for real.pdf via classic and via PAPPL.
- Classic output: `IMAGELEN=17296` (single band) -> 17711 bytes total, WORKS.
- PAPPL output: `IMAGELEN=11740` (single band) -> 12155 bytes, works once
  duplex fix applied + printer freshly power-cycled.
- Difference is 245igdirf options (media-col borderless + Duplex options), not
  the raster data.

### Duplex fix result

- With `DUPLEX=ON` in the PAPPL PJL: **real.pdf printed** via the CUPS queue
  (single page), and a real **2-page PDF printed both sides**.
- Conclusion: the earlier "DUPLEX=OFF" was NOT the sole wedge cause; the duplex
  fix plus a fresh (power-cycled) printer cleared the wedge for real documents.
- Note: after ANY print, the printer must be in a non-wedged state; jobs sent
  while the printer is wedged abort at the backend.

### Known limitation: banner-content PDFs wedge the printer

- Printing PAPPL's `testpage.pdf` (or any PDF whose content is sniffed as
  `application/vnd.cups-pdf-banner`) triggers `bannertopdf`, producing a
  2-PAGESTATUS-block job with banded `IMAGELEN=32768,32768,...` that **wedges the
  printer** in "data receiving" (needs power cycle). Detection is by content, not
  filename (renaming to `neutral-name.pdf` still detected as banner).
- Real documents (single and multi-page) print reliably; only banner-detected
  content wedges. Use the classic `KONICA_MINOLTA_206` queue for test/banner pages.

### PAPPL driver-name restart quirk (fixed)

- User-added PPDs register under `-user-added-en` on restart, but
  `legacy-printer-app add` accepts the non-suffixed name (e.g.
  `konica-minolia--206--full-bleed-retrofit-en`) and rejects the suffixed one.
  State referencing the non-suffixed name gets dropped on restart.
- Fixed with `/usr/local/bin/ensure-konica206uri.sh` wired as
  `ExecStartPost` in the drop-in: re-adds the queue (and sets A4 media-default)
  if missing after startup. Queue now survives `systemctl restart`.

### Cleanup

- Classic backend `/usr/lib/cups/backend/usb` restored to original ELF;
  removed capture wrapper copies (`usb.real`, `usb.orig.backup`).
- `/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf` restored
  (capture wrapper removed).
- Debug jobdata files kept at `/var/spool/legacy-printer-app/debug-jobdata-konica206uri-*.prn`.
- usbmon logs in `/home/vinod/konica-pappl-usb-diagnostic-20260807/`:
  `cups-duplex-fix-usbmon.log`, `cups-twopage-usbmon.log`.

## Round 7 — Black-Page Root Cause (OCM_TonerSave) + USB Wedge Root Cause (PAPPL large writes) (2026-08-16)

### Black-page root cause: `OCM_TonerSave`

- Same 34808176-byte sGray raster through the same `245igdirf` binary:
  - classic argv (contains `...OCM_TonerSave=TRUE`) -> 174496 bytes correct gray output
  - PAPPL argv (contains `...noOCM_TonerSave`) -> 164550 bytes all-black output
- Incremental option tests (ColorModel=Gray, Duplex, media-col) on the classic base did NOT change output (still 174496). Replacing `noOCM_TonerSave` with `OCM_TonerSave=TRUE` in the full PAPPL argv produced 174496 bytes byte-identical to classic.
- Fix: `/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd` `*DefaultOCM_TonerSave: FALSE` -> `TRUE` (matches classic PPD). Also applied to real-margins PPD. Verified job 18: 174496 bytes, 6 bands, EOJ, byte-identical to classic.

### USB wedge root cause: single large PAPPL USB write

- PAPPL `_prPrintFilterFunction` (job-process.c / print-job.c) reads filter output into a 65536-byte buffer and calls `papplDeviceWrite(device, buffer, bytes)` once with the whole chunk. `pappl_usb_write` does a single `libusb_bulk_transfer` of the full buffer (61465 bytes observed).
- Printer's USB controller drops off the bus when its buffer overflows from one large write: kernel log `usb 2-2: USB disconnect, device number 22` then re-enumeration as device 23. Backend error: `[Device] Unable to write 61465 bytes to USB port: No such device`.
- Classic CUPS usb backend writes in 8192-byte chunks (usbmon) and works.
- Decisive proof: correct 174496-byte output sent directly through classic backend printed successfully.

### Fix: switch PAPPL printer to the `cups:` device scheme

- pappl-retrofit supports a `cups:` device scheme that runs the classic CUPS backend as a subprocess inside the filter chain (`ppdFilterExternalCUPS`, exec_mode=1). The backend reads job data from its stdin and writes to USB in 8192-byte chunks.
- Changed printer URI from `usb://KONICA%20MINOLTA/206?serial=A8A6041029423` to `cups:usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1` (in `/var/lib/legacy-printer-app/legacy-printer-app.state`).
- Added `-o backend-directory=/usr/lib/cups/backend` to the systemd drop-in ExecStart.
- Updated `/usr/local/bin/ensure-konica206uri.sh` URI accordingly.
- Result: dense-a4 (job 21) and 2-sided twopage (job 22) printed via PAPPL queue; journal shows 8192-byte `cfFilterExternal (usb)` writes, "Sent 174496 bytes", backend exited cleanly. Output byte-identical to classic (`sha256` bfcaa12f...). No USB disconnect.

### Final state

- PAPPL queue `konica206uri` -> `cups:usb://...&interface=1` (classic chunked USB writes); classic queue `KONICA_MINOLTA_206` -> `usb://...&interface=1` (untouched).
- Pristine binaries restored: `/usr/lib/cups/backend/usb` (sha256 1ebbe1e6...), `/usr/lib/cups/filter/KonicaMinolta/245igdi/Filters/245igdirf` (sha256 0faf0a69...). `/tmp` capture artifacts removed.
- Known limitation (Round 6) remains: banner-content PDFs still wedge; use classic queue for banner/test pages.

## Round 8 — CUPS 3.0-proofing: Self-Contained Chunked USB Backend (2026-08-16)

### Problem

The Round 7 fix made the `cups:` device scheme launch the **classic CUPS USB
backend** (`/usr/lib/cups/backend/usb`) as a subprocess. That subprocess:
- does **NOT** talk to the CUPS daemon (verified: no `/var/run/cups`/`cupsServer`
  strings; job mode = read stdin, write USB, side-channel via pipes),
- but **links `libcups.so.2`** (`libcups2t64`, CUPS 2.4.x) plus libusb-1.0,
  libudev, avahi, gnutls, krb5 (verified via `ldd`).

CUPS 3.0 removes PPDs/filters/classic backends and ships libcups3, so the
classic backend binary and `libcups2` would likely disappear from the distro —
breaking the `cups:` scheme.

### Solution: `konica-usb-backend`

A self-contained, CUPS-compatible USB backend that depends **only on libusb-1.0**
+ libc. Source: `/home/vinod/konica-usb-backend/konica-usb-backend.c`, built with:

```bash
gcc -O2 -Wall -o usb konica-usb-backend.c -I/usr/include/libusb-1.0 -lusb-1.0
```

Installed at `/usr/local/libexec/konica-backend/usb` (root:root, 0755,
sha256 `d76e61bc574752a05d833f6e90f5c1dd80f03996ffe4fb9c75d002b7e7658ce9`).
`libusb-1.0-0-dev` was installed to build it.

Behavior (mirrors the classic backend that worked, minus any CUPS dependency):
- **Discovery mode** (no `DEVICE_URI`): enumerates USB, prints CUPS device line:
  `direct usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1 "KONICA MINOLTA 206" ...`
- **Job mode** (`DEVICE_URI` env): parse `serial`/`interface` query params
  (interface default 1), match VID 132b / PID 232b + serial `A8A6041029423`,
  open, set config 1, detach kernel driver if active, claim interface 1, find
  the first bulk-OUT endpoint (0x01), then `read(stdin)` -> `libusb_bulk_transfer`
  in **≤8192-byte chunks** (30 s timeout). Emits `STATE:`/`INFO:`/`DEBUG:` to
  stderr for the app's journal.
- CUPS-compatible exit codes: 0 OK, 1 STOP, 5 FAILED.

Note: reading the USB serial string requires root access to `/dev/bus/usb`
(as non-root it reads "unknown"); the Printer Application runs as root via
systemd, so this is not a problem.

### Config change

`/etc/systemd/system/legacy-printer-app.service.d/override.conf`:
`-o backend-directory=/usr/lib/cups/backend` -> `-o backend-directory=/usr/local/libexec/konica-backend`.

The stored device URI is unchanged (`cups:usb://...&interface=1`).

### Verification

1. **Direct pipe test** — piped the known-good 174496-byte dense output through
   the backend:
   `sudo env DEVICE_URI="usb://KONICA%20MINOLTA/206?serial=A8A6041029423&interface=1" /usr/local/libexec/konica-backend/usb < /tmp/out-classic.prn`
   - 21 x 8192-byte chunks + 2464-byte tail = 174496 bytes, exit 0.
   - **No USB disconnect** (device stayed 23; last disconnect was the pre-fix
     wedge at 10:01:12, device 22->23).
2. **Full stack** — 2-sided `twopage` via PAPPL queue (CUPS job 121 / PAPPL job 25):
   - Journal: `/usr/local/libexec/konica-backend/usb (PID 216708) started`,
     `Connected to interface 1, endpoint 0x01`, `Wrote 8192 bytes`,
     `Wrote 960 bytes`, `Backend (PID 216708) exited with no errors`.
   - Job completed (state 9), queue idle.
3. **User confirmed:** "both printed fine" (dense page via direct pipe and
   2-sided page via the PAPPL queue).

### Result

The PAPPL path no longer depends on classic CUPS, its backends, or `libcups2` —
it survives the CUPS 3.0 transition. The classic `/usr/lib/cups/backend/usb`
binary remains installed only for the legacy `KONICA_MINOLTA_206` queue (which
itself does not survive CUPS 3.0 and is documented as such).

## Round 9 — Hardening: driver relocation to /usr/local, package holds, backup (2026-08-16)

### Context

Review of upgrade survival (Ubuntu future releases) concluded the config in
`/usr/local`, `/etc/systemd`, and `/var/lib` survives `apt` untouched, but three
packages could be dropped by a future release upgrade: `legacy-printer-app`,
`libpappl-retrofit1`, `libpappl1t64`, and the vendor driver
`konica-minolta-245igdi-cups` (2023, already absent from current Ubuntu sources —
`apt-cache madison konica-minolta-245igdi-cups` returns nothing). Rendering
depends on the driver binary `245igdirf`, which the retrofit PPDs referenced by
the package-owned absolute path `/usr/lib/cups/filter/KonicaMinolta/245igdi/`.

`libcups3` itself is NOT a blocker: OpenPrinting added libcups3 support to
pappl-retrofit, libppd, and libcupsfilters (the app builds with libcups2 OR
libcups3). libcups 3.0.2 released 2026-06-05. The only real caveat is that the
installed `legacy-printer-app 1.0~b2-0ubuntu8` will need a newer pappl-retrofit
build at CUPS-3 migration time — a normal package migration, not a fundamental
printer-driver problem.

### Steps

1. **Relocated the driver tree** to `/usr/local/lib/konica/KonicaMinolta/245igdi/`
   (binary, `mtorf.ocm`, `Halftones/`, `Colorworlds/`, `Profiles/`, `COPYING`).
   Verified the binary runs from the new location (`-h` → exit 10, a CUPS "no
   job" error, no crash). The binary has NO compiled-in absolute paths for its
   support files — it uses the PPD's `*OCM_resourceDir` to find them.
2. **Repointed both retrofit PPDs** (fullbleed + real-margins): line 39
   `*cupsFilter` and line 56 `*OCM_resourceDir` now reference
   `/usr/local/lib/konica/KonicaMinolta/245igdi/...`.
3. **Debian 13 kit updated** to match: all kit PPDs repointed; setup script now
   installs the driver under `/usr/local/lib/konica/...` (apt-immune).
4. **Restart + test:** `systemctl restart legacy-printer-app`; printer
   `konica206uri` and CUPS queue + default survived. Printed dense-a4 via the
   PAPPL queue (job 26): output 174496 B, sha256
   `bfcaa12f891a0e2d13a9ea29ae6b6fa8186b1717c1cc0fcc838abaf65c7a6a96` —
   **byte-identical** to `/tmp/out-classic.prn`. `job-state: completed`
   `job-completed-successfully`; no new USB disconnect.
5. **`apt-mark hold`** on `legacy-printer-app`, `libpappl-retrofit1`,
   `libpappl1t64`, `konica-minolta-245igdi-cups`.
6. **Archived `.debs`** to the backup: `legacy-printer-app`,
   `libpappl-retrofit1`, `libpappl1t64` (from apt cache), plus `libcups2t64` and
   `libcupsimage2t64` (downloaded). The driver `.deb` is unrecoverable from
   current repos, so the installed tree + dpkg metadata (`dpkg-info/`) is
   archived instead.
7. **Backup regenerated:** `/home/vinod/konica-pappl-backup-20260816-1050/`
   (tarball `.tar.gz`) now includes the relocated driver tree, repointed PPDs,
   backend, ensure script, drop-in, Debian 13 kit, `debs/`, `dpkg-info/`, and
   `SHA256SUMS`.

### Result

Rendering no longer depends on the `konica-minolta-245igdi-cups` package. Even
if a future Ubuntu release removes all four packages, printing keeps working via
the `/usr/local` driver + the self-contained backend; recovery is a normal
package rebuild/migration, and the backup provides complete offline restore.
