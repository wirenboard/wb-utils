"""Host-independent regressions for wb-usb-otg-netfunc.py; no configfs or USB hardware needed.

Run: python3 -m unittest discover -s tests
"""

import contextlib
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "netfunc", Path(__file__).resolve().parents[1] / "utils/lib/wb-usb-otg/wb-usb-otg-netfunc.py"
)
dyn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dyn)

URL = "https://10-200-200-1.abcdef.ip.wirenboard.com/"


class FakeState:
    """UDC state attribute driven by a script; wait() advances a fake clock."""

    def __init__(self, events=()):
        self.value = "configured"
        self.events = iter(events)
        self.now = 0.0

    def awake(self):
        return self.value == "configured"

    def wait(self, timeout):
        self.now += timeout
        self.value = next(self.events, self.value)


class Host:
    """What the host does with the current layout, seen through carrier and rx counters."""

    def __init__(self, talks=(), configures=("rndis", "ecm")):
        self.talks = set(talks)  # net functions the host sends packets on
        self.configures = set(configures)  # layouts the host completes SET_CONFIGURATION for
        self.rx = {"rndis": 0, "ecm": 0}
        self.plugged = True

    def carrier(self, net):
        return self.plugged and net in self.configures

    def rx_packets(self, net):
        if self.plugged and net in self.talks:
            self.rx[net] += 1
        return self.rx[net]


class Fixture(contextlib.ExitStack):
    """NetFunc with configfs, netdev and clock replaced; records binds and medium changes."""

    def __init__(self, host, events=(), landing_page="", ecm="ecm.usb0", handshake=False):
        super().__init__()
        self.host, self.events = host, []
        self.st = FakeState(events)
        self.nf = dyn.NetFunc("udc0", self.st)
        self.landing_page, self.ecm, self.handshake = landing_page, ecm, handshake

    def __enter__(self):
        super().__enter__()
        self.enter_context(patch.object(dyn, "LANDING_PAGE", self.landing_page))
        self.enter_context(patch.object(dyn, "ECM_FUNCTION", self.ecm))
        self.enter_context(patch.object(dyn, "carrier", self.host.carrier))
        self.enter_context(patch.object(dyn, "rx_packets", self.host.rx_packets))
        self.enter_context(patch.object(dyn, "rndis_initialized", lambda: self.handshake))
        self.enter_context(patch.object(dyn.time, "monotonic", lambda: self.st.now))
        self.enter_context(patch.object(self.nf, "bind", self.bind))
        self.enter_context(patch.object(self.nf, "set_medium", self.set_medium))
        # serve() blocks in wait_detached() after the medium is in; the tests drive plug cycles
        self.enter_context(patch.object(self.nf, "wait_detached", lambda: None))
        return self

    def bind(self, net, url_visible, with_winusb=True):
        self.events.append(("bind", net, url_visible))
        self.nf.net, self.nf.url_visible = net, url_visible
        self.nf.rx0 = self.host.rx_packets(net)
        return True

    def set_medium(self, inserted):
        self.events.append(("medium", inserted))


class SessionTests(unittest.TestCase):
    """One plug: probe layout -> verdict -> final layout -> medium."""

    def session(self, fx):
        fx.nf.bind("rndis", False)
        fx.nf.wait_configured()
        fx.nf.serve()
        while fx.nf.attached() and fx.events[-1] != ("medium", True):
            fx.nf.serve()
        return fx.events

    def test_rndis_host_with_landing_page_gets_final_rndis_then_medium(self):
        with Fixture(Host(talks=["rndis"]), landing_page=URL) as fx:
            self.assertEqual(
                self.session(fx),
                [("bind", "rndis", False), ("bind", "rndis", True), ("medium", True)],
            )

    def test_rndis_host_without_landing_page_needs_no_second_enumeration(self):
        with Fixture(Host(talks=["rndis"])) as fx:
            self.assertEqual(self.session(fx), [("bind", "rndis", False), ("medium", True)])

    def test_handshake_alone_is_evidence(self):
        with Fixture(Host(), handshake=True) as fx:
            self.assertEqual(self.session(fx), [("bind", "rndis", False), ("medium", True)])

    def test_silent_host_gets_ecm_with_landing_page_and_medium_after_traffic(self):
        with Fixture(Host(talks=["ecm"]), landing_page=URL) as fx:
            self.assertEqual(
                self.session(fx),
                [("bind", "rndis", False), ("bind", "ecm", True), ("medium", True)],
            )

    def test_host_silent_on_both_ends_on_rndis_for_good(self):
        with Fixture(Host(), landing_page=URL) as fx:
            self.assertEqual(
                self.session(fx),
                [("bind", "rndis", False), ("bind", "ecm", True), ("bind", "rndis", True), ("medium", True)],
            )
            self.assertTrue(fx.nf.rndis_final)
            self.assertGreaterEqual(fx.st.now, dyn.PROBE_SECONDS + dyn.ECM_SECONDS)

    def test_no_ecm_function_keeps_rndis(self):
        with Fixture(Host(), ecm="") as fx:
            self.assertEqual(self.session(fx), [("bind", "rndis", False), ("medium", True)])

    def test_slow_windows_recovers_after_ecm_detour(self):
        """RNDIS driver comes up only after the ECM detour: RNDIS stays and the medium follows."""
        host = Host(talks=[])
        with Fixture(host, landing_page=URL) as fx:
            self.session(fx)  # ends on RNDIS for good, host still silent
            binds = len(fx.events)
            host.talks.add("rndis")
            fx.nf.serve()  # re-check after the host reconfigures (bus reset by the new driver)
            self.assertEqual(fx.events[binds:], [("medium", True)])
            self.assertEqual(fx.nf.net, "rndis")

    def test_suspend_does_not_consume_probe_budget(self):
        with Fixture(Host(), events=["suspended"] * 40 + ["configured"], ecm="") as fx:
            fx.nf.bind("rndis", False)
            self.assertEqual(fx.nf.wait_evidence(dyn.PROBE_SECONDS, fx.nf.rndis_evidence), "silent")
            self.assertGreater(fx.st.now, 14)

    def test_unplug_during_probe_is_a_link_event(self):
        host = Host()
        with Fixture(host) as fx:
            fx.nf.bind("rndis", False)

            def unplug(_timeout):
                host.plugged = False

            fx.st.wait = unplug
            self.assertEqual(fx.nf.wait_evidence(dyn.PROBE_SECONDS, fx.nf.rndis_evidence), "link event")


class DetachTests(unittest.TestCase):
    def test_reset_keeps_final_layout_and_unplug_restores_probe_layout(self):
        host = Host(talks=["rndis"])
        with Fixture(host, landing_page=URL) as fx:
            fx.nf.bind("rndis", True)
            fx.nf.rndis_final = True
            # bus reset: carrier drops and comes back before DETACH_SECONDS
            host.plugged = False
            fx.st.events = iter(["default"])
            calls = []

            def wait(timeout):
                calls.append(timeout)
                fx.st.now += timeout
                host.plugged = True  # host reconfigured

            fx.st.wait = wait
            self.assertTrue(fx.nf.wait_configured(dyn.DETACH_SECONDS))
            self.assertEqual(fx.events, [("bind", "rndis", True)])
            # unplug: nothing reconfigures within DETACH_SECONDS
            host.plugged = False
            fx.st.wait = lambda timeout: setattr(fx.st, "now", fx.st.now + timeout)
            self.assertFalse(fx.nf.wait_configured(dyn.DETACH_SECONDS))
            # run() then restores the probe layout and forgets the ECM failure
            fx.nf.rndis_final = False
            fx.nf.bind("rndis", False)
            self.assertEqual(fx.events[-1], ("bind", "rndis", False))

    def test_switch_reports_missing_host(self):
        host = Host(configures=())
        with Fixture(host, events=["default"] * 100) as fx:
            self.assertFalse(fx.nf.switch("ecm", False))
            self.assertGreaterEqual(fx.st.now, dyn.ENUM_SECONDS)


class ConfigfsTests(unittest.TestCase):
    """bind() against a temporary configfs-like tree."""

    def make_tree(self, tmp, winusb=True):
        g = Path(tmp) / "g1"
        for fn in ("rndis.usb0", "ecm.usb0", "mass_storage.usb0", "ffs.wbwinusb"):
            (g / "functions" / fn).mkdir(parents=True)
        (g / "functions/mass_storage.usb0/lun.0").mkdir()
        (g / "functions/mass_storage.usb0/lun.0/file").write_text("")
        (g / "functions/rndis.usb0/ifname").write_text("dbg0\n")
        (g / "functions/ecm.usb0/ifname").write_text("dbge0\n")
        (g / "configs/c.1").mkdir(parents=True)
        (g / "configs/c.1/rndis.usb0").symlink_to(g / "functions/rndis.usb0")  # stale link
        (g / "os_desc").mkdir()
        (g / "os_desc/use").write_text("1")
        (g / "msos20").mkdir()
        (g / "msos20/use").write_text("1")
        (g / "webusb").mkdir()
        (g / "webusb/landingPage").write_text("")
        (g / "UDC").write_text("")
        return g

    def bind(self, g, net, url_visible, winusb="ffs.wbwinusb", udc_writes=None):
        nf = dyn.NetFunc("udc0", None)
        nf.medium = True  # a previous layout had the medium in: bind() must eject it first
        real_write = dyn.write
        writes = []

        def write(path, value):
            writes.append((os.path.relpath(path, g), value))
            if path.endswith("/UDC") and value and udc_writes is not None:
                udc_writes(value)
            real_write(path, value)

        with patch.object(dyn, "G", str(g)), patch.object(dyn, "LANDING_PAGE", URL), patch.object(
            dyn, "WINUSB_FUNCTION", winusb
        ), patch.object(dyn, "write", write), patch.object(dyn, "rx_packets", lambda net: 0):
            nf.bind(net, url_visible)
        return nf, writes

    def links(self, g):
        return sorted(os.listdir(g / "configs/c.1"))

    def test_ecm_layout_links_and_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            g = self.make_tree(tmp)
            nf, writes = self.bind(g, "ecm", True)
            self.assertEqual(self.links(g), ["ecm.usb0", "ffs.wbwinusb", "mass_storage.usb0"])
            self.assertEqual((g / "os_desc/use").read_text(), "0")
            self.assertEqual((g / "msos20/use").read_text(), "0")
            self.assertEqual((g / "webusb/landingPage").read_text(), URL + "\n")
            self.assertEqual((g / "UDC").read_text(), "udc0")
            # medium out and UDC unbound before relinking, UDC bound last
            self.assertEqual(writes[0], ("functions/mass_storage.usb0/lun.0/file", ""))
            self.assertEqual(writes[1], ("UDC", ""))
            self.assertEqual(writes[-1], ("UDC", "udc0"))
            self.assertEqual((nf.net, nf.url_visible), ("ecm", True))

    def test_rndis_probe_layout_hides_url_and_keeps_ms_os(self):
        with tempfile.TemporaryDirectory() as tmp:
            g = self.make_tree(tmp)
            self.bind(g, "rndis", False)
            self.assertEqual(self.links(g), ["ffs.wbwinusb", "mass_storage.usb0", "rndis.usb0"])
            self.assertEqual((g / "os_desc/use").read_text(), "1")
            self.assertEqual((g / "webusb/landingPage").read_text(), "\n")

    def test_layout_without_winusb_function(self):
        with tempfile.TemporaryDirectory() as tmp:
            g = self.make_tree(tmp)
            self.bind(g, "rndis", False, winusb="")
            self.assertEqual(self.links(g), ["mass_storage.usb0", "rndis.usb0"])

    def test_bind_retries_without_winusb_on_enodev(self):
        with tempfile.TemporaryDirectory() as tmp:
            g = self.make_tree(tmp)
            attempts = []

            def udc(value):
                attempts.append(value)
                if len(attempts) == 1:
                    raise OSError(dyn.errno.ENODEV, "functionfs not ready")

            self.bind(g, "rndis", False, udc_writes=udc)
            self.assertEqual(len(attempts), 2)
            self.assertEqual(self.links(g), ["mass_storage.usb0", "rndis.usb0"])

    def test_other_bind_errors_propagate(self):
        with tempfile.TemporaryDirectory() as tmp:
            g = self.make_tree(tmp)

            def udc(_value):
                raise OSError(dyn.errno.EBUSY, "busy")

            with self.assertRaises(OSError):
                self.bind(g, "rndis", False, udc_writes=udc)

    def test_medium_writes_only_on_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            g = self.make_tree(tmp)
            nf = dyn.NetFunc("udc0", None)
            with patch.object(dyn, "G", str(g)), patch.object(dyn, "IMAGE_FILE", "/img"):
                nf.set_medium(True)
                nf.set_medium(True)
                self.assertEqual((g / "functions/mass_storage.usb0/lun.0/file").read_text(), "/img")
                nf.set_medium(False)
                self.assertEqual((g / "functions/mass_storage.usb0/lun.0/file").read_text(), "")


class HelperTests(unittest.TestCase):
    def test_proc_state_and_missing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rndis"
            with patch.object(dyn, "RNDIS_STATE_FILE", str(path)):
                self.assertFalse(dyn.rndis_initialized())
                for state, expected in (
                    ("RNDIS_UNINITIALIZED", False),
                    ("RNDIS_INITIALIZED", True),
                    ("RNDIS_DATA_INITIALIZED", True),
                    ("unknown", False),
                ):
                    path.write_text(f"used : y\nstate     : {state}\n")
                    self.assertEqual(dyn.rndis_initialized(), expected)

    def test_state_file_is_not_guessed_with_several_instances(self):
        with patch.object(dyn, "RNDIS_STATE_FILE", None):
            with patch.object(dyn.glob, "glob", return_value=["/proc/driver/rndis-000"]):
                self.assertEqual(dyn.rndis_state_file(), "/proc/driver/rndis-000")
            with patch.object(
                dyn.glob, "glob", return_value=["/proc/driver/rndis-000", "/proc/driver/rndis-001"]
            ):
                self.assertIsNone(dyn.rndis_state_file())
            with patch.object(dyn.glob, "glob", return_value=[]):
                self.assertIsNone(dyn.rndis_state_file())

    def test_netdev_and_counters_from_configfs_and_sysfs(self):
        with tempfile.TemporaryDirectory() as tmp:
            g = Path(tmp) / "g1"
            (g / "functions/rndis.usb0").mkdir(parents=True)
            (g / "functions/ecm.usb0").mkdir(parents=True)
            (g / "functions/rndis.usb0/ifname").write_text("dbg%d\n")  # before the first bind
            with patch.object(dyn, "G", str(g)):
                self.assertIsNone(dyn.netdev("rndis"))
                self.assertIsNone(dyn.netdev("ecm"))  # unreadable, logged once
                self.assertFalse(dyn.carrier("rndis"))
                self.assertEqual(dyn.rx_packets("rndis"), 0)
                (g / "functions/rndis.usb0/ifname").write_text("dbg0\n")
                self.assertEqual(dyn.netdev("rndis"), "dbg0")
                self.assertEqual(dyn.rx_packets("rndis"), 0)  # /sys/class/net/dbg0 absent here


if __name__ == "__main__":
    unittest.main()
