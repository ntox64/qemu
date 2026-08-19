/* SPDX-License-Identifier: BSD-2-Clause */

/*
 * usb-nto64: configurable USB device for the nto64 attach-storm /
 * enumeration-fault harness.
 *
 * A minimal control-only full-speed device whose bMaxPower comes from
 * the `power-ma` property (2 mA units), so a guest driver can exercise
 * its power-budget check against an over-budget device (e.g.
 * power-ma=600 on a 500 mA budget).  The fault properties model the
 * enumeration cases a real devu-* driver must survive:
 *   bad-desc     - the device descriptor returns garbage words
 *   no-config    - GET_DESCRIPTOR(CONFIG) stalls
 *   stall-config - SET_CONFIGURATION stalls
 *   reset-hang   - the device NAKs every control request (never takes
 *                  an address): the driver's reset/enumeration times
 *                  out and must recover by resetting the port.
 * This testbed adds the composite shape: with `nto64-composite=on`
 * single configuration carries two vendor interfaces, each with a
 * 64-byte bulk OUT + bulk IN echo pair (the guest writes a pattern
 * and reads it back to prove the function is alive).  `nto64-kill-
 * iface=N` makes interface N's endpoints STALL every transfer - the
 * dead function a composite driver must mask while the other
 * interface keeps working.
 * This testbed adds the mid-transfer disconnect shape: with
 * `nto64-disconnect=on` (+ `nto64-replug-ms=M`) a guest-only vendor
 * request (0x56) arms the device; the next data transfer starts
 * (a partial chunk is copied) but the device VANISHES mid-transfer
 * (the packet is held in flight and the device detaches after ~1 ms,
 * so the xHCI nukes the outstanding URB with no completion event),
 * then re-attaches after M ms.  A driver that bounds its transfer
 * wait, notices the port disconnect, tears the slot down and
 * re-enumerates after the replug survives.
 * adds the isochronous shape: with `nto64-isoc=on`
 * the device presents a single vendor interface with one isoc IN
 * endpoint (interval 1, 64-byte packets) and a bulk OUT arming
 * endpoint.  `nto64-drop-microframe=1` + a guest-only vendor request
 * (0x57) arms a one-shot missed service interval: the Nth isoc
 * transfer NAKs once, so the xHCI services it at the NEXT interval
 * and the driver sees no transfer event for one interval (the isoc
 * stream must not wedge).
 *
 */

#include "qemu/osdep.h"
#include "qemu/module.h"
#include "qemu/error-report.h"
#include "qemu/timer.h"
#include "hw/usb.h"
#include "hw/usb/desc.h"
#include "hw/qdev-properties.h"
#include "qom/object.h"

#define TYPE_USB_NTO64 "usb-nto64"
OBJECT_DECLARE_SIMPLE_TYPE(Nto64UsbState, USB_NTO64)

struct Nto64UsbState {
    USBDevice dev;
    uint32_t power_ma;
    bool bad_desc;
    bool no_config;
    bool stall_config;
    bool reset_hang;
    bool composite;
    int32_t kill_iface;
    uint8_t config_value;
    uint8_t data_iface[2][64];
    uint32_t io_count[2];
    /* mid-transfer disconnect (vendor-armed, one-shot) */
    bool disconnect;
    uint32_t replug_ms;
    bool disconnect_armed;
    bool disconnect_done;
    QEMUTimer *disconnect_timer;
    QEMUTimer *replug_timer;
    /* isoc missed-microframe shape */
    bool isoc;
    uint32_t drop_microframe;
    uint32_t drop_microframe_left;
    bool drop_microframe_armed;
    uint32_t isoc_count;
    uint8_t isoc_buf[64];
};

enum {
    STR_MANUFACTURER = 1,
    STR_PRODUCT,
};

static const USBDescStrings desc_strings = {
    [STR_MANUFACTURER] = "QEMU",
    [STR_PRODUCT]      = "nto64 test device",
};

static const USBDescDevice desc_device_nto64 = {
    .bcdUSB                        = 0x0100,
    .bDeviceClass                  = 0xff,   /* vendor specific */
    .bMaxPacketSize0               = 8,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 0,
            .bConfigurationValue   = 1,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER,
            .bMaxPower             = 50,     /* 100 mA; patched at realize */
        },
    },
};

static const USBDesc desc_nto64 = {
    .id = {
        .idVendor          = 0x1234,
        .idProduct         = 0x1eeb,
        .bcdDevice         = 0x0001,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT,
    },
    .full = &desc_device_nto64,
    .str  = desc_strings,
};

static void nto64_usb_handle_control(USBDevice *dev, USBPacket *p,
                                     int request, int value, int index,
                                     int length, uint8_t *data)
{
    Nto64UsbState *s = USB_NTO64(dev);

    if (s->reset_hang &&
        request != (DeviceRequest | USB_REQ_GET_STATUS)) {
        /*
         * the hung device never responds to enumeration: NAK so the
         * driver's control-transfer timeout fires
         */
        p->status = USB_RET_NAK;
        return;
    }

    switch (request) {
    case DeviceOutRequest | USB_REQ_SET_ADDRESS:
        dev->addr = value;
        break;
    case DeviceRequest | USB_REQ_GET_DESCRIPTOR:
        switch (value >> 8) {
        case USB_DT_DEVICE:
            if (s->bad_desc) {
                memset(data, 0xee, MIN(length, 18));
            } else {
                uint8_t d[18] = {
                    18, USB_DT_DEVICE,
                    0x00, 0x01,               /* bcdUSB 1.00 */
                    0xff,                     /* bDeviceClass: vendor */
                    0x00, 0x00, 0x08,         /* sub/proto, maxpacket0 */
                    0x34, 0x12, 0xeb, 0x1e,   /* idVendor/idProduct */
                    0x01, 0x00,               /* bcdDevice */
                    STR_MANUFACTURER, STR_PRODUCT,
                    0x00, 0x01,               /* iSerial, bNumConfigs */
                };
                memcpy(data, d, MIN(length, sizeof(d)));
            }
            p->actual_length = MIN(length, 18);
            break;
        case USB_DT_CONFIG:
            if (s->no_config) {
                p->status = USB_RET_STALL;
                break;
            } else {
                if (s->isoc) {
                    /*
                     * one vendor interface: isoc IN (ep 1) + bulk OUT
                     * (ep 2, the arming/echo channel)
                     */
                    uint8_t c[32] = {
                        9, USB_DT_CONFIG,
                        32, 0,                /* wTotalLength */
                        1, 1, 0,              /* nIfaces, bConfigValue */
                        USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER,
                        (uint8_t)MIN(s->power_ma / 2, 255),
                        9, USB_DT_INTERFACE, 0, 0, 2, 0xff, 0, 0, 0,
                        7, USB_DT_ENDPOINT, 0x81, 1, 64, 0, 1,
                        7, USB_DT_ENDPOINT, 0x02, 2, 64, 0, 0,
                    };
                    memcpy(data, c, MIN(length, sizeof(c)));
                    p->actual_length = MIN(length, sizeof(c));
                } else if (s->composite) {
                    /* two vendor interfaces, 64-byte bulk echo pairs */
                    uint8_t c[55] = {
                        9, USB_DT_CONFIG,
                        55, 0,                /* wTotalLength */
                        2, 1, 0,              /* nIfaces, bConfigValue, iConfig */
                        USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER,
                        (uint8_t)MIN(s->power_ma / 2, 255),
                        9, USB_DT_INTERFACE, 0, 0, 2, 0xff, 0, 0, 0,
                        7, USB_DT_ENDPOINT, 0x01, 2, 64, 0, 0,
                        7, USB_DT_ENDPOINT, 0x81, 2, 64, 0, 0,
                        9, USB_DT_INTERFACE, 1, 0, 2, 0xff, 0, 0, 0,
                        7, USB_DT_ENDPOINT, 0x02, 2, 64, 0, 0,
                        7, USB_DT_ENDPOINT, 0x82, 2, 64, 0, 0,
                    };
                    memcpy(data, c, MIN(length, sizeof(c)));
                    p->actual_length = MIN(length, sizeof(c));
                } else {
                    uint8_t c[9] = {
                        9, USB_DT_CONFIG,
                        9, 0,                 /* wTotalLength */
                        1, 1, 0,              /* nIfaces, bConfigValue, iConfig */
                        USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER,
                        (uint8_t)MIN(s->power_ma / 2, 255),
                    };
                    memcpy(data, c, MIN(length, sizeof(c)));
                    p->actual_length = MIN(length, sizeof(c));
                }
            }
            break;
        default:
            p->status = USB_RET_STALL;
            break;
        }
        break;
    case DeviceOutRequest | USB_REQ_SET_CONFIGURATION:
        if (s->stall_config) {
            p->status = USB_RET_STALL;
        } else {
            s->config_value = value & 0xff;
        }
        break;
    case DeviceRequest | USB_REQ_GET_CONFIGURATION:
        data[0] = s->config_value;
        p->actual_length = 1;
        break;
    case DeviceRequest | USB_REQ_GET_STATUS:
        data[0] = 1;                 /* self-powered */
        data[1] = 0;
        p->actual_length = MIN(length, 2);
        break;
    case VendorDeviceOutRequest | 0x56:
        /*
         * arm the mid-transfer disconnect (guest-only; the
         * no-op reply keeps the harness phase uniform on clean
         * targets where the hook is off).
         */
        if (s->disconnect && !s->disconnect_done) {
            s->disconnect_armed = true;
        }
        break;
    case VendorDeviceOutRequest | 0x57:
        /*
         * arm the isoc missed-microframe (guest-
         * only; no-op on clean targets).
         */
        if (s->isoc && s->drop_microframe &&
            s->drop_microframe_left > 0) {
            s->drop_microframe_armed = true;
        }
        break;
    case VendorDeviceRequest | 0x58:
        /*
         * report whether the drop is armed, so the
         * harness can distinguish the clean stream (0 gaps expected)
         * from the drop target (1 gap expected).
         */
        data[0] = s->drop_microframe_armed ? 1 : 0;
        p->actual_length = MIN(length, 1);
        break;
    default:
        p->status = USB_RET_STALL;
        break;
    }
}

/*
 * the device vanishes mid-transfer - the in-flight packet is
 * nuked by the controller's detach path (no completion event) and the
 * port shows a disconnect; a replug timer brings the device back.
 */
static void nto64_usb_disconnect_cb(void *opaque)
{
    Nto64UsbState *s = opaque;

    usb_device_detach(USB_DEVICE(s));
    if (s->replug_ms > 0) {
        timer_mod(s->replug_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                  s->replug_ms * 1000000ULL);
    }
}

static void nto64_usb_replug_cb(void *opaque)
{
    Nto64UsbState *s = opaque;
    USBDevice *dev = USB_DEVICE(s);
    Error *err = NULL;

    /* fresh state for re-enumeration */
    dev->addr = 0;
    dev->state = USB_STATE_NOTATTACHED;
    dev->remote_wakeup = 0;
    s->config_value = 0;
    memset(s->data_iface, 0, sizeof(s->data_iface));
    memset(s->io_count, 0, sizeof(s->io_count));
    s->disconnect_armed = false;
    s->disconnect_done = false;
    if (s->isoc) {
        s->drop_microframe_left = s->drop_microframe;
        s->drop_microframe_armed = false;
    }
    usb_device_attach(dev, &err);
    if (err) {
        error_report_err(err);
    }
}

/*
 * nto64_usb_handle_data: composite bulk echo.  Each interface latches
 * the last OUT payload and returns it on IN; a killed interface STALLs
 * every transfer (the dead function).
 */
static void nto64_usb_handle_data(USBDevice *dev, USBPacket *p)
{
    Nto64UsbState *s = USB_NTO64(dev);
    int iface;

    if (s->isoc) {
        if (p->pid == USB_TOKEN_IN && p->ep->nr == 1) {
            if (s->drop_microframe_armed) {
                s->drop_microframe_armed = false;
                s->drop_microframe_left--;
                /*
                 * missed service: NAK the Nth isoc transfer once.
                 * The xHCI re-arms the retry for the next service
                 * interval, so the transfer completes one interval
                 * late with full data and the stream must not wedge.
                 */
                p->status = USB_RET_NAK;
                return;
            }
            s->isoc_count++;
            memset(s->isoc_buf, s->isoc_count & 0xff, sizeof(s->isoc_buf));
            usb_packet_copy(p, s->isoc_buf, MIN(p->iov.size, 64));
            p->actual_length = MIN(p->iov.size, 64);
            return;
        }
        if (p->pid == USB_TOKEN_OUT && p->ep->nr == 2) {
            /* bulk OUT echo (arming channel) */
            usb_packet_copy(p, s->data_iface[0], MIN(p->iov.size, 64));
            p->actual_length = MIN(p->iov.size, 64);
            s->io_count[0]++;
            return;
        }
        p->status = USB_RET_STALL;
        return;
    }
    if (!s->composite) {
        p->status = USB_RET_STALL;
        return;
    }
    iface = p->ep->nr - 1;
    if (iface < 0 || iface > 1) {
        p->status = USB_RET_STALL;
        return;
    }
    if (s->kill_iface == iface) {
        p->status = USB_RET_STALL;
        return;
    }
    if (s->disconnect_armed) {
        /*
         * the armed transfer starts (partial data copied)
         * but the device disappears mid-transfer: hold the packet in
         * flight and detach after ~1 ms, so the transfer never
         * completes and the port disconnect is observable.
         */
        s->disconnect_armed = false;
        s->disconnect_done = true;
        usb_packet_copy(p, s->data_iface[iface], MIN(8, p->iov.size));
        p->actual_length = MIN(8, p->iov.size);
        p->status = USB_RET_ASYNC;
        timer_mod(s->disconnect_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 1000000);
        return;
    }
    usb_packet_copy(p, s->data_iface[iface], MIN(p->iov.size, 64));
    p->actual_length = MIN(p->iov.size, 64);
    s->io_count[iface]++;
}

static void nto64_usb_realize(USBDevice *dev, Error **errp)
{
    Nto64UsbState *s = USB_NTO64(dev);

    usb_desc_init(dev);
    usb_desc_attach(dev);
    if (s->power_ma == 0 || s->power_ma > 1000) {
        error_setg(errp, "usb-nto64: power-ma must be 1..1000");
        return;
    }
    info_report("usb-nto64: attached (power %u mA, bad-desc %d, "
                "no-config %d, stall-config %d, reset-hang %d, "
                "composite %d, kill-iface %d)",
                s->power_ma, s->bad_desc, s->no_config,
                s->stall_config, s->reset_hang, s->composite,
                s->kill_iface);
    if (s->composite) {
        usb_ep_get(dev, USB_TOKEN_OUT, 1);
        usb_ep_get(dev, USB_TOKEN_IN, 1);
        usb_ep_get(dev, USB_TOKEN_OUT, 2);
        usb_ep_get(dev, USB_TOKEN_IN, 2);
    } else if (s->isoc) {
        usb_ep_get(dev, USB_TOKEN_IN, 1);
        usb_ep_get(dev, USB_TOKEN_OUT, 2);
        s->drop_microframe_left = s->drop_microframe;
    }
    s->disconnect_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                       nto64_usb_disconnect_cb, s);
    s->replug_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                   nto64_usb_replug_cb, s);
}

static void nto64_usb_unrealize(USBDevice *dev)
{
    Nto64UsbState *s = USB_NTO64(dev);

    timer_free(s->disconnect_timer);
    timer_free(s->replug_timer);
}

static const Property nto64_usb_properties[] = {
    DEFINE_PROP_UINT32("power-ma", Nto64UsbState, power_ma, 100),
    DEFINE_PROP_BOOL("bad-desc", Nto64UsbState, bad_desc, false),
    DEFINE_PROP_BOOL("no-config", Nto64UsbState, no_config, false),
    DEFINE_PROP_BOOL("stall-config", Nto64UsbState, stall_config, false),
    DEFINE_PROP_BOOL("reset-hang", Nto64UsbState, reset_hang, false),
    DEFINE_PROP_BOOL("composite", Nto64UsbState, composite, false),
    DEFINE_PROP_INT32("kill-iface", Nto64UsbState, kill_iface, -1),
    DEFINE_PROP_BOOL("nto64-disconnect", Nto64UsbState, disconnect, false),
    DEFINE_PROP_UINT32("nto64-replug-ms", Nto64UsbState, replug_ms, 2000),
    DEFINE_PROP_BOOL("nto64-isoc", Nto64UsbState, isoc, false),
    DEFINE_PROP_UINT32("nto64-drop-microframe", Nto64UsbState,
                       drop_microframe, 0),
};

static void nto64_usb_class_init(ObjectClass *klass, const void *data)
{
    USBDeviceClass *k = USB_DEVICE_CLASS(klass);
    DeviceClass *dc = DEVICE_CLASS(klass);

    (void)data;
    k->realize = nto64_usb_realize;
    k->unrealize = nto64_usb_unrealize;
    k->handle_control = nto64_usb_handle_control;
    k->handle_data = nto64_usb_handle_data;
    k->usb_desc = &desc_nto64;
    k->product_desc = "nto64 test device";
    device_class_set_props(dc, nto64_usb_properties);
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);
}

static const TypeInfo nto64_usb_info = {
    .name = TYPE_USB_NTO64,
    .parent = TYPE_USB_DEVICE,
    .instance_size = sizeof(Nto64UsbState),
    .class_init = nto64_usb_class_init,
};

static void nto64_usb_register_types(void)
{
    type_register_static(&nto64_usb_info);
}

type_init(nto64_usb_register_types)
