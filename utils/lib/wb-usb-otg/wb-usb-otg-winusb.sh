#!/bin/bash
# Empty vendor interface (class 0xFF, zero endpoints) carrying MS OS descriptors.
#
# Chromium on Windows sends the WebUSB GET_URL request only through an interface bound
# to WinUSB (OpenInterfaceForControlTransfer() in usb_device_handle_win.cc). RNDIS +
# mass storage has no such function, and the RNDIS compat ID cannot be repurposed -
# the network relies on it.
#
# An Extended Compat ID ("WINUSB") alone is not enough: Windows loads WinUSB but,
# without a DeviceInterfaceGUID, creates no device interface, so Chrome gets no device
# path (GetFunctionInfo() in usb_service_win.cc looks the GUID up in the registry).
# Hence the Extended Properties feature (wIndex=5) is included as well.
#
# Encoding: the property name and data are stored as UTF-8, with lengths in UTF-8 bytes.
# The kernel converts them to UTF-16 and doubles the lengths itself
# (f_fs.c: ext_prop->name_len *= 2).
#
# FunctionFS requires ep0 to stay open for the whole lifetime of the function, hence
# the process that blocks forever (~292 KB of private memory).

set -e

FFS_NAME="wbwinusb"
FFS_DIR="/dev/ffs-${FFS_NAME}"
USBGADGET_CONFIG=/sys/kernel/config/usb_gadget/g1

# FunctionFS descriptor blob, format v2 (include/uapi/linux/usb/functionfs.h), 161 bytes.
# Generated statically; keep FFS_DESCS_LEN in sync if you ever change it. Layout:
#
#   03 00 00 00              magic  = FUNCTIONFS_DESCRIPTORS_MAGIC_V2 (3)
#   a1 00 00 00              length = 161 (whole blob)
#   0b 00 00 00              flags  = HAS_FS_DESC|HAS_HS_DESC|HAS_MS_OS_DESC (1|2|8)
#   01 00 00 00              fs_count = 1
#   01 00 00 00              hs_count = 1
#   02 00 00 00              os_count = 2 (two MS OS 1.0 feature descriptors)
#
#   full-speed interface descriptor:
#   09 04 00 00 00 ff 00 00 00   bLength=9, bDescriptorType=4 (INTERFACE),
#                                bInterfaceNumber=0, bAlternateSetting=0, bNumEndpoints=0,
#                                bInterfaceClass=0xFF (vendor), subclass=0, protocol=0, iInterface=0
#   high-speed interface descriptor (identical 9 bytes):
#   09 04 00 00 00 ff 00 00 00
#
#   MS OS 1.0 Extended Compat ID (usb_os_desc_header + one function):
#   00                       interface = 0
#   23 00 00 00              dwLength = 35
#   00 01                    bcdVersion = 0x0100
#   04 00                    wIndex = 4 (Extended Compat ID)
#   01 00                    bCount = 1, reserved
#   00 01                    bFirstInterfaceNumber = 0, reserved (=1)
#   57 49 4e 55 53 42 00 00  CompatibleID = "WINUSB"
#   00 00 00 00 00 00 00 00  SubCompatibleID = (none)
#   00 00 00 00 00 00        reserved[6]
#
#   MS OS 1.0 Extended Properties (registry property = DeviceInterfaceGUID):
#   00                       interface = 0
#   54 00 00 00              dwLength = 84
#   00 01                    bcdVersion = 0x0100
#   05 00                    wIndex = 5 (Extended Properties)
#   01 00                    bCount = 1, reserved
#   49 00 00 00              dwSize = 73 (this property)
#   01 00 00 00              dwPropertyDataType = 1 (REG_SZ)
#   14 00                    wPropertyNameLength = 20 (bytes; kernel doubles to UTF-16)
#   44 65 ... 44 00          name = "DeviceInterfaceGUID\0" (ASCII, kernel -> UTF-16LE)
#   27 00 00 00              dwPropertyDataLength = 39
#   7b 39 ... 7d 00          data = "{9E3C1B4A-7D52-4F86-A1C9-2B7E5D8F3A61}\0" (ASCII -> UTF-16LE)
FFS_DESCS='\x03\x00\x00\x00\xa1\x00\x00\x00\x0b\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x09\x04\x00\x00\x00\xff\x00\x00\x00\x09\x04\x00\x00\x00\xff\x00\x00\x00\x00\x23\x00\x00\x00\x00\x01\x04\x00\x01\x00\x00\x01\x57\x49\x4e\x55\x53\x42\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x54\x00\x00\x00\x00\x01\x05\x00\x01\x00\x49\x00\x00\x00\x01\x00\x00\x00\x14\x00\x44\x65\x76\x69\x63\x65\x49\x6e\x74\x65\x72\x66\x61\x63\x65\x47\x55\x49\x44\x00\x27\x00\x00\x00\x7b\x39\x45\x33\x43\x31\x42\x34\x41\x2d\x37\x44\x35\x32\x2d\x34\x46\x38\x36\x2d\x41\x31\x43\x39\x2d\x32\x42\x37\x45\x35\x44\x38\x46\x33\x41\x36\x31\x7d\x00'
FFS_DESCS_LEN=161
FFS_STRINGS='\x02\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
FFS_STRINGS_LEN=16

log() { >&2 echo "wb-usb-otg-winusb: $*"; }

modprobe -q usb_f_fs || true
mkdir -p "${USBGADGET_CONFIG}/functions/ffs.${FFS_NAME}"
mkdir -p "${FFS_DIR}"
mountpoint -q "${FFS_DIR}" && umount "${FFS_DIR}"
mount -t functionfs "${FFS_NAME}" "${FFS_DIR}"

exec 3<>"${FFS_DIR}/ep0"

# The blob must be delivered in a single write(): ffs_ep0_write() parses it all at once.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%b' "${FFS_DESCS}" > "$tmp"
dd if="$tmp" bs=${FFS_DESCS_LEN} count=1 status=none >&3
printf '%b' "${FFS_STRINGS}" > "$tmp"
dd if="$tmp" bs=${FFS_STRINGS_LEN} count=1 status=none >&3
rm -f "$tmp"; trap - EXIT

log "ffs.${FFS_NAME} function is ready"
systemd-notify --ready 2>/dev/null || true

hold=$(mktemp -u)
mkfifo "$hold"
exec 4<>"$hold"
rm -f "$hold"
read -r <&4
