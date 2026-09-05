#!/usr/bin/env python3
"""Host-adaptive network function for the USB Debug Network gadget.

Why: macOS has no RNDIS driver and Windows has no CDC ECM driver, and the two functions
cannot be offered together. The H616 musb UDC has 4 IN + 4 OUT endpoints, so RNDIS
(2 IN + 1 OUT) + mass storage (1 + 1) + ECM (2 + 1) do not fit into one configuration,
while a second USB configuration stops Windows from loading usbccgp for the composite
device (no USB\\COMPOSITE id, the first interface class wins and binds usbser).

How: the gadget always enumerates as RNDIS + mass storage + WinUSB stub first. A host
with an RNDIS driver (Windows, Linux) completes the RNDIS handshake (RNDIS_MSG_INIT,
visible in /proc/driver/rndis-NNN when the kernel has USB_GADGET_DEBUG_FILES) or sends
packets (DHCP, ICMPv6) within about a second of SET_CONFIGURATION; a fresh Windows 11
install needs ~1.3 s. If nothing arrives for PROBE_SECONDS of awake time, the host has
no RNDIS driver and the gadget re-enumerates with CDC ECM. A bus reset or disconnect in
ECM mode goes back to RNDIS, so every host starts from the default.

The WebUSB landing page is advertised only in the final layout: during the probe
iLandingPage is 0, so Chromium shows one notification per plug rather than one per
enumeration. The mass-storage medium is inserted after the verdict for the same reason:
a macOS host would otherwise mount the volume and then watch it disappear.

Both gadget netdevs (dbg0 for RNDIS, dbge0 for ECM) are ports of the dbgbr bridge that
carries the NetworkManager shared connection, so switching functions does not
re-activate the connection. UDC state changes arrive through sysfs_notify() ->
poll(POLLPRI) on /sys/class/udc/<udc>/state; notifications may coalesce, they are not
a queue of resets.
"""

import errno
import glob
import os
import select
import sys
import time

G = os.environ.get("USBGADGET_CONFIG", "/sys/kernel/config/usb_gadget/g1")
USBDEV = os.environ.get("USBDEV", "usb0")
FUNCS = {"rndis": f"rndis.{USBDEV}", "ecm": f"ecm.{USBDEV}"}
MSC = f"mass_storage.{USBDEV}"
FFS = "ffs." + os.environ.get("FFS_WINUSB_NAME", "wbwinusb")
IMAGE_FILE = os.environ.get("IMAGE_FILE", "/usr/lib/wb-utils/wb-usb-otg/mass_storage.img")
LUN_FILE = f"{G}/functions/{MSC}/lun.0/file"
# Written by wb-usb-otg-start.sh (setup_webusb) before the first bind. The live configfs
# attribute is deliberately empty during the probe and cannot be used to recover the URL.
LANDING_PAGE_FILE = os.environ.get("LANDING_PAGE_FILE", "/run/wb-usb-otg/landing-page")
RNDIS_IF = os.environ.get("RNDIS_IF", "dbg0")
PROBE_SECONDS = float(os.environ.get("PROBE_SECONDS", "4"))
# UDC state poll period inside the probe; also the timing resolution of the verdict.
PROBE_POLL = float(os.environ.get("PROBE_POLL", "0.25"))
# Explicit /proc/driver/rndis-NNN path; unset = use the file if exactly one instance exists.
RNDIS_STATE_FILE = os.environ.get("RNDIS_STATE_FILE")

UDC = None
STATE = None


def log(msg):
    print(f"wb-usb-otg-netfunc: {msg}", file=sys.stderr, flush=True)


def write(path, value):
    with open(path, "w") as f:
        f.write(value)


def saved_landing_page():
    try:
        with open(LANDING_PAGE_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def rx_packets():
    try:
        with open(f"/sys/class/net/{RNDIS_IF}/statistics/rx_packets") as f:
            return int(f.read())
    except OSError:
        return 0


def rndis_state_file():
    if RNDIS_STATE_FILE is not None:
        return RNDIS_STATE_FILE or None
    # Never guess an instance number when several RNDIS functions exist.
    files = glob.glob("/proc/driver/rndis-*")
    return files[0] if len(files) == 1 else None


def rndis_initialized():
    """The control-plane handshake is evidence even on a host with DHCP and IPv6 disabled.

    Needs CONFIG_USB_GADGET_DEBUG_FILES; without the file only packets count. The netdev
    carrier is not usable instead: gether_connect() raises it as soon as the host selects
    the interface, before RNDIS_MSG_INIT.
    """
    path = rndis_state_file()
    if not path:
        return False
    try:
        with open(path) as f:
            for line in f:
                key, sep, value = line.partition(":")
                if sep and key.strip() == "state":
                    return value.strip() in ("RNDIS_INITIALIZED", "RNDIS_DATA_INITIALIZED")
    except OSError:
        pass
    return False


def probe(st, rx0):
    """Wait for RNDIS evidence, counting only awake time: a suspended host cannot answer.

    Returns ("rndis" | "silent" | "link event", awake seconds).
    """
    elapsed = 0.0
    started = time.monotonic()
    while True:
        if not st.connected():
            return "link event", elapsed
        init, rx = rndis_initialized(), rx_packets()
        if init or rx > rx0:
            log(
                f"RNDIS evidence: handshake={init}, {rx - rx0} packets, "
                f"{time.monotonic() - started:.2f}s after SET_CONFIGURATION"
            )
            return "rndis", elapsed
        if st.value == "configured" and elapsed >= PROBE_SECONDS:
            return "silent", elapsed
        previous = st.value
        t0 = time.monotonic()
        st.wait(PROBE_POLL)
        if previous == "configured" and st.value == "configured":
            elapsed += time.monotonic() - t0


def set_medium(inserted):
    """Insert or eject the mass-storage image; the LUN is removable, so this works while bound."""
    try:
        write(LUN_FILE, IMAGE_FILE if inserted else "")
    except OSError as e:
        log(f"lun.0/file: {e}")


def unbind():
    try:
        write(f"{G}/UDC", "")
    except OSError as e:
        if e.errno != errno.ENODEV:  # ENODEV: was not bound
            raise


def set_net_function(name, landing_page=None):
    """Relink c.1 as <net>(0-1) + mass_storage(2) + ffs(3), set the landing page, bind."""
    set_medium(False)
    unbind()
    if landing_page is not None and os.path.exists(f"{G}/webusb/landingPage"):
        # The trailing newline makes configfs store an empty URL too; an empty URL means
        # iLandingPage=0 while the WebUSB capability, bcdUSB and MS OS descriptors stay.
        write(f"{G}/webusb/landingPage", landing_page + "\n")
    for fn in list(FUNCS.values()) + [MSC, FFS]:
        link = f"{G}/configs/c.1/{fn}"
        if os.path.islink(link):
            os.unlink(link)
    for fn in (FUNCS[name], MSC, FFS):
        if os.path.isdir(f"{G}/functions/{fn}"):
            os.symlink(f"{G}/functions/{fn}", f"{G}/configs/c.1/{fn}")
    # MS OS 1.0/2.0 descriptors describe the RNDIS layout (and Windows would bind
    # usbrndis6 to the ECM interface by them); do not offer them in ECM mode.
    ms = "1" if name == "rndis" else "0"
    write(f"{G}/os_desc/use", ms)
    if os.path.exists(f"{G}/msos20/use"):
        write(f"{G}/msos20/use", ms)
    write(f"{G}/UDC", UDC)
    status = "unchanged" if landing_page is None else ("present" if landing_page else "hidden")
    log(f"enumerating as {name}, landing page {status}")
    # The state attribute is not updated on unbind, so a stale "configured" may remain
    # until the host resets us; the caller must wait for a fresh transition.


class UdcState:
    def __init__(self):
        self.f = open(STATE)
        self.poll = select.poll()
        self.poll.register(self.f, select.POLLPRI | select.POLLERR)
        self.value = self.read()

    def read(self):
        self.f.seek(0)
        self.value = self.f.read().strip()
        return self.value

    def wait(self, timeout=None):
        """Block until the state attribute changes (or timeout, seconds); return new state."""
        self.poll.poll(None if timeout is None else int(timeout * 1000))
        return self.read()

    def connected(self):
        return self.value in ("configured", "suspended")


def main():
    global UDC, STATE
    UDC = sorted(os.listdir("/sys/class/udc"))[0]
    STATE = f"/sys/class/udc/{UDC}/state"
    landing_page = saved_landing_page()
    st = UdcState()
    mode = "rndis"
    log(
        f"udc={UDC} state={st.value} probe={PROBE_SECONDS}s "
        f"rndis_state={rndis_state_file() or 'packets only'} "
        f"landing_page={'set' if landing_page else 'none'}"
    )
    # Start from the probe layout even when restarted from a final ECM/RNDIS layout.
    set_net_function("rndis", landing_page="")
    fresh, ready = False, False
    while True:
        if not fresh:
            while st.connected():
                st.wait()
            fresh = True
        # Snapshot before SET_CONFIGURATION: the first packet may arrive before
        # userspace wakes up on the state notification.
        rx0 = rx_packets()
        while st.value != "configured":
            st.wait()
        if not ready:
            verdict, elapsed = probe(st, rx0)
            if verdict == "rndis":
                log("host talks RNDIS, keeping it")
                ready = True
                if landing_page:
                    set_net_function("rndis", landing_page=landing_page)
                    fresh = False
                # No URL means no reason to re-enumerate a working RNDIS host.
            elif verdict == "silent":
                log(f"configured but no RNDIS evidence for {elapsed:.1f}s awake, trying CDC ECM")
                set_net_function("ecm", landing_page=landing_page)
                mode, fresh, ready = "ecm", False, True
            else:
                log(f"link event ({st.value}) during probe, restarting")
        else:
            set_medium(True)
            while st.connected():
                st.wait()
            log(f"link event ({st.value}) in {mode} mode, back to the RNDIS probe")
            set_net_function("rndis", landing_page="")
            mode, fresh, ready = "rndis", False, False


if __name__ == "__main__":
    main()
