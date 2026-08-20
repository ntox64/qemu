/*
 * QEMU USB HUB emulation
 *
 * Copyright (c) 2005 Fabrice Bellard
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/timer.h"
#include "trace.h"
#include "hw/qdev-properties.h"
#include "hw/usb.h"
#include "migration/vmstate.h"
#include "desc.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qom/object.h"

#define MAX_PORTS 8

typedef struct USBHubPort {
    USBPort port;
    uint16_t wPortStatus;
    uint16_t wPortChange;
} USBHubPort;

struct USBHubState {
    USBDevice dev;
    USBEndpoint *intr;
    uint32_t num_ports;
    uint32_t oc_port;       /* port reporting over-current (0=none) */
    bool oc_active;         /* over-current condition present */
    /*
     * over-current misbehaviour modes (a hub that breaks the
     * USB 2.0 change-bit / power-switching model in each axis).
     */
    bool oc_edge;           /* edge-triggered change bit (spec) - off = chatty */
    bool oc_persistent;     /* OC survives a port power cycle (broken hub) */
    bool oc_status;         /* report the OVERCURRENT status bit */
    bool oc_change;         /* report the C_OVERCURRENT change bit */
    uint32_t oc_self_clear_reads; /* OC self-clears after N status reads */
    uint32_t oc_reads;
    /* downstream-port connect/disconnect storm */
    bool port_storm;        /* nto64-port-storm=on */
    uint32_t storm_port;    /* 1-based port that flaps */
    uint32_t storm_flaps;   /* transitions (even -> ends attached) */
    uint32_t storm_period_ms;
    uint32_t storm_left;
    QEMUTimer *storm_timer;
    /*
     * downstream-port RESET storm (the port never disconnects;
     * the hub keeps re-signaling PORT RESET and re-resetting the child).
     */
    bool reset_storm;       /* nto64-reset-storm=on */
    uint32_t reset_storm_port;
    uint32_t reset_storm_flaps;
    uint32_t reset_storm_period_ms;
    uint32_t reset_storm_left;
    QEMUTimer *reset_storm_timer;
    /* guest-armed OC asserted mid-transfer */
    bool oc_mid;                /* nto64-oc-mid-transfer=on */
    uint32_t oc_mid_port;       /* 1-based port to fault */
    uint32_t oc_mid_ms;         /* OC assertion delay after arming */
    QEMUTimer *oc_mid_timer;
    bool port_power;
    QEMUTimer *port_timer;
    USBHubPort ports[MAX_PORTS];
};

#define TYPE_USB_HUB "usb-hub"
OBJECT_DECLARE_SIMPLE_TYPE(USBHubState, USB_HUB)

#define ClearHubFeature         (0x2000 | USB_REQ_CLEAR_FEATURE)
#define ClearPortFeature        (0x2300 | USB_REQ_CLEAR_FEATURE)
#define GetHubDescriptor        (0xa000 | USB_REQ_GET_DESCRIPTOR)
#define GetHubStatus            (0xa000 | USB_REQ_GET_STATUS)
#define GetPortStatus           (0xa300 | USB_REQ_GET_STATUS)
#define SetHubFeature           (0x2000 | USB_REQ_SET_FEATURE)
#define SetPortFeature          (0x2300 | USB_REQ_SET_FEATURE)

#define PORT_STAT_CONNECTION    0x0001
#define PORT_STAT_ENABLE        0x0002
#define PORT_STAT_SUSPEND       0x0004
#define PORT_STAT_OVERCURRENT   0x0008
#define PORT_STAT_RESET         0x0010
#define PORT_STAT_POWER         0x0100
#define PORT_STAT_LOW_SPEED     0x0200
#define PORT_STAT_HIGH_SPEED    0x0400
#define PORT_STAT_TEST          0x0800
#define PORT_STAT_INDICATOR     0x1000

#define PORT_STAT_C_CONNECTION  0x0001
#define PORT_STAT_C_ENABLE      0x0002
#define PORT_STAT_C_SUSPEND     0x0004
#define PORT_STAT_C_OVERCURRENT 0x0008
#define PORT_STAT_C_RESET       0x0010

#define PORT_CONNECTION         0
#define PORT_ENABLE             1
#define PORT_SUSPEND            2
#define PORT_OVERCURRENT        3
#define PORT_RESET              4
#define PORT_POWER              8
#define PORT_LOWSPEED           9
#define PORT_HIGHSPEED          10
#define PORT_C_CONNECTION       16
#define PORT_C_ENABLE           17
#define PORT_C_SUSPEND          18
#define PORT_C_OVERCURRENT      19
#define PORT_C_RESET            20
#define PORT_TEST               21
#define PORT_INDICATOR          22

/* same as Linux kernel root hubs */

enum {
    STR_MANUFACTURER = 1,
    STR_PRODUCT,
    STR_SERIALNUMBER,
};

static const USBDescStrings desc_strings = {
    [STR_MANUFACTURER] = "QEMU",
    [STR_PRODUCT]      = "QEMU USB Hub",
    [STR_SERIALNUMBER] = "314159",
};

/*
 * arm the over-current fault (condition + edge change bit +
 * a fresh self-clear counter).  Called on every SET_CONFIGURATION so
 * the guest driver's own set-config - the last one before its fault
 * phases - is the deterministic arming point; BIOS boot enumeration
 * also sets the hub config and would otherwise consume the edge
 * change bit / self-clear reads.
 */
static void nto64_hub_arm_oc(USBHubState *s)
{
    if (s->oc_port == 0) {
        return;
    }
    s->oc_active = true;
    s->oc_reads = 0;
    if (s->oc_change) {
        s->ports[s->oc_port - 1].wPortChange |= PORT_STAT_C_OVERCURRENT;
    }
}

/*
 * the downstream-port connect/disconnect storm.  Each tick
 * flips the child's attach state (detach, attach, detach, ...), one
 * transition per storm_period_ms; with an even storm_flaps the storm
 * settles with the device ATTACHED, so a driver that bounds its wait
 * and re-enumerates after the settle survives.
 */
static void nto64_hub_storm_tick(void *opaque)
{
    USBHubState *s = opaque;
    USBHubPort *port;
    USBDevice *child;
    Error *err = NULL;

    if (s->storm_left == 0 || s->storm_port == 0 ||
        s->storm_port > s->num_ports) {
        return;
    }
    port = &s->ports[s->storm_port - 1];
    child = port->port.dev;
    if (child == NULL) {
        return;
    }
    s->storm_left--;
    if (child->attached) {
        usb_device_detach(child);
    } else {
        usb_device_attach(child, &err);
        if (err) {
            error_report_err(err);
            return;
        }
    }
    timer_mod(s->storm_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
              s->storm_period_ms * 1000000ULL);
}

/*
 * the over-current condition asserts WHILE a
 * downstream transfer is in flight (the guest arms the hub, starts
 * the transfer, and the timer fires mid-transfer).  The OC status and
 * change bits are set exactly like the static shapes; the in-flight
 * transfer dies because the downstream device's own disconnect hook
 * detaches it at ~1 ms (the same shape as ).  The driver
 * notices the OC, power-cycles the port, re-enumerates and retries.
 */
static void nto64_hub_oc_mid_tick(void *opaque)
{
    USBHubState *s = opaque;

    if (s->oc_mid_port == 0 || s->oc_mid_port > s->num_ports) {
        return;
    }
    s->oc_active = true;
    s->oc_reads = 0;
    s->oc_port = s->oc_mid_port;
    if (s->oc_change) {
        s->ports[s->oc_mid_port - 1].wPortChange |=
            PORT_STAT_C_OVERCURRENT;
    }
}

static const USBDescIface desc_iface_hub = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 1,
    .bInterfaceClass               = USB_CLASS_HUB,
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_INT,
            .wMaxPacketSize        = 1 + DIV_ROUND_UP(MAX_PORTS, 8),
            .bInterval             = 0xff,
        },
    }
};

static const USBDescDevice desc_device_hub = {
    .bcdUSB                        = 0x0110,
    .bDeviceClass                  = USB_CLASS_HUB,
    .bMaxPacketSize0               = 8,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_SELFPOWER |
                                     USB_CFG_ATT_WAKEUP,
            .nif = 1,
            .ifs = &desc_iface_hub,
        },
    },
};

static const USBDesc desc_hub = {
    .id = {
        .idVendor          = 0x0409,
        .idProduct         = 0x55aa,
        .bcdDevice         = 0x0101,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT,
        .iSerialNumber     = STR_SERIALNUMBER,
    },
    .full = &desc_device_hub,
    .str  = desc_strings,
};

static const uint8_t qemu_hub_hub_descriptor[] =
{
        0x00,                   /*  u8  bLength; patched in later */
        0x29,                   /*  u8  bDescriptorType; Hub-descriptor */
        0x00,                   /*  u8  bNbrPorts; (patched later) */
        0x0a,                   /* u16  wHubCharacteristics; */
        0x00,                   /*   (per-port OC, no power switching) */
        0x01,                   /*  u8  bPwrOn2pwrGood; 2ms */
        0x00                    /*  u8  bHubContrCurrent; 0 mA */

        /* DeviceRemovable and PortPwrCtrlMask patched in later */
};

static bool usb_hub_port_change(USBHubPort *port, uint16_t status)
{
    bool notify = false;

    if (status & 0x1f) {
        port->wPortChange |= status;
        notify = true;
    }
    return notify;
}

static bool usb_hub_port_set(USBHubPort *port, uint16_t status)
{
    if (port->wPortStatus & status) {
        return false;
    }
    port->wPortStatus |= status;
    return usb_hub_port_change(port, status);
}

static bool usb_hub_port_clear(USBHubPort *port, uint16_t status)
{
    if (!(port->wPortStatus & status)) {
        return false;
    }
    port->wPortStatus &= ~status;
    return usb_hub_port_change(port, status);
}

static bool usb_hub_port_update(USBHubPort *port)
{
    bool notify = false;

    if (port->port.dev && port->port.dev->attached) {
        notify = usb_hub_port_set(port, PORT_STAT_CONNECTION);
        if (port->port.dev->speed == USB_SPEED_LOW) {
            usb_hub_port_set(port, PORT_STAT_LOW_SPEED);
        } else {
            usb_hub_port_clear(port, PORT_STAT_LOW_SPEED);
        }
    }
    return notify;
}

static void usb_hub_port_update_timer(void *opaque)
{
    USBHubState *s = opaque;
    bool notify = false;
    int i;

    for (i = 0; i < s->num_ports; i++) {
        notify |= usb_hub_port_update(&s->ports[i]);
    }
    if (notify) {
        usb_wakeup(s->intr, 0);
    }
}

/*
 * the downstream-port RESET storm.  Each tick re-signals a
 * port reset without a host request - the same observable as a
 * SetPortFeature(PORT_RESET): the RESET status pulses, the C_RESET
 * change bit re-asserts (via usb_hub_port_change), and the child is
 * reset (address/config cleared, so it must re-enumerate).  The port
 * never DISCONNECTS, so a driver that treats every reset like a
 * disconnect tears slots down pointlessly; the recovery is a bounded
 * wait for the storm to settle, then a re-enumerate.  An even flap
 * count ends quiet.
 */
static void nto64_hub_reset_storm_tick(void *opaque)
{
    USBHubState *s = opaque;
    USBHubPort *port;
    USBDevice *child;

    if (s->reset_storm_left == 0 || s->reset_storm_port == 0 ||
        s->reset_storm_port > s->num_ports) {
        return;
    }
    port = &s->ports[s->reset_storm_port - 1];
    child = port->port.dev;
    if (child == NULL) {
        return;
    }
    s->reset_storm_left--;
    usb_hub_port_set(port, PORT_STAT_RESET);
    usb_hub_port_clear(port, PORT_STAT_RESET);
    if (child->attached) {
        usb_device_reset(child);
        usb_hub_port_set(port, PORT_STAT_ENABLE);
    }
    usb_wakeup(s->intr, 0);
    timer_mod(s->reset_storm_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
              s->reset_storm_period_ms * 1000000ULL);
}

static void usb_hub_attach(USBPort *port1)
{
    USBHubState *s = port1->opaque;
    USBHubPort *port = &s->ports[port1->index];

    trace_usb_hub_attach(s->dev.addr, port1->index + 1);
    usb_hub_port_update(port);
    usb_wakeup(s->intr, 0);
}

static void usb_hub_detach(USBPort *port1)
{
    USBHubState *s = port1->opaque;
    USBHubPort *port = &s->ports[port1->index];

    trace_usb_hub_detach(s->dev.addr, port1->index + 1);
    usb_wakeup(s->intr, 0);

    /* Let upstream know the device on this port is gone */
    s->dev.port->ops->child_detach(s->dev.port, port1->dev);

    usb_hub_port_clear(port, PORT_STAT_CONNECTION);
    usb_hub_port_clear(port, PORT_STAT_ENABLE);
    usb_hub_port_clear(port, PORT_STAT_SUSPEND);
    usb_wakeup(s->intr, 0);
}

static void usb_hub_child_detach(USBPort *port1, USBDevice *child)
{
    USBHubState *s = port1->opaque;

    /* Pass along upstream */
    s->dev.port->ops->child_detach(s->dev.port, child);
}

static void usb_hub_wakeup(USBPort *port1)
{
    USBHubState *s = port1->opaque;
    USBHubPort *port = &s->ports[port1->index];

    if (usb_hub_port_clear(port, PORT_STAT_SUSPEND)) {
        usb_wakeup(s->intr, 0);
    }
}

static void usb_hub_complete(USBPort *port, USBPacket *packet)
{
    USBHubState *s = port->opaque;

    /*
     * Just pass it along upstream for now.
     *
     * If we ever implement usb 2.0 split transactions this will
     * become a little more complicated ...
     *
     * Can't use usb_packet_complete() here because packet->owner is
     * cleared already, go call the ->complete() callback directly
     * instead.
     */
    s->dev.port->ops->complete(s->dev.port, packet);
}

static USBDevice *usb_hub_find_device(USBDevice *dev, uint8_t addr)
{
    USBHubState *s = USB_HUB(dev);
    USBHubPort *port;
    USBDevice *downstream;
    int i;

    for (i = 0; i < s->num_ports; i++) {
        port = &s->ports[i];
        if (!(port->wPortStatus & PORT_STAT_ENABLE)) {
            continue;
        }
        downstream = usb_find_device(&port->port, addr);
        if (downstream != NULL) {
            return downstream;
        }
    }
    return NULL;
}

static void usb_hub_handle_reset(USBDevice *dev)
{
    USBHubState *s = USB_HUB(dev);
    USBHubPort *port;
    int i;

    trace_usb_hub_reset(s->dev.addr);
    for (i = 0; i < s->num_ports; i++) {
        port = s->ports + i;
        port->wPortStatus = 0;
        port->wPortChange = 0;
        usb_hub_port_set(port, PORT_STAT_POWER);
        usb_hub_port_update(port);
    }
}

static const char *feature_name(int feature)
{
    static const char *name[] = {
        [PORT_CONNECTION]    = "connection",
        [PORT_ENABLE]        = "enable",
        [PORT_SUSPEND]       = "suspend",
        [PORT_OVERCURRENT]   = "overcurrent",
        [PORT_RESET]         = "reset",
        [PORT_POWER]         = "power",
        [PORT_LOWSPEED]      = "lowspeed",
        [PORT_HIGHSPEED]     = "highspeed",
        [PORT_C_CONNECTION]  = "change-connection",
        [PORT_C_ENABLE]      = "change-enable",
        [PORT_C_SUSPEND]     = "change-suspend",
        [PORT_C_OVERCURRENT] = "change-overcurrent",
        [PORT_C_RESET]       = "change-reset",
        [PORT_TEST]          = "test",
        [PORT_INDICATOR]     = "indicator",
    };
    if (feature < 0 || feature >= ARRAY_SIZE(name)) {
        return "?";
    }
    return name[feature] ?: "?";
}

static void usb_hub_handle_control(USBDevice *dev, USBPacket *p,
               int request, int value, int index, int length, uint8_t *data)
{
    USBHubState *s = (USBHubState *)dev;
    int ret;

    trace_usb_hub_control(s->dev.addr, request, value, index, length);

    if (request == (DeviceOutRequest | USB_REQ_SET_CONFIGURATION)) {
        nto64_hub_arm_oc(s);
    }

    ret = usb_desc_handle_control(dev, p, request, value, index, length, data);
    if (ret >= 0) {
        return;
    }
    switch(request) {
    case VendorDeviceOutRequest | 0x56:
        /*
         * guest-only arm for the port connect/disconnect
         * storm (the no-op reply keeps the harness phase uniform on
         * clean targets where the hook is off).
         */
        if (s->port_storm && s->storm_port > 0 &&
            s->storm_port <= s->num_ports) {
            s->storm_left = s->storm_flaps;
            timer_mod(s->storm_timer,
                      qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL));
        }
        break;
    case VendorDeviceOutRequest | 0x57:
        /*
         * guest-only arm for the mid-transfer
         * over-current (no-op on clean targets).
         */
        if (s->oc_mid && s->oc_mid_port > 0 &&
            s->oc_mid_port <= s->num_ports) {
            timer_mod(s->oc_mid_timer,
                      qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                      s->oc_mid_ms * 1000000ULL);
        }
        break;
    case VendorDeviceOutRequest | 0x58:
        /*
         * guest-only arm for the port RESET storm (no-op on
         * clean targets).
         */
        if (s->reset_storm && s->reset_storm_port > 0 &&
            s->reset_storm_port <= s->num_ports) {
            s->reset_storm_left = s->reset_storm_flaps;
            timer_mod(s->reset_storm_timer,
                      qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL));
        }
        break;
    case EndpointOutRequest | USB_REQ_CLEAR_FEATURE:
        if (value == 0 && index != 0x81) { /* clear ep halt */
            goto fail;
        }
        break;
        /* usb specific requests */
    case GetHubStatus:
        data[0] = 0;
        data[1] = 0;
        data[2] = 0;
        data[3] = 0;
        p->actual_length = 4;
        break;
    case GetPortStatus:
        {
            unsigned int n = index - 1;
            USBHubPort *port;
            if (n >= s->num_ports) {
                goto fail;
            }
            port = &s->ports[n];
            trace_usb_hub_get_port_status(s->dev.addr, index,
                                          port->wPortStatus,
                                          port->wPortChange);
            data[0] = port->wPortStatus;
            data[1] = port->wPortStatus >> 8;
            data[2] = port->wPortChange;
            data[3] = port->wPortChange >> 8;
            if (s->oc_active && s->oc_port == index) {
                s->oc_reads++;
                if (s->oc_self_clear_reads &&
                    s->oc_reads >= s->oc_self_clear_reads) {
                    /*
                     * the condition clears on its own (a
                     * transient fault the driver must not over-react
                     * to with a power cycle).
                     */
                    s->oc_active = false;
                }
                if (s->oc_active) {
                    if (s->oc_status) {
                        data[0] |= PORT_STAT_OVERCURRENT;
                    }
                    if (s->oc_change && !s->oc_edge) {
                        /*
                         * a chatty (non-compliant) hub
                         * re-asserts the change bit on every read
                         * while the condition persists; the spec is
                         * edge-triggered (the bit was set once at
                         * assertion and the host clears it).
                         */
                        data[2] |= PORT_STAT_C_OVERCURRENT;
                    }
                }
            }
            p->actual_length = 4;
        }
        break;
    case SetHubFeature:
    case ClearHubFeature:
        if (value != 0 && value != 1) {
            goto fail;
        }
        break;
    case SetPortFeature:
        {
            unsigned int n = index - 1;
            USBHubPort *port;
            USBDevice *pdev;

            trace_usb_hub_set_port_feature(s->dev.addr, index,
                                           feature_name(value));

            if (n >= s->num_ports) {
                goto fail;
            }
            port = &s->ports[n];
            pdev = port->port.dev;
            switch(value) {
            case PORT_SUSPEND:
                port->wPortStatus |= PORT_STAT_SUSPEND;
                break;
            case PORT_RESET:
                usb_hub_port_set(port, PORT_STAT_RESET);
                usb_hub_port_clear(port, PORT_STAT_RESET);
                if (pdev && pdev->attached) {
                    usb_device_reset(pdev);
                    usb_hub_port_set(port, PORT_STAT_ENABLE);
                }
                usb_wakeup(s->intr, 0);
                break;
            case PORT_POWER:
                if (s->port_power) {
                    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
                    usb_hub_port_set(port, PORT_STAT_POWER);
                    timer_mod(s->port_timer, now + 5000000); /* 5 ms */
                }
                break;
            default:
                goto fail;
            }
        }
        break;
    case ClearPortFeature:
        {
            unsigned int n = index - 1;
            USBHubPort *port;

            trace_usb_hub_clear_port_feature(s->dev.addr, index,
                                             feature_name(value));

            if (n >= s->num_ports) {
                goto fail;
            }
            port = &s->ports[n];
            switch(value) {
            case PORT_ENABLE:
                port->wPortStatus &= ~PORT_STAT_ENABLE;
                break;
            case PORT_C_ENABLE:
                port->wPortChange &= ~PORT_STAT_C_ENABLE;
                break;
            case PORT_SUSPEND:
                usb_hub_port_clear(port, PORT_STAT_SUSPEND);
                break;
            case PORT_C_SUSPEND:
                port->wPortChange &= ~PORT_STAT_C_SUSPEND;
                break;
            case PORT_C_CONNECTION:
                port->wPortChange &= ~PORT_STAT_C_CONNECTION;
                break;
            case PORT_C_OVERCURRENT:
                port->wPortChange &= ~PORT_STAT_C_OVERCURRENT;
                break;
            case PORT_C_RESET:
                port->wPortChange &= ~PORT_STAT_C_RESET;
                break;
            case PORT_POWER:
                if (s->port_power) {
                    usb_hub_port_clear(port, PORT_STAT_POWER);
                    usb_hub_port_clear(port, PORT_STAT_CONNECTION);
                    usb_hub_port_clear(port, PORT_STAT_ENABLE);
                    usb_hub_port_clear(port, PORT_STAT_SUSPEND);
                    port->wPortChange = 0;
                    /*
                     * power-restore cycle: killing the port power ends
                     * the over-current condition (unless the hub is
                     * broken and the fault persists)
                     */
                    if (s->oc_active && s->oc_port == index &&
                        !s->oc_persistent) {
                        s->oc_active = false;
                    }
                }
                break;
            default:
                goto fail;
            }
        }
        break;
    case GetHubDescriptor:
        {
            unsigned int n, limit, var_hub_size = 0;
            memcpy(data, qemu_hub_hub_descriptor,
                   sizeof(qemu_hub_hub_descriptor));
            data[2] = s->num_ports;

            if (s->port_power) {
                data[3] &= ~0x03;
                data[3] |= 0x01;
            }

            /* fill DeviceRemovable bits */
            limit = DIV_ROUND_UP(s->num_ports + 1, 8) + 7;
            for (n = 7; n < limit; n++) {
                data[n] = 0x00;
                var_hub_size++;
            }

            /* fill PortPwrCtrlMask bits */
            limit = limit + DIV_ROUND_UP(s->num_ports, 8);
            for (;n < limit; n++) {
                data[n] = 0xff;
                var_hub_size++;
            }

            p->actual_length = sizeof(qemu_hub_hub_descriptor) + var_hub_size;
            data[0] = p->actual_length;
            break;
        }
    default:
    fail:
        p->status = USB_RET_STALL;
        break;
    }
}

static void usb_hub_handle_data(USBDevice *dev, USBPacket *p)
{
    USBHubState *s = (USBHubState *)dev;

    switch(p->pid) {
    case USB_TOKEN_IN:
        if (p->ep->nr == 1) {
            USBHubPort *port;
            unsigned int status;
            uint8_t buf[4];
            int i, n;
            n = DIV_ROUND_UP(s->num_ports + 1, 8);
            if (p->iov.size == 1) { /* FreeBSD workaround */
                n = 1;
            } else if (n > p->iov.size) {
                p->status = USB_RET_BABBLE;
                return;
            }
            status = 0;
            for (i = 0; i < s->num_ports; i++) {
                port = &s->ports[i];
                if (port->wPortChange)
                    status |= (1 << (i + 1));
            }
            if (status != 0) {
                trace_usb_hub_status_report(s->dev.addr, status);
                for(i = 0; i < n; i++) {
                    buf[i] = status >> (8 * i);
                }
                usb_packet_copy(p, buf, n);
            } else {
                p->status = USB_RET_NAK; /* usb11 11.13.1 */
            }
        } else {
            goto fail;
        }
        break;
    case USB_TOKEN_OUT:
    default:
    fail:
        p->status = USB_RET_STALL;
        break;
    }
}

static void usb_hub_unrealize(USBDevice *dev)
{
    USBHubState *s = (USBHubState *)dev;
    int i;

    for (i = 0; i < s->num_ports; i++) {
        usb_unregister_port(usb_bus_from_device(dev),
                            &s->ports[i].port);
    }

    timer_free(s->port_timer);
    timer_free(s->storm_timer);
    timer_free(s->reset_storm_timer);
    timer_free(s->oc_mid_timer);
}

static USBPortOps usb_hub_port_ops = {
    .attach = usb_hub_attach,
    .detach = usb_hub_detach,
    .child_detach = usb_hub_child_detach,
    .wakeup = usb_hub_wakeup,
    .complete = usb_hub_complete,
};

static void usb_hub_realize(USBDevice *dev, Error **errp)
{
    USBHubState *s = USB_HUB(dev);
    USBHubPort *port;
    int i;

    if (s->num_ports < 1 || s->num_ports > MAX_PORTS) {
        error_setg(errp, "num_ports (%d) out of range (1..%d)",
                   s->num_ports, MAX_PORTS);
        return;
    }

    if (dev->port->hubcount == 5) {
        error_setg(errp, "usb hub chain too deep");
        return;
    }

    usb_desc_create_serial(dev);
    usb_desc_init(dev);
    s->port_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                 usb_hub_port_update_timer, s);
    s->storm_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                  nto64_hub_storm_tick, s);
    s->reset_storm_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                        nto64_hub_reset_storm_tick, s);
    s->oc_mid_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                   nto64_hub_oc_mid_tick, s);
    s->intr = usb_ep_get(dev, USB_TOKEN_IN, 1);
    for (i = 0; i < s->num_ports; i++) {
        port = &s->ports[i];
        usb_register_port(usb_bus_from_device(dev),
                          &port->port, s, i, &usb_hub_port_ops,
                          USB_SPEED_MASK_LOW | USB_SPEED_MASK_FULL);
        usb_port_location(&port->port, dev->port, i+1);
    }
    usb_hub_handle_reset(dev);
    if (s->oc_port != 0) {
        s->oc_active = true;
        if (s->oc_change) {
            /* edge-triggered: set the change bit once at assertion */
            s->ports[s->oc_port - 1].wPortChange |= PORT_STAT_C_OVERCURRENT;
        }
    }
}

static const VMStateDescription vmstate_usb_hub_port = {
    .name = "usb-hub-port",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_UINT16(wPortStatus, USBHubPort),
        VMSTATE_UINT16(wPortChange, USBHubPort),
        VMSTATE_END_OF_LIST()
    }
};

static bool usb_hub_port_timer_needed(void *opaque)
{
    USBHubState *s = opaque;

    return s->port_power;
}

static const VMStateDescription vmstate_usb_hub_port_timer = {
    .name = "usb-hub/port-timer",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = usb_hub_port_timer_needed,
    .fields = (const VMStateField[]) {
        VMSTATE_TIMER_PTR(port_timer, USBHubState),
        VMSTATE_END_OF_LIST()
    },
};

static const VMStateDescription vmstate_usb_hub = {
    .name = "usb-hub",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_USB_DEVICE(dev, USBHubState),
        VMSTATE_STRUCT_ARRAY(ports, USBHubState, MAX_PORTS, 0,
                             vmstate_usb_hub_port, USBHubPort),
        VMSTATE_END_OF_LIST()
    },
    .subsections = (const VMStateDescription * const []) {
        &vmstate_usb_hub_port_timer,
        NULL
    }
};

static const Property usb_hub_properties[] = {
    DEFINE_PROP_UINT32("ports", USBHubState, num_ports, 8),
    DEFINE_PROP_BOOL("port-power", USBHubState, port_power, false),
    DEFINE_PROP_UINT32("oc-port", USBHubState, oc_port, 0),
    DEFINE_PROP_BOOL("nto64-oc-edge", USBHubState, oc_edge, true),
    DEFINE_PROP_BOOL("nto64-oc-persistent", USBHubState, oc_persistent, false),
    DEFINE_PROP_BOOL("nto64-oc-status", USBHubState, oc_status, true),
    DEFINE_PROP_BOOL("nto64-oc-change", USBHubState, oc_change, true),
    DEFINE_PROP_UINT32("nto64-oc-self-clear-reads", USBHubState,
                       oc_self_clear_reads, 0),
    DEFINE_PROP_BOOL("nto64-port-storm", USBHubState, port_storm, false),
    DEFINE_PROP_UINT32("nto64-storm-port", USBHubState, storm_port, 1),
    DEFINE_PROP_UINT32("nto64-storm-flaps", USBHubState, storm_flaps, 4),
    DEFINE_PROP_UINT32("nto64-storm-period-ms", USBHubState,
                       storm_period_ms, 50),
    DEFINE_PROP_BOOL("nto64-reset-storm", USBHubState, reset_storm, false),
    DEFINE_PROP_UINT32("nto64-reset-storm-port", USBHubState,
                       reset_storm_port, 1),
    DEFINE_PROP_UINT32("nto64-reset-storm-flaps", USBHubState,
                       reset_storm_flaps, 4),
    DEFINE_PROP_UINT32("nto64-reset-storm-period-ms", USBHubState,
                       reset_storm_period_ms, 50),
    DEFINE_PROP_BOOL("nto64-oc-mid-transfer", USBHubState, oc_mid, false),
    DEFINE_PROP_UINT32("nto64-oc-mid-port", USBHubState, oc_mid_port, 1),
    DEFINE_PROP_UINT32("nto64-oc-mid-ms", USBHubState, oc_mid_ms, 20),
};

static void usb_hub_class_initfn(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize        = usb_hub_realize;
    uc->product_desc   = "QEMU USB Hub";
    uc->usb_desc       = &desc_hub;
    uc->find_device    = usb_hub_find_device;
    uc->handle_reset   = usb_hub_handle_reset;
    uc->handle_control = usb_hub_handle_control;
    uc->handle_data    = usb_hub_handle_data;
    uc->unrealize      = usb_hub_unrealize;
    set_bit(DEVICE_CATEGORY_BRIDGE, dc->categories);
    dc->fw_name = "hub";
    dc->vmsd = &vmstate_usb_hub;
    device_class_set_props(dc, usb_hub_properties);
}

static const TypeInfo hub_info = {
    .name          = TYPE_USB_HUB,
    .parent        = TYPE_USB_DEVICE,
    .instance_size = sizeof(USBHubState),
    .class_init    = usb_hub_class_initfn,
};

static void usb_hub_register_types(void)
{
    type_register_static(&hub_info);
}

type_init(usb_hub_register_types)
