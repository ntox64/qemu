/*
 * USB Mass Storage Device emulation
 *
 * Copyright (c) 2006 CodeSourcery.
 * Written by Paul Brook
 *
 * This code is licensed under the LGPL.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qemu/option.h"
#include "qemu/config-file.h"
#include "hw/usb.h"
#include "hw/usb/msd.h"
#include "desc.h"
#include "hw/qdev-properties.h"
#include "hw/scsi/scsi.h"
#include "scsi/constants.h"
#include "scsi/utils.h"
#include "migration/vmstate.h"
#include "qemu/cutils.h"
#include "qom/object.h"
#include "trace.h"

/* USB requests.  */
#define MassStorageReset  0xff
#define GetMaxLun         0xfe

struct usb_msd_cbw {
    uint32_t sig;
    uint32_t tag;
    uint32_t data_len;
    uint8_t flags;
    uint8_t lun;
    uint8_t cmd_len;
    uint8_t cmd[16];
};

/* pull the LBA out of a READ/WRITE CDB (10- and 16-byte). */
static uint64_t usb_msd_cbw_lba(const struct usb_msd_cbw *cbw)
{
    const uint8_t *cdb = cbw->cmd;
    uint64_t lba = 0;
    int i;

    switch (cdb[0]) {
    case 0x28:  /* READ(10) */
    case 0x2a:  /* WRITE(10) */
        lba = ((uint64_t)cdb[2] << 24) | ((uint64_t)cdb[3] << 16) |
              ((uint64_t)cdb[4] << 8) | cdb[5];
        break;
    case 0x88:  /* READ(16) */
    case 0x8a:  /* WRITE(16) */
        for (i = 2; i < 10; i++) {
            lba = (lba << 8) | cdb[i];
        }
        break;
    default:
        break;
    }
    return lba;
}

enum {
    STR_MANUFACTURER = 1,
    STR_PRODUCT,
    STR_SERIALNUMBER,
    STR_CONFIG_FULL,
    STR_CONFIG_HIGH,
    STR_CONFIG_SUPER,
};

static const USBDescStrings desc_strings = {
    [STR_MANUFACTURER] = "QEMU",
    [STR_PRODUCT]      = "QEMU USB HARDDRIVE",
    [STR_SERIALNUMBER] = "1",
    [STR_CONFIG_FULL]  = "Full speed config (usb 1.1)",
    [STR_CONFIG_HIGH]  = "High speed config (usb 2.0)",
    [STR_CONFIG_SUPER] = "Super speed config (usb 3.0)",
};

static const USBDescIface desc_iface_full = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 2,
    .bInterfaceClass               = USB_CLASS_MASS_STORAGE,
    .bInterfaceSubClass            = 0x06, /* SCSI */
    .bInterfaceProtocol            = 0x50, /* Bulk */
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_BULK,
            .wMaxPacketSize        = 64,
        },{
            .bEndpointAddress      = USB_DIR_OUT | 0x02,
            .bmAttributes          = USB_ENDPOINT_XFER_BULK,
            .wMaxPacketSize        = 64,
        },
    }
};

static const USBDescDevice desc_device_full = {
    .bcdUSB                        = 0x0200,
    .bMaxPacketSize0               = 8,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_FULL,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER,
            .nif = 1,
            .ifs = &desc_iface_full,
        },
    },
};

static const USBDescIface desc_iface_high = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 2,
    .bInterfaceClass               = USB_CLASS_MASS_STORAGE,
    .bInterfaceSubClass            = 0x06, /* SCSI */
    .bInterfaceProtocol            = 0x50, /* Bulk */
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_BULK,
            .wMaxPacketSize        = 512,
        },{
            .bEndpointAddress      = USB_DIR_OUT | 0x02,
            .bmAttributes          = USB_ENDPOINT_XFER_BULK,
            .wMaxPacketSize        = 512,
        },
    }
};

static const USBDescDevice desc_device_high = {
    .bcdUSB                        = 0x0200,
    .bMaxPacketSize0               = 64,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_HIGH,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER,
            .nif = 1,
            .ifs = &desc_iface_high,
        },
    },
};

static const USBDescIface desc_iface_super = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 2,
    .bInterfaceClass               = USB_CLASS_MASS_STORAGE,
    .bInterfaceSubClass            = 0x06, /* SCSI */
    .bInterfaceProtocol            = 0x50, /* Bulk */
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_BULK,
            .wMaxPacketSize        = 1024,
            .bMaxBurst             = 15,
        },{
            .bEndpointAddress      = USB_DIR_OUT | 0x02,
            .bmAttributes          = USB_ENDPOINT_XFER_BULK,
            .wMaxPacketSize        = 1024,
            .bMaxBurst             = 15,
        },
    }
};

static const USBDescDevice desc_device_super = {
    .bcdUSB                        = 0x0300,
    .bMaxPacketSize0               = 9,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_SUPER,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER,
            .nif = 1,
            .ifs = &desc_iface_super,
        },
    },
};

static const USBDesc desc = {
    .id = {
        .idVendor          = 0x46f4, /* CRC16() of "QEMU" */
        .idProduct         = 0x0001,
        .bcdDevice         = 0,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT,
        .iSerialNumber     = STR_SERIALNUMBER,
    },
    .full  = &desc_device_full,
    .high  = &desc_device_high,
    .super = &desc_device_super,
    .str   = desc_strings,
};

static void usb_msd_packet_complete(MSDState *s, int status)
{
    USBPacket *p = s->packet;

    /*
     * Set s->packet to NULL before calling usb_packet_complete
     * because another request may be issued before
     * usb_packet_complete returns.
     */
    trace_usb_msd_packet_complete();
    p->status = status;
    s->packet = NULL;
    usb_packet_complete(&s->dev, p);
}

/*
 * guest-armed media/power fault completion.  The command
 * is completed at the BOT layer WITHOUT SCSI dispatch (no block I/O),
 * so the BOT CSW carries the failure and the driver's REQUEST SENSE
 * sees the armed sense code.  For the flush-lie shape the CSW claims
 * success while the data is never persisted.
 */
static void usb_msd_fault_complete(MSDState *s, uint32_t tag, uint32_t lun,
                                   uint8_t *cdb, size_t cdb_len,
                                   SCSISense sense, bool good)
{
    SCSIDevice *scsi_dev = scsi_device_find(&s->bus, 0, 0, lun);

    if (!scsi_dev || s->req) {
        return;
    }
    (void)cdb;
    (void)cdb_len;
    s->csw.sig = cpu_to_le32(0x53425355);
    s->csw.tag = cpu_to_le32(tag);
    s->csw.residue = cpu_to_le32(s->data_len);
    s->csw.status = good ? 0 : 1;
    if (!good) {
        /* the sense is stored on the device for REQUEST SENSE */
        scsi_dev->sense_len = scsi_build_sense(scsi_dev->sense, sense);
    }
    s->mode = USB_MSDM_CSW;
}

static void usb_msd_fatal_error(MSDState *s)
{
    trace_usb_msd_fatal_error();

    if (s->packet) {
        usb_msd_packet_complete(s, USB_RET_STALL);
    }

    /*
     * Guest messed up up device state with illegal requests.  Go
     * ignore any requests until the guests resets the device (and
     * brings it into a known state that way).
     */
    s->needs_reset = true;
}

static void usb_msd_copy_data(MSDState *s, USBPacket *p)
{
    uint32_t len;
    len = p->iov.size - p->actual_length;
    if (len > s->scsi_len)
        len = s->scsi_len;
    usb_packet_copy(p, scsi_req_get_buf(s->req) + s->scsi_off, len);
    s->scsi_len -= len;
    s->scsi_off += len;
    if (len > s->data_len) {
        len = s->data_len;
    }
    s->data_len -= len;
    if (s->scsi_len == 0 || s->data_len == 0) {
        scsi_req_continue(s->req);
    }
}

static void usb_msd_send_status(MSDState *s, USBPacket *p)
{
    int len;

    trace_usb_msd_send_status(s->csw.status, le32_to_cpu(s->csw.tag),
                              p->iov.size);

    assert(s->csw.sig == cpu_to_le32(0x53425355));
    len = MIN(sizeof(s->csw), p->iov.size);
    usb_packet_copy(p, &s->csw, len);
    memset(&s->csw, 0, sizeof(s->csw));
}

void usb_msd_transfer_data(SCSIRequest *req, uint32_t len)
{
    MSDState *s = DO_UPCAST(MSDState, dev.qdev, req->bus->qbus.parent);
    USBPacket *p = s->packet;

    if ((s->mode == USB_MSDM_DATAOUT) != (req->cmd.mode == SCSI_XFER_TO_DEV)) {
        usb_msd_fatal_error(s);
        return;
    }

    s->scsi_len = len;
    s->scsi_off = 0;
    if (p) {
        usb_msd_copy_data(s, p);
        p = s->packet;
        if (p && p->actual_length == p->iov.size) {
            /* USB_RET_SUCCESS status clears previous ASYNC status */
            usb_msd_packet_complete(s, USB_RET_SUCCESS);
        }
    }
}

void usb_msd_command_complete(SCSIRequest *req, size_t resid)
{
    MSDState *s = DO_UPCAST(MSDState, dev.qdev, req->bus->qbus.parent);
    USBPacket *p = s->packet;

    trace_usb_msd_cmd_complete(req->status, req->tag);

    s->csw.sig = cpu_to_le32(0x53425355);
    s->csw.tag = cpu_to_le32(req->tag);
    s->csw.residue = cpu_to_le32(s->data_len);
    s->csw.status = req->status != 0;

    if (s->packet) {
        if (s->data_len == 0 && s->mode == USB_MSDM_DATAOUT) {
            /* A deferred packet with no write data remaining must be
               the status read packet.  */
            usb_msd_send_status(s, p);
            s->mode = USB_MSDM_CBW;
        } else if (s->mode == USB_MSDM_CSW) {
            usb_msd_send_status(s, p);
            s->mode = USB_MSDM_CBW;
        } else {
            if (s->data_len) {
                int len = (p->iov.size - p->actual_length);
                usb_packet_skip(p, len);
                if (len > s->data_len) {
                    len = s->data_len;
                }
                s->data_len -= len;
            }
            if (s->data_len == 0) {
                s->mode = USB_MSDM_CSW;
            }
        }
        /* USB_RET_SUCCESS status clears previous ASYNC status */
        usb_msd_packet_complete(s, USB_RET_SUCCESS);
    } else if (s->data_len == 0) {
        s->mode = USB_MSDM_CSW;
    }
    scsi_req_unref(req);
    s->req = NULL;
}

void usb_msd_request_cancelled(SCSIRequest *req)
{
    MSDState *s = DO_UPCAST(MSDState, dev.qdev, req->bus->qbus.parent);

    trace_usb_msd_cmd_cancel(req->tag);

    if (req == s->req) {
        s->csw.sig = cpu_to_le32(0x53425355);
        s->csw.tag = cpu_to_le32(req->tag);
        s->csw.status = 1; /* error */

        scsi_req_unref(s->req);
        s->req = NULL;
        s->scsi_len = 0;
    }
}

void usb_msd_handle_reset(USBDevice *dev)
{
    MSDState *s = (MSDState *)dev;

    trace_usb_msd_reset();
    if (s->req) {
        scsi_req_cancel(s->req);
    }
    assert(s->req == NULL);

    if (s->packet) {
        usb_msd_packet_complete(s, USB_RET_STALL);
    }

    memset(&s->csw, 0, sizeof(s->csw));
    s->mode = USB_MSDM_CBW;

    s->needs_reset = false;
}

static void usb_msd_handle_control(USBDevice *dev, USBPacket *p,
               int request, int value, int index, int length, uint8_t *data)
{
    MSDState *s = (MSDState *)dev;
    SCSIDevice *scsi_dev;
    int ret, maxlun;

    ret = usb_desc_handle_control(dev, p, request, value, index, length, data);
    if (ret >= 0) {
        return;
    }

    switch (request) {
    case VendorDeviceOutRequest | 0x57:
        /* guest-only arm: eject at the armed LBA */
        if (s->nto64_eject_lba != 0) {
            s->nto64_eject_armed = true;
        }
        break;
    case VendorDeviceOutRequest | 0x58:
        /* guest-only arm: write protect */
        if (s->nto64_wp) {
            s->nto64_wp_armed = true;
        }
        break;
    case VendorDeviceRequest | 0x59:
        /*
         * report which guest-armed hooks are
         * LIVE (the harness distinguishes a clean target from a fault
         * target: the arm requests are accepted by every device, so a
         * status byte is the only reliable signal).
         */
        data[0] = (s->nto64_eject_armed ? 0x01 : 0) |
                  (s->nto64_wp_armed ? 0x02 : 0);
        p->actual_length = MIN(length, 1);
        break;
    case VendorDeviceOutRequest | 0x5a:
        /*
         * guest-only arm for the eject DURING an
         * in-flight transfer (the READ at the armed LBA starts, then
         * the device detaches mid-transfer and replugs).
         */
        if (s->nto64_eject_inflight_lba != 0) {
            s->nto64_eject_inflight_armed = true;
        }
        break;
    case VendorDeviceOutRequest | 0x5a:
        /*
         * guest-only arm for the eject DURING an
         * in-flight transfer (the READ at the armed LBA starts, then
         * the device detaches mid-transfer and replugs).
         */
        if (s->nto64_eject_inflight_lba != 0) {
            s->nto64_eject_inflight_armed = true;
        }
        break;
    case EndpointOutRequest | USB_REQ_CLEAR_FEATURE:
        break;
        /* Class specific requests.  */
    case ClassInterfaceOutRequest | MassStorageReset:
        /* Reset state ready for the next CBW.  */
        s->mode = USB_MSDM_CBW;
        break;
    case ClassInterfaceRequest | GetMaxLun:
        maxlun = 0;
        for (;;) {
            scsi_dev = scsi_device_find(&s->bus, 0, 0, maxlun+1);
            if (scsi_dev == NULL) {
                break;
            }
            if (scsi_dev->lun != maxlun+1) {
                break;
            }
            maxlun++;
        }
        trace_usb_msd_maxlun(maxlun);
        data[0] = maxlun;
        p->actual_length = 1;
        break;
    default:
        p->status = USB_RET_STALL;
        break;
    }
}

static void usb_msd_cancel_io(USBDevice *dev, USBPacket *p)
{
    MSDState *s = USB_STORAGE_DEV(dev);

    assert(s->packet == p);
    s->packet = NULL;

    if (s->req) {
        scsi_req_cancel(s->req);
    }
}

static void usb_msd_handle_data(USBDevice *dev, USBPacket *p)
{
    MSDState *s = (MSDState *)dev;
    uint32_t tag;
    struct usb_msd_cbw cbw;
    uint8_t devep = p->ep->nr;
    SCSIDevice *scsi_dev;
    int len;

    if (s->needs_reset) {
        p->status = USB_RET_STALL;
        return;
    }

    switch (p->pid) {
    case USB_TOKEN_OUT:
        if (devep != 2)
            goto fail;

        switch (s->mode) {
        case USB_MSDM_CBW:
            if (p->iov.size != 31) {
                error_report("usb-msd: Bad CBW size");
                goto fail;
            }
            usb_packet_copy(p, &cbw, 31);
            if (le32_to_cpu(cbw.sig) != 0x43425355) {
                error_report("usb-msd: Bad signature %08x",
                             le32_to_cpu(cbw.sig));
                goto fail;
            }
            scsi_dev = scsi_device_find(&s->bus, 0, 0, cbw.lun);
            if (scsi_dev == NULL) {
                error_report("usb-msd: Bad LUN %d", cbw.lun);
                goto fail;
            }
            tag = le32_to_cpu(cbw.tag);
            s->data_len = le32_to_cpu(cbw.data_len);
            if (s->data_len == 0) {
                s->mode = USB_MSDM_CSW;
            } else if (cbw.flags & 0x80) {
                s->mode = USB_MSDM_DATAIN;
            } else {
                s->mode = USB_MSDM_DATAOUT;
            }
            trace_usb_msd_cmd_submit(cbw.lun, tag, cbw.flags,
                                     cbw.cmd_len, s->data_len);
            assert(le32_to_cpu(s->csw.residue) == 0);
            s->scsi_len = 0;
            /*
             * guest-armed media/power faults.  These are
             * armed ONLY by guest vendor requests (0x57/0x58), so BIOS
             * boot traffic can never consume them.  The fault completes
             * the command with a synthetic sense (or a lying GOOD) and
             * skips the real SCSI dispatch.
             */
            if (s->nto64_eject_armed && cbw.cmd[0] == 0x28 &&
                usb_msd_cbw_lba(&cbw) == s->nto64_eject_lba) {
                s->nto64_eject_armed = false;
                usb_msd_fault_complete(s, tag, cbw.lun, cbw.cmd, cbw.cmd_len,
                                       SENSE_CODE(NO_MEDIUM), false);
                scsi_device_set_ua(scsi_dev, SENSE_CODE(MEDIUM_CHANGED));
                break;
            }
            if (s->nto64_wp_armed &&
                (cbw.cmd[0] == 0x2a || cbw.cmd[0] == 0x8a)) {
                s->nto64_wp_armed = false;
                usb_msd_fault_complete(s, tag, cbw.lun, cbw.cmd, cbw.cmd_len,
                                       SENSE_CODE(WRITE_PROTECTED), false);
                break;
            }
            if (s->nto64_eject_inflight_armed && cbw.cmd[0] == 0x28 &&
                usb_msd_cbw_lba(&cbw) == s->nto64_eject_inflight_lba) {
                /*
                 * eject DURING the transfer: the CBW is accepted, the
                 * data phase begins, then the device detaches
                 * mid-flight (the in-flight packet is held ASYNC and
                 * the disconnect timer fires ~1 ms later), so the
                 * transfer dies with no completion.  The replug timer
                 * re-attaches the device and the driver re-enumerates.
                 */
                s->nto64_eject_inflight_armed = false;
                s->nto64_inflight_pending = true;
                s->data_len = le32_to_cpu(cbw.data_len);
                s->mode = USB_MSDM_DATAIN;
                break;
            }
            if (s->nto64_eject_inflight_armed && cbw.cmd[0] == 0x28 &&
                usb_msd_cbw_lba(&cbw) == s->nto64_eject_inflight_lba) {
                /*
                 * eject DURING the transfer: the CBW is accepted, the
                 * data phase begins, then the device detaches
                 * mid-flight (the in-flight packet is held ASYNC and
                 * the disconnect timer fires ~1 ms later), so the
                 * transfer dies with no completion.  The replug timer
                 * re-attaches the device and the driver re-enumerates.
                 */
                s->nto64_eject_inflight_armed = false;
                s->nto64_inflight_pending = true;
                s->data_len = le32_to_cpu(cbw.data_len);
                s->mode = USB_MSDM_DATAIN;
                break;
            }
            /*
             * arm the one-shot USB faults on LBA match.  Only
             * READ CDBs match: the harness pre-fills the pattern with a
             * WRITE to the same LBA, which must not consume the fault.
             */
            if (cbw.cmd[0] != 0x28 && cbw.cmd[0] != 0x88) {
                goto no_fault;
            }
            if (s->nto64_stall_lba &&
                usb_msd_cbw_lba(&cbw) == s->nto64_stall_lba) {
                s->nto64_stall_lba = 0;
                s->nto64_stall_pending = true;
            }
            if (s->nto64_drop_lba &&
                usb_msd_cbw_lba(&cbw) == s->nto64_drop_lba) {
                s->nto64_drop_lba = 0;
                s->nto64_drop_pending = true;
            }
no_fault:
            s->req = scsi_req_new(scsi_dev, tag, cbw.lun, cbw.cmd, cbw.cmd_len, NULL);
            if (s->commandlog) {
                scsi_req_print(s->req);
            }
            len = scsi_req_enqueue(s->req);
            if (len) {
                scsi_req_continue(s->req);
            }
            break;

        case USB_MSDM_CSW:
            /*
             * after a CBW-time media/power fault the
             * device is already in CSW mode; swallow the data the
             * host still sends (the fault "completed" the command
             * before the data phase) so the CSW read succeeds.
             */
            usb_packet_skip(p, p->iov.size);
            p->actual_length = p->iov.size;
            break;

        case USB_MSDM_DATAOUT:
            /* one-shot stall of the data phase. */
            if (s->nto64_stall_pending) {
                s->nto64_stall_pending = false;
                p->status = USB_RET_STALL;
                break;
            }
            trace_usb_msd_data_out(p->iov.size, s->data_len);
            if (p->iov.size > s->data_len) {
                goto fail;
            }

            if (s->scsi_len) {
                usb_msd_copy_data(s, p);
            }
            if (le32_to_cpu(s->csw.residue)) {
                len = p->iov.size - p->actual_length;
                if (len) {
                    usb_packet_skip(p, len);
                    if (len > s->data_len) {
                        len = s->data_len;
                    }
                    s->data_len -= len;
                    if (s->data_len == 0) {
                        s->mode = USB_MSDM_CSW;
                    }
                }
            }
            if (p->actual_length < p->iov.size) {
                trace_usb_msd_packet_async();
                s->packet = p;
                p->status = USB_RET_ASYNC;
            }
            break;

        default:
            goto fail;
        }
        break;

    case USB_TOKEN_IN:
        if (devep != 1)
            goto fail;

        switch (s->mode) {
        case USB_MSDM_DATAOUT:
            if (s->data_len != 0 || p->iov.size < 13) {
                goto fail;
            }
            /* Waiting for SCSI write to complete.  */
            trace_usb_msd_packet_async();
            s->packet = p;
            p->status = USB_RET_ASYNC;
            break;

        case USB_MSDM_CSW:
            if (p->iov.size < 13) {
                goto fail;
            }

            /*
             * one-shot dropped CSW - the status read never
             * completes, so the guest must time it out and run BOT
             * reset recovery.
             */
            if (s->nto64_drop_pending) {
                s->nto64_drop_pending = false;
                s->packet = p;
                p->status = USB_RET_ASYNC;
                break;
            }

            if (s->req) {
                /* still in flight */
                trace_usb_msd_packet_async();
                s->packet = p;
                p->status = USB_RET_ASYNC;
            } else {
                usb_msd_send_status(s, p);
                s->mode = USB_MSDM_CBW;
            }
            break;

        case USB_MSDM_DATAIN:
            /* one-shot stall of the data phase. */
            if (s->nto64_stall_pending) {
                s->nto64_stall_pending = false;
                p->status = USB_RET_STALL;
                break;
            }
            /*
             * eject-during-in-flight - hold the
             * data phase ASYNC and detach ~1 ms later, so the
             * in-flight transfer is nuked by the controller with no
             * completion event.
             */
            if (s->nto64_inflight_pending) {
                s->nto64_inflight_pending = false;
                p->status = USB_RET_ASYNC;
                usb_packet_set_state(p, USB_PACKET_ASYNC);
                s->packet = p;
                timer_mod(s->disconnect_timer,
                          qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 1000000);
                return;
            }
            /*
             * eject-during-in-flight - hold the
             * data phase ASYNC and detach ~1 ms later, so the
             * in-flight transfer is nuked by the controller with no
             * completion event.
             */
            if (s->nto64_inflight_pending) {
                s->nto64_inflight_pending = false;
                p->status = USB_RET_ASYNC;
                usb_packet_set_state(p, USB_PACKET_ASYNC);
                s->packet = p;
                timer_mod(s->disconnect_timer,
                          qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 1000000);
                return;
            }
            trace_usb_msd_data_in(p->iov.size, s->data_len, s->scsi_len);
            if (s->scsi_len) {
                usb_msd_copy_data(s, p);
            }
            if (le32_to_cpu(s->csw.residue)) {
                len = p->iov.size - p->actual_length;
                if (len) {
                    usb_packet_skip(p, len);
                    if (len > s->data_len) {
                        len = s->data_len;
                    }
                    s->data_len -= len;
                    if (s->data_len == 0) {
                        s->mode = USB_MSDM_CSW;
                    }
                }
            }
            if (p->actual_length < p->iov.size && s->mode == USB_MSDM_DATAIN) {
                trace_usb_msd_packet_async();
                s->packet = p;
                p->status = USB_RET_ASYNC;
            }
            break;

        default:
            goto fail;
        }
        break;

    default:
    fail:
        p->status = USB_RET_STALL;
        break;
    }
}

void *usb_msd_load_request(QEMUFile *f, SCSIRequest *req)
{
    MSDState *s = DO_UPCAST(MSDState, dev.qdev, req->bus->qbus.parent);

    /* nothing to load, just store req in our state struct */
    assert(s->req == NULL);
    scsi_req_ref(req);
    s->req = req;
    return NULL;
}

static const VMStateDescription vmstate_usb_msd = {
    .name = "usb-storage",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_USB_DEVICE(dev, MSDState),
        VMSTATE_UINT32(mode, MSDState),
        VMSTATE_UINT32(scsi_len, MSDState),
        VMSTATE_UINT32(scsi_off, MSDState),
        VMSTATE_UINT32(data_len, MSDState),
        VMSTATE_UINT32(csw.sig, MSDState),
        VMSTATE_UINT32(csw.tag, MSDState),
        VMSTATE_UINT32(csw.residue, MSDState),
        VMSTATE_UINT8(csw.status, MSDState),
        VMSTATE_END_OF_LIST()
    }
};

static void usb_msd_class_initfn_common(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->product_desc   = "QEMU USB MSD";
    uc->usb_desc       = &desc;
    uc->cancel_packet  = usb_msd_cancel_io;
    uc->handle_attach  = usb_desc_attach;
    uc->handle_reset   = usb_msd_handle_reset;
    uc->handle_control = usb_msd_handle_control;
    uc->handle_data    = usb_msd_handle_data;
    set_bit(DEVICE_CATEGORY_STORAGE, dc->categories);
    dc->fw_name = "storage";
    dc->vmsd = &vmstate_usb_msd;
}

static const TypeInfo usb_storage_dev_type_info = {
    .name = TYPE_USB_STORAGE,
    .parent = TYPE_USB_DEVICE,
    .instance_size = sizeof(MSDState),
    .abstract = true,
    .class_init = usb_msd_class_initfn_common,
};

static void usb_msd_register_types(void)
{
    type_register_static(&usb_storage_dev_type_info);
}

type_init(usb_msd_register_types)
