#!/usr/bin/env python3
"""Host-adaptive network function for the USB Debug Network gadget.

Why: macOS has no RNDIS driver and Windows has no CDC ECM driver, and the two functions
cannot be offered together. The H616 musb UDC has 4 IN + 4 OUT endpoints, so RNDIS
(2 IN + 1 OUT) + mass storage (1 + 1) + ECM (2 + 1) do not fit into one configuration,
while a second USB configuration stops Windows from loading usbccgp for the composite
device (no USB\\COMPOSITE id, the first interface class wins and binds usbser).

How: the gadget enumerates as RNDIS + mass storage (+ WinUSB stub) with the WebUSB
landing page hidden. A host with an RNDIS driver (Windows, Linux) completes the RNDIS
handshake (RNDIS_MSG_INIT, visible in /proc/driver/rndis-NNN when the kernel has
USB_GADGET_DEBUG_FILES) or sends packets (DHCP, ICMPv6) within about a second of
SET_CONFIGURATION; a fresh Windows 11 install needs ~1.3 s. With evidence the layout is
re-enumerated once more with the landing page visible (only when one is configured).
Without evidence for PROBE_SECONDS of awake time the gadget re-enumerates as CDC ECM; if
the host stays silent there too for ECM_SECONDS (Windows with a slow first driver install,
Linux without DHCP and IPv6) it goes back to RNDIS and stays there, so the pre-existing
behaviour is the worst case. The evidence check runs again after every re-configuration
(bus reset, resume), so a host that stopped talking is not left on a dead function.

The landing page is visible only in a final layout, so Chromium shows one notification
per plug rather than one per enumeration; the mass-storage medium is inserted only after
the host has proven the layout works, so a macOS host never mounts a volume that is
about to disappear. Both gadget netdevs (dbg0 for RNDIS, dbge0 for ECM) are ports of the
dbgbr bridge that carries the NetworkManager shared connection, so switching functions
does not re-activate the connection.

Signals: /sys/class/udc/<udc>/state via poll(POLLPRI) (sysfs_notify; notifications may
coalesce and the attribute is not updated on unbind, so it is only used to account for
suspend and to wake up), and the carrier of the active function's netdev, which
u_ether raises at SET_CONFIGURATION and drops on reset, disconnect and unbind. The
carrier is the level that says "the host runs this layout". A host that neither
reconfigures the gadget within DETACH_SECONDS after a reset is treated as unplugged and
the probe layout is restored. On this hardware the state attribute shows "default" for
both a reset and a cable pull.
"""

import errno
import glob
import os
import select
import sys
import time

# Written by wb-usb-otg-start.sh into /run/wb-usb-otg/env (EnvironmentFile= of the unit);
# the defaults only matter for tests.
G = os.environ.get("USBGADGET_CONFIG", "/sys/kernel/config/usb_gadget/g1")
USBDEV = os.environ.get("USBDEV", "usb0")
IMAGE_FILE = os.environ.get("IMAGE_FILE", "/usr/lib/wb-utils/wb-usb-otg/mass_storage.img")
LANDING_PAGE = os.environ.get("LANDING_PAGE", "")
# Functions the start script created; an empty value means "not available".
ECM_FUNCTION = os.environ.get("ECM_FUNCTION", f"ecm.{USBDEV}")
WINUSB_FUNCTION = os.environ.get("WINUSB_FUNCTION", "")
RNDIS_FUNCTION = f"rndis.{USBDEV}"
MSC_FUNCTION = f"mass_storage.{USBDEV}"
NET_FUNCTIONS = {"rndis": RNDIS_FUNCTION, "ecm": ECM_FUNCTION}
# Tunables, e.g. via `systemctl edit wb-usb-otg-netfunc` (seconds).
PROBE_SECONDS = float(os.environ.get("PROBE_SECONDS", "4"))  # RNDIS evidence, awake time
ECM_SECONDS = float(os.environ.get("ECM_SECONDS", "10"))  # packets on the ECM netdev, awake time
ENUM_SECONDS = float(os.environ.get("ENUM_SECONDS", "10"))  # host must configure a fresh layout
DETACH_SECONDS = float(os.environ.get("DETACH_SECONDS", "5"))  # reset without reconfigure = unplug
POLL = 0.25
# Explicit /proc/driver/rndis-NNN path; unset = the file if exactly one instance exists.
RNDIS_STATE_FILE = os.environ.get("RNDIS_STATE_FILE")

_logged_errors = set()


def log(msg):
    print(f"wb-usb-otg-netfunc: {msg}", file=sys.stderr, flush=True)


def log_once(key, msg):
    if key not in _logged_errors:
        _logged_errors.add(key)
        log(msg)


def write(path, value):
    with open(path, "w", encoding="ascii") as f:
        f.write(value)


def read(path):
    """File content without the trailing newline, or None when unreadable (logged once)."""
    try:
        with open(path, encoding="ascii", errors="replace") as f:
            return f.read().strip()
    except OSError as e:
        log_once(path, f"cannot read {path}: {e}")
        return None


def netdev(net):
    """Kernel-assigned interface name of a network function (valid after the first bind)."""
    name = read(f"{G}/functions/{NET_FUNCTIONS[net]}/ifname")
    return None if not name or "%" in name else name


def carrier(net):
    dev = netdev(net)
    return dev is not None and read(f"/sys/class/net/{dev}/carrier") == "1"


def rx_packets(net):
    dev = netdev(net)
    value = read(f"/sys/class/net/{dev}/statistics/rx_packets") if dev else None
    return int(value) if value and value.isdigit() else 0


def rndis_state_file():
    if RNDIS_STATE_FILE is not None:
        return RNDIS_STATE_FILE
    # Never guess an instance number when several RNDIS functions exist.
    files = glob.glob("/proc/driver/rndis-*")
    return files[0] if len(files) == 1 else None


def rndis_initialized():
    """The control-plane handshake is evidence even on a host with DHCP and IPv6 disabled.

    Needs CONFIG_USB_GADGET_DEBUG_FILES; without the file only packets count. The netdev
    carrier is not usable instead: u_ether raises it at SET_CONFIGURATION, before
    RNDIS_MSG_INIT.
    """
    path = rndis_state_file()
    if not path:
        return False
    try:
        with open(path, encoding="ascii") as f:
            for line in f:
                key, sep, value = line.partition(":")
                if sep and key.strip() == "state":
                    return value.strip() in ("RNDIS_INITIALIZED", "RNDIS_DATA_INITIALIZED")
    except OSError:
        pass
    return False


class UdcState:
    def __init__(self, path):
        self.f = open(path, encoding="ascii")  # pylint: disable=consider-using-with
        self.poll = select.poll()
        self.poll.register(self.f, select.POLLPRI | select.POLLERR)
        self.value = ""
        self.read()

    def read(self):
        self.f.seek(0)
        self.value = self.f.read().strip()

    def wait(self, timeout):
        """Sleep until the state attribute changes or `timeout` seconds pass, then refresh."""
        self.poll.poll(int(timeout * 1000))
        self.read()

    def awake(self):
        return self.value == "configured"


class NetFunc:
    """One gadget, one host at a time."""

    def __init__(self, udc, st):
        self.udc = udc
        self.st = st
        self.net = None  # active network function: "rndis" | "ecm"
        self.url_visible = False
        self.medium = False
        self.rndis_final = False  # ECM was tried and failed: stay on RNDIS until unplugged
        self.rx0 = 0  # rx_packets of the active netdev before the host configured us

    # --- configfs -----------------------------------------------------------------

    def set_medium(self, inserted):
        if inserted == self.medium:
            return
        try:
            write(f"{G}/functions/{MSC_FUNCTION}/lun.0/file", IMAGE_FILE if inserted else "")
            self.medium = inserted
        except OSError as e:
            log(f"lun.0/file: {e}")

    def unbind(self):
        try:
            write(f"{G}/UDC", "")
        except OSError as e:
            if e.errno != errno.ENODEV:  # ENODEV: was not bound
                raise

    def bind(self, net, url_visible, with_winusb=True):
        """Relink c.1 as <net>(0-1) + mass_storage(2) [+ ffs(3)], set the landing page, bind.

        The interface order must stay in sync with FFS_WINUSB_INTERFACE in
        wb-usb-otg-common.sh: the MS OS 2.0 descriptor set names the WinUSB interface by number.
        """
        self.set_medium(False)
        self.unbind()
        if os.path.exists(f"{G}/webusb/landingPage"):
            # The trailing newline makes configfs store an empty URL too; an empty URL
            # means iLandingPage=0 while the WebUSB capability and bcdUSB stay.
            write(f"{G}/webusb/landingPage", (LANDING_PAGE if url_visible else "") + "\n")
        for fn in os.listdir(f"{G}/configs/c.1"):
            if os.path.islink(f"{G}/configs/c.1/{fn}"):
                os.unlink(f"{G}/configs/c.1/{fn}")
        functions = [NET_FUNCTIONS[net], MSC_FUNCTION]
        if WINUSB_FUNCTION and with_winusb:
            functions.append(WINUSB_FUNCTION)
        for fn in functions:
            os.symlink(f"{G}/functions/{fn}", f"{G}/configs/c.1/{fn}")
        # MS OS 1.0/2.0 descriptors describe the RNDIS layout, and by them Windows would
        # bind usbrndis6 to the ECM interface: do not offer them in ECM mode.
        ms = "1" if net == "rndis" else "0"
        write(f"{G}/os_desc/use", ms)
        if os.path.exists(f"{G}/msos20/use"):
            write(f"{G}/msos20/use", ms)
        try:
            write(f"{G}/UDC", self.udc)
        except OSError as e:
            if e.errno == errno.ENODEV and WINUSB_FUNCTION and with_winusb:
                # FunctionFS without descriptors (wb-usb-otg-winusb.service died after
                # creating the function): the network and the drive matter more.
                log(f"bind with {WINUSB_FUNCTION} failed ({e}), retrying without it")
                return self.bind(net, url_visible, with_winusb=False)
            raise
        self.net, self.url_visible = net, url_visible
        self.rx0 = rx_packets(net)
        log(f"enumerating as {net}, landing page {'visible' if url_visible else 'hidden'}")
        return True

    # --- waiting ------------------------------------------------------------------

    def attached(self):
        """The host runs the current layout (carrier follows SET_CONFIGURATION / reset)."""
        return carrier(self.net)

    def wait_configured(self, timeout=None):
        """Wait until the host configures the current layout; False on timeout (seconds)."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while not self.attached():
            if deadline is not None and time.monotonic() >= deadline:
                return False
            # Snapshot before SET_CONFIGURATION: the first packet may arrive before we wake up.
            self.rx0 = rx_packets(self.net)
            self.st.wait(POLL)
        return True

    def wait_evidence(self, seconds, evidence):
        """Wait up to `seconds` of awake time for evidence(); "evidence" | "silent" | "link event"."""
        awake = 0.0
        while True:
            if not self.attached():
                return "link event"
            if evidence():
                return "evidence"
            if awake >= seconds:
                return "silent"
            was_awake = self.st.awake()
            t0 = time.monotonic()
            self.st.wait(POLL)
            if was_awake and self.st.awake():
                awake += time.monotonic() - t0

    def wait_detached(self):
        while self.attached():
            self.st.wait(1.0)

    # --- policy -------------------------------------------------------------------

    def rndis_evidence(self):
        return rndis_initialized() or rx_packets("rndis") > self.rx0

    def ecm_evidence(self):
        return rx_packets("ecm") > self.rx0

    def switch(self, net, url_visible):
        """Re-enumerate; False when no host picked the new layout up (unplugged meanwhile)."""
        self.bind(net, url_visible)
        if self.wait_configured(ENUM_SECONDS):
            return True
        log(f"no host configured the {net} layout within {ENUM_SECONDS:.0f}s")
        return False

    def serve(self):
        """Handle one configured layout; returns when the host left it or after a switch."""
        if self.net == "rndis":
            verdict = self.wait_evidence(PROBE_SECONDS, self.rndis_evidence)
            if verdict == "evidence":
                log("host talks RNDIS")
            elif verdict == "silent" and ECM_FUNCTION and not self.rndis_final:
                log(f"no RNDIS evidence for {PROBE_SECONDS:.0f}s awake, trying CDC ECM")
                self.switch("ecm", bool(LANDING_PAGE))
                return
            elif verdict == "silent":
                log(
                    "no RNDIS evidence, keeping RNDIS (no ECM to try)"
                    if not ECM_FUNCTION
                    else "no RNDIS evidence, keeping RNDIS (ECM already failed)"
                )
            else:
                return
            if LANDING_PAGE and not self.url_visible:
                self.switch("rndis", True)
                return
        else:
            verdict = self.wait_evidence(ECM_SECONDS, self.ecm_evidence)
            if verdict == "evidence":
                log("host talks CDC ECM")
            elif verdict == "silent":
                log(f"no traffic on CDC ECM for {ECM_SECONDS:.0f}s awake, back to RNDIS for good")
                self.rndis_final = True
                self.switch("rndis", bool(LANDING_PAGE))
                return
            else:
                return
        self.set_medium(True)
        self.wait_detached()

    def run(self):
        self.bind("rndis", False)
        while True:
            self.wait_configured()
            self.serve()
            if self.attached() or self.wait_configured(DETACH_SECONDS):
                continue  # bus reset or a layout switch: the same host is still there
            log("host gone, back to the RNDIS probe layout")
            self.rndis_final = False
            if self.net != "rndis" or self.url_visible:
                self.bind("rndis", False)


def main():
    udcs = sorted(os.listdir("/sys/class/udc"))
    if not udcs:
        log("no UDC in /sys/class/udc")
        return 1
    udc = udcs[0]
    st = UdcState(f"/sys/class/udc/{udc}/state")
    log(
        f"udc={udc} probe={PROBE_SECONDS:.0f}s ecm={'yes' if ECM_FUNCTION else 'no'} "
        f"winusb={'yes' if WINUSB_FUNCTION else 'no'} "
        f"rndis_state={rndis_state_file() or 'packets only'} "
        f"landing_page={'set' if LANDING_PAGE else 'none'}"
    )
    try:
        NetFunc(udc, st).run()
    except OSError as e:
        log(f"configfs error: {e} ({e.filename})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
