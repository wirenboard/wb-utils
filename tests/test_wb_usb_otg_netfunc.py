"""Host-independent regressions for wb-usb-otg-netfunc.py; no configfs or USB hardware needed.

Run: python3 -m unittest discover -s tests
"""

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "netfunc", Path(__file__).resolve().parents[1] / "utils/lib/wb-usb-otg/wb-usb-otg-netfunc.py"
)
dyn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dyn)


class FakeState:
    def __init__(self, events=()):
        self.value = "configured"
        self.events = iter(events)
        self.now = 0

    def connected(self):
        return self.value in ("configured", "suspended")

    def wait(self, timeout):
        self.now += timeout
        self.value = next(self.events, "configured")


class ProbeTests(unittest.TestCase):
    def run_probe(self, st, packets=0, initialized=False, baseline=0):
        with patch.object(dyn, "rx_packets", return_value=packets), patch.object(
            dyn, "rndis_initialized", return_value=initialized
        ), patch.object(dyn.time, "monotonic", side_effect=lambda: st.now):
            return dyn.probe(st, baseline)

    def test_handshake_without_network_packets(self):
        self.assertEqual(self.run_probe(FakeState(), initialized=True), ("rndis", 0))

    def test_packet_arriving_before_probe_is_evidence(self):
        self.assertEqual(self.run_probe(FakeState(), packets=8, baseline=7), ("rndis", 0))

    def test_old_packets_are_not_evidence(self):
        self.assertEqual(self.run_probe(FakeState(), packets=7, baseline=7), ("silent", 4))

    def test_suspend_does_not_consume_probe_budget(self):
        st = FakeState(["suspended"] * 40 + ["configured"])
        self.assertEqual(self.run_probe(st), ("silent", 4))
        self.assertGreater(st.now, 14)

    def test_disconnect_aborts_probe(self):
        self.assertEqual(self.run_probe(FakeState(["not attached"])), ("link event", 0))


class RndisStateTests(unittest.TestCase):
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
        with patch.object(dyn, "RNDIS_STATE_FILE", ""):
            self.assertIsNone(dyn.rndis_state_file())


class LayoutTests(unittest.TestCase):
    def test_restart_in_ecm_restores_rndis_even_without_host(self):
        st = FakeState()
        st.value = "not attached"

        class StopAfterRebind(Exception):
            pass

        with patch.object(dyn.os, "listdir", return_value=["test-udc"]), patch.object(
            dyn, "UdcState", return_value=st
        ), patch.object(dyn, "saved_landing_page", return_value="https://wb.example/"), patch.object(
            dyn, "set_net_function", side_effect=StopAfterRebind
        ) as rebind:
            with self.assertRaises(StopAfterRebind):
                dyn.main()
            rebind.assert_called_once_with("rndis", landing_page="")

    def check_final_layout(self, verdict, url, expected_binds):
        class Done(Exception):
            pass

        events = []
        st = FakeState()

        def bind(mode, landing_page=None):
            events.append(("bind", mode, landing_page))
            st.value = "default"

        def wait(timeout=None):
            if st.value == "default":
                st.value = "configured"
            else:
                raise Done

        st.wait = wait
        with patch.object(dyn.os, "listdir", return_value=["test-udc"]), patch.object(
            dyn, "saved_landing_page", return_value=url
        ), patch.object(dyn, "UdcState", return_value=st), patch.object(
            dyn, "set_net_function", side_effect=bind
        ), patch.object(
            dyn, "probe", return_value=(verdict, 0.25)
        ), patch.object(
            dyn, "rx_packets", return_value=0
        ), patch.object(
            dyn, "rndis_initialized", return_value=verdict == "rndis"
        ), patch.object(
            dyn, "set_medium", side_effect=lambda v: events.append(("medium", v))
        ):
            with self.assertRaises(Done):
                dyn.main()
        self.assertEqual(events, expected_binds + [("medium", True)])

    def test_mac_gets_url_only_in_final_ecm_and_then_medium(self):
        self.check_final_layout(
            "silent", "https://wb.example/", [("bind", "rndis", ""), ("bind", "ecm", "https://wb.example/")]
        )

    def test_rndis_gets_one_final_url_without_reprobing(self):
        self.check_final_layout(
            "rndis", "https://wb.example/", [("bind", "rndis", ""), ("bind", "rndis", "https://wb.example/")]
        )

    def test_no_https_needs_no_second_rndis_enumeration(self):
        self.check_final_layout("rndis", "", [("bind", "rndis", "")])

    def test_unbind_tolerates_unbound_gadget(self):
        def enodev(path, value):
            raise OSError(dyn.errno.ENODEV, "not bound")

        with patch.object(dyn, "write", side_effect=enodev):
            dyn.unbind()
        with patch.object(dyn, "write", side_effect=OSError(dyn.errno.EACCES, "denied")):
            with self.assertRaises(OSError):
                dyn.unbind()


if __name__ == "__main__":
    unittest.main()
