/*
 * konica-usb-backend.c
 *
 * Self-contained CUPS-style USB backend for the Konica Minolta 206 (GDI).
 *
 * Unlike the classic CUPS "usb" backend, this program depends ONLY on
 * libusb-1.0 and the C library. It does not link against libcups and does
 * not talk to the CUPS daemon, so it keeps working after CUPS 3.0 removes
 * classic PPDs, filters, and backends.
 *
 * It deliberately writes print data to the printer in SMALL (<=8192 byte)
 * chunks, because the Konica 206's USB controller drops off the bus if a
 * single bulk write is too large (observed ~61 KB single write -> USB
 * disconnect, device re-enumerated, printer stuck in "data receiving").
 *
 * Modes:
 *
 *   Discovery mode (no DEVICE_URI env / no args):
 *     Enumerates USB printers and prints CUPS device lines:
 *       direct URI "make model" "name" "1284 device ID" ""
 *
 *   Job mode (DEVICE_URI env set):
 *     Reads print data from stdin and writes it to the bulk OUT endpoint
 *     of the matching printer in <=8192 byte chunks.
 *
 * Build:  gcc -O2 -o usb konica-usb-backend.c $(pkg-config --cflags --libs libusb-1.0)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <poll.h>
#include <libusb-1.0/libusb.h>

#define VENDOR_KONICA  0x132b
#define PRODUCT_206    0x232b

#define CHUNK_SIZE     8192
#define WRITE_TIMEOUT  30000      /* ms per bulk transfer */
#define READ_TIMEOUT   30000      /* ms without data on stdin before aborting */

/* Exit codes compatible with CUPS backends */
#define EXIT_OK        0
#define EXIT_STOP      1          /* retry later */
#define EXIT_FAILED    5

/*
 * Parse a "usb://make/model?serial=XXX&interface=N" device URI.
 * Returns: serial string (caller-provided buffer), interface number.
 * serial and interface are optional.
 */
static void
parse_device_uri(const char *uri,
                 char        *serial,
                 size_t       serial_size,
                 int         *interface_num)
{
    const char *query;

    *interface_num = 1;                 /* default: printer-class interface */

    serial[0] = '\0';

    if ((query = strchr(uri, '?')) == NULL)
        return;

    query ++;
    while (*query)
    {
        const char *amp = strchr(query, '&');
        size_t len = amp ? (size_t)(amp - query) : strlen(query);
        char key[64], val[256];

        /* split key=value */
        const char *eq = memchr(query, '=', len);
        if (eq)
        {
            size_t klen = (size_t)(eq - query);
            size_t vlen = len - klen - 1;
            if (klen >= sizeof(key)) klen = sizeof(key) - 1;
            if (vlen >= sizeof(val)) vlen = sizeof(val) - 1;
            memcpy(key, query, klen); key[klen] = '\0';
            memcpy(val, eq + 1, vlen); val[vlen] = '\0';

            if (strcmp(key, "serial") == 0)
                snprintf(serial, serial_size, "%s", val);
            else if (strcmp(key, "interface") == 0)
                *interface_num = atoi(val);
        }

        if (!amp)
            break;
        query = amp + 1;
    }
}

/*
 * Build a CUPS device URI from a libusb device. Always uses the
 * "usb://make/model?serial=SERIAL&interface=1" form that the classic
 * backend uses, so the Printer Application's stored "cups:..." URI matches.
 */
static void
make_device_uri(libusb_device *dev,
                const char    *serial,
                char          *buf,
                size_t         bufsize)
{
    snprintf(buf, bufsize,
             "usb://KONICA%%20MINOLTA/206?serial=%s&interface=1",
             serial);
}

/*
 * Discovery mode: list all Konica Minolta 206 devices.
 */
static int
list_devices(void)
{
    libusb_device **devs;
    ssize_t count, i;
    int ret = EXIT_OK;

    if (libusb_init(NULL) < 0)
    {
        fprintf(stderr, "ERROR: Unable to initialize libusb.\n");
        return (EXIT_FAILED);
    }

    count = libusb_get_device_list(NULL, &devs);
    if (count < 0)
    {
        fprintf(stderr, "ERROR: Unable to get USB device list.\n");
        libusb_exit(NULL);
        return (EXIT_FAILED);
    }

    for (i = 0; i < count; i ++)
    {
        struct libusb_device_descriptor desc;
        libusb_device_handle *handle;
        char serial[256] = "";
        char uri[512];
        int iface;

        if (libusb_get_device_descriptor(devs[i], &desc) < 0)
            continue;

        if (desc.idVendor != VENDOR_KONICA || desc.idProduct != PRODUCT_206)
            continue;

        /* Try to read the serial number string */
        if (libusb_open(devs[i], &handle) == 0)
        {
            if (desc.iSerialNumber)
                libusb_get_string_descriptor_ascii(handle,
                                                   desc.iSerialNumber,
                                                   (unsigned char *)serial,
                                                   sizeof(serial));
            libusb_close(handle);
        }

        if (!serial[0])
            snprintf(serial, sizeof(serial), "unknown");

        make_device_uri(devs[i], serial, uri, sizeof(uri));

        printf("direct %s \"KONICA MINOLTA 206\" \"KONICA MINOLTA 206\" "
               "\"MFG:KONICA MINOLTA;CMD:GDI,XPS;MDL:206;CLS:PRINTER;CID:KONICA MINOLTA206;\" \"\"\n",
               uri);
        (void)iface;
    }

    libusb_free_device_list(devs, 1);
    libusb_exit(NULL);

    return (ret);
}

/*
 * Find a bulk OUT endpoint on the given interface.
 * Returns endpoint address (0x01 .. 0x0f) or -1.
 */
static int
find_bulk_out_endpoint(libusb_device *dev, int interface_num)
{
    struct libusb_config_descriptor *config = NULL;
    const struct libusb_interface_descriptor *alt;
    int i, ep, endpoint = -1;

    if (libusb_get_active_config_descriptor(dev, &config) < 0)
        return (-1);

    for (i = 0; i < (int)config->bNumInterfaces; i ++)
    {
        if (config->interface[i].num_altsetting < 1)
            continue;

        alt = &config->interface[i].altsetting[0];

        if ((int)alt->bInterfaceNumber != interface_num)
            continue;

        for (ep = 0; ep < (int)alt->bNumEndpoints; ep ++)
        {
            const struct libusb_endpoint_descriptor *ed =
                &alt->endpoint[ep];

            if ((ed->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) ==
                    LIBUSB_TRANSFER_TYPE_BULK &&
                (ed->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                    LIBUSB_ENDPOINT_OUT)
            {
                endpoint = ed->bEndpointAddress;
                break;
            }
        }
        break;
    }

    libusb_free_config_descriptor(config);
    return (endpoint);
}

/*
 * Job mode: read stdin and write to the printer in small chunks.
 */
static int
send_to_printer(libusb_device_handle *handle,
                libusb_device        *dev,
                int                   interface_num,
                int                   endpoint)
{
    unsigned char buffer[CHUNK_SIZE];
    int transferred, ret;
    int config = -1;

    if (libusb_get_configuration(handle, &config) < 0)
        config = -1;
    if (config != 1)
    {
        /* Ignore "already set" errors */
        libusb_set_configuration(handle, 1);
    }

    if (libusb_kernel_driver_active(handle, interface_num) == 1)
        libusb_detach_kernel_driver(handle, interface_num);

    if (libusb_claim_interface(handle, interface_num) < 0)
    {
        fprintf(stderr, "ERROR: Unable to claim interface %d.\n",
                interface_num);
        return (EXIT_FAILED);
    }

    fprintf(stderr, "STATE: +connecting-to-device\n");
    fprintf(stderr, "INFO: Connected to interface %d, endpoint 0x%02x\n",
            interface_num, endpoint);

    while (1)
    {
        struct pollfd pfd;
        ssize_t bytes;
        size_t offset = 0;
        int pr;

        /*
         * Wait for data on stdin with a timeout. If the upstream filter
         * chain stalls (e.g. the vendor GDI filter hangs and produces
         * nothing), a plain read() would block forever and freeze the whole
         * print queue. Polling lets us abort the job instead.
         */
        pfd.fd = 0;
        pfd.events = POLLIN;

        pr = poll(&pfd, 1, READ_TIMEOUT);
        if (pr < 0)
        {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "ERROR: poll() failed: %s\n", strerror(errno));
            libusb_release_interface(handle, interface_num);
            return (EXIT_FAILED);
        }
        if (pr == 0)
        {
            fprintf(stderr,
                    "ERROR: No data received for %d seconds; aborting job "
                    "to avoid blocking the print queue.\n", READ_TIMEOUT / 1000);
            libusb_release_interface(handle, interface_num);
            return (EXIT_STOP);
        }

        bytes = read(0, buffer, sizeof(buffer));
        if (bytes == 0)
            break;                              /* EOF: end of job */
        if (bytes < 0)
        {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "ERROR: Unable to read print data: %s\n",
                    strerror(errno));
            libusb_release_interface(handle, interface_num);
            return (EXIT_FAILED);
        }

        while (offset < (size_t)bytes)
        {
            ret = libusb_bulk_transfer(handle, endpoint,
                                       buffer + offset,
                                       (int)(bytes - offset),
                                       &transferred, WRITE_TIMEOUT);
            if (ret < 0)
            {
                fprintf(stderr, "ERROR: Unable to write %d bytes to USB port: %s\n",
                        (int)(bytes - offset),
                        (ret == LIBUSB_ERROR_NO_DEVICE) ?
                            "No such device (it may have been disconnected)" :
                            libusb_error_name(ret));
                libusb_release_interface(handle, interface_num);
                return (ret == LIBUSB_ERROR_NO_DEVICE ? EXIT_STOP : EXIT_FAILED);
            }
            offset += (size_t)transferred;
        }
        fprintf(stderr, "DEBUG: Wrote %zd bytes of print data...\n", bytes);
    }

    libusb_release_interface(handle, interface_num);
    fprintf(stderr, "STATE: -connecting-to-device\n");

    return (EXIT_OK);
}

/*
 * Open the printer matching the serial (if given) in the device URI.
 */
static libusb_device_handle *
open_printer(const char *serial, int interface_num, libusb_device **matched)
{
    libusb_device **devs;
    libusb_device_handle *handle = NULL;
    ssize_t count, i;

    count = libusb_get_device_list(NULL, &devs);
    if (count < 0)
        return (NULL);

    *matched = NULL;

    for (i = 0; i < count && !handle; i ++)
    {
        struct libusb_device_descriptor desc;
        libusb_device_handle *h;
        char dev_serial[256] = "";

        if (libusb_get_device_descriptor(devs[i], &desc) < 0)
            continue;

        if (desc.idVendor != VENDOR_KONICA || desc.idProduct != PRODUCT_206)
            continue;

        if (libusb_open(devs[i], &h) < 0)
            continue;

        if (desc.iSerialNumber)
            libusb_get_string_descriptor_ascii(h, desc.iSerialNumber,
                                               (unsigned char *)dev_serial,
                                               sizeof(dev_serial));
        libusb_close(h);

        if (serial[0] && strcmp(serial, dev_serial) != 0)
            continue;

        /* Match found; open it for real */
        if (libusb_open(devs[i], &handle) == 0)
            *matched = devs[i];
    }

    libusb_free_device_list(devs, 1);
    return (handle);
}

int
main(int argc, char *argv[])
{
    const char *uri = getenv("DEVICE_URI");
    char serial[256];
    int interface_num;
    libusb_device_handle *handle;
    libusb_device *dev;
    int endpoint;
    int ret;

    if (!uri || !uri[0])
        return (list_devices());

    parse_device_uri(uri, serial, sizeof(serial), &interface_num);

    if (libusb_init(NULL) < 0)
    {
        fprintf(stderr, "ERROR: Unable to initialize libusb.\n");
        return (EXIT_FAILED);
    }

    handle = open_printer(serial, interface_num, &dev);
    if (!handle)
    {
        fprintf(stderr,
                "ERROR: Unable to find printer matching '%s'.\n", uri);
        libusb_exit(NULL);
        return (EXIT_STOP);
    }

    endpoint = find_bulk_out_endpoint(dev, interface_num);
    if (endpoint < 0)
    {
        fprintf(stderr, "ERROR: No bulk OUT endpoint on interface %d.\n",
                interface_num);
        libusb_close(handle);
        libusb_exit(NULL);
        return (EXIT_FAILED);
    }

    ret = send_to_printer(handle, dev, interface_num, endpoint);

    libusb_close(handle);
    libusb_exit(NULL);

    return (ret);
}