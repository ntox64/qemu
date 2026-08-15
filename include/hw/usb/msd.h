/*
 * USB Mass Storage Device emulation
 *
 * Copyright (c) 2006 CodeSourcery.
 * Written by Paul Brook
 *
 * This code is licensed under the LGPL.
 */

#include "hw/usb.h"
#include "hw/scsi/scsi.h"

enum USBMSDMode {
    USB_MSDM_CBW, /* Command Block.  */
    USB_MSDM_DATAOUT, /* Transfer data to device.  */
    USB_MSDM_DATAIN, /* Transfer data from device.  */
    USB_MSDM_CSW /* Command Status.  */
};

struct QEMU_PACKED usb_msd_csw {
    uint32_t sig;
    uint32_t tag;
    uint32_t residue;
    uint8_t status;
};

struct MSDState {
    USBDevice dev;
    enum USBMSDMode mode;
    uint32_t scsi_off;
    uint32_t scsi_len;
    uint32_t data_len;
    struct usb_msd_csw csw;
    SCSIRequest *req;
    SCSIBus bus;
    /* For async completion.  */
    USBPacket *packet;
    /* fault injection (one-shot each). */
    /*
     * data phase of the command at this LBA returns STALL once (endpoint halts)
     */
    uint64_t nto64_stall_lba;
    bool     nto64_stall_pending;
    /*
     * the CSW of the command at this LBA is dropped once (never completes)
     */
    uint64_t nto64_drop_lba;
    bool     nto64_drop_pending;
    /* media / power shapes (all guest-armed, one-shot). */
    /*
     * the next READ at this LBA reports NOT READY / MEDIUM NOT PRESENT and a
     * media-change UA follows (re-read works)
     */
    uint64_t nto64_eject_lba;
    bool     nto64_eject_armed;
    /*
     * the next WRITE reports WRITE PROTECTED (data phase never reaches the
     * backend)
     */
    bool     nto64_wp;
    bool     nto64_wp_armed;
    /*
     * a READ at this LBA starts, then the device detaches mid-transfer (replug)
     */
    uint64_t nto64_eject_inflight_lba;
    bool     nto64_eject_inflight_armed;
    /*
     * the data phase holds the packet until the detach
     */
    bool     nto64_inflight_pending;
    /*
     * SYNCHRONIZE CACHE reports success while armed writes are NOT persisted; a
     * vendor replug (0x56) simulates the power loss.  The write-lie is armed
     * by a guest vendor request (0x5b), so the harness can prefill a pattern
     * BEFORE the lie is active and prove it survives the replug.
     */
    bool     nto64_flush_lie;
    bool     nto64_flush_armed;
    bool     nto64_replug_armed;
    uint32_t nto64_replug_ms;
    QEMUTimer *disconnect_timer;
    QEMUTimer *replug_timer;
    bool     nto64_disconnect; /* vendor 0x56 arms a mid-transfer replug */
    /* usb-storage only */
    BlockConf conf;
    bool removable;
    bool commandlog;
    SCSIDevice *scsi_dev;
    bool needs_reset;
};

typedef struct MSDState MSDState;
#define TYPE_USB_STORAGE "usb-storage-dev"
DECLARE_INSTANCE_CHECKER(MSDState, USB_STORAGE_DEV,
                         TYPE_USB_STORAGE)

void usb_msd_transfer_data(SCSIRequest *req, uint32_t len);
void usb_msd_command_complete(SCSIRequest *req, size_t resid);
void usb_msd_request_cancelled(SCSIRequest *req);
void *usb_msd_load_request(QEMUFile *f, SCSIRequest *req);
void usb_msd_handle_reset(USBDevice *dev);
void usb_msd_disconnect_cb(void *opaque);
void usb_msd_replug_cb(void *opaque);
