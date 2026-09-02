#!/usr/bin/env python3
"""Build the MS OS 2.0 descriptor set for the Debug Network gadget.

Why: Windows 8.1+ reads MS OS 2.0 from the BOS and ignores MS OS 1.0. The set must
therefore describe EVERY function that needs a compat ID - otherwise RNDIS loses its
own and the network on the host breaks.

What it provides:
  * RNDIS  -> CompatibleID "RNDIS"/"5162001" (same as MS OS 1.0, network keeps working)
  * vendor -> CompatibleID "WINUSB" + DeviceInterfaceGUIDs

The latter is the only way to give Windows a DeviceInterfaceGUID for a function of a
composite device: Windows does not pick up MS OS 1.0 extended properties for it, and
the kernel cannot emit a REG_MULTI_SZ property at all (composite.c: type 7 -> -EINVAL).
Without a GUID the function has no device path and Chrome cannot open it
(usb_service_win.cc::GetFunctionInfo), so the WebUSB landing page is never read.
"""
import argparse, struct, sys

MS_OS_20_SET_HEADER_DESCRIPTOR      = 0x0000
MS_OS_20_SUBSET_HEADER_CONFIGURATION = 0x0001
MS_OS_20_SUBSET_HEADER_FUNCTION     = 0x0002
MS_OS_20_FEATURE_COMPATIBLE_ID      = 0x0003
MS_OS_20_FEATURE_REG_PROPERTY       = 0x0004
REG_MULTI_SZ                        = 7
WINDOWS_VERSION_8_1                 = 0x06030000


def compatible_id(cid: bytes, sub: bytes = b"") -> bytes:
    return struct.pack('<HH8s8s', 20, MS_OS_20_FEATURE_COMPATIBLE_ID,
                       cid.ljust(8, b'\0'), sub.ljust(8, b'\0'))


def reg_property_multi_sz(name: str, values) -> bytes:
    pname = (name + "\0").encode('utf-16-le')
    pdata = ("".join(v + "\0" for v in values) + "\0").encode('utf-16-le')
    total = 2 + 2 + 2 + 2 + len(pname) + 2 + len(pdata)
    return (struct.pack('<HHHH', total, MS_OS_20_FEATURE_REG_PROPERTY,
                        REG_MULTI_SZ, len(pname)) + pname
            + struct.pack('<H', len(pdata)) + pdata)


def function_subset(first_interface: int, features: bytes) -> bytes:
    return struct.pack('<HHBBH', 8, MS_OS_20_SUBSET_HEADER_FUNCTION,
                       first_interface, 0, 8 + len(features)) + features


def build(rndis_if: int, winusb_if: int, guid: str, config_index: int = 0) -> bytes:
    subsets = function_subset(rndis_if, compatible_id(b"RNDIS", b"5162001"))
    subsets += function_subset(winusb_if,
                               compatible_id(b"WINUSB")
                               + reg_property_multi_sz("DeviceInterfaceGUIDs", [guid]))
    cfg = struct.pack('<HHBBH', 8, MS_OS_20_SUBSET_HEADER_CONFIGURATION,
                      config_index, 0, 8 + len(subsets)) + subsets
    return struct.pack('<HHIH', 10, MS_OS_20_SET_HEADER_DESCRIPTOR,
                       WINDOWS_VERSION_8_1, 10 + len(cfg)) + cfg


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rndis-interface', type=int, default=0)
    ap.add_argument('--winusb-interface', type=int, required=True)
    ap.add_argument('--guid', required=True, help='{XXXXXXXX-XXXX-...}')
    ap.add_argument('-o', '--output', required=True, help='file to write the descriptor set to')
    a = ap.parse_args()

    if not (a.guid.startswith('{') and a.guid.endswith('}') and len(a.guid) == 38):
        sys.exit("GUID must look like {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}")

    blob = build(a.rndis_interface, a.winusb_interface, a.guid)
    # the kernel validates exactly this, so cross-check it ourselves
    assert struct.unpack_from('<H', blob, 8)[0] == len(blob)
    with open(a.output, 'wb') as f:
        f.write(blob)
    print("%s: %d bytes (RNDIS=if%d, WinUSB=if%d)"
          % (a.output, len(blob), a.rndis_interface, a.winusb_interface))


if __name__ == '__main__':
    main()
