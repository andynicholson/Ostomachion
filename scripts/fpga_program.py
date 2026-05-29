#!/usr/bin/env python3
# Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
#
# Program an XEM7310 FPGA via the Opal Kelly FrontPanel Python API.

import argparse
import os
import sys

import ok

ERROR_NAMES = {
    0: "NoError",
    -1: "Failed",
    -2: "Timeout",
    -3: "DoneNotHigh",
    -4: "TransferError",
    -5: "CommunicationError",
    -6: "InvalidBitStream",
    -7: "FileError",
    -8: "DeviceNotOpen",
}


def main():
    parser = argparse.ArgumentParser(description="Program XEM7310 FPGA via FrontPanel USB")
    parser.add_argument("bitfile", help="Path to .bit bitstream file")
    parser.add_argument("--serial", default="", help="Device serial number (default: first found)")
    args = parser.parse_args()

    if not os.path.isfile(args.bitfile):
        print(f"ERROR: Bitstream file not found: {args.bitfile}", file=sys.stderr)
        sys.exit(1)

    dev = ok.FrontPanel()
    n = dev.GetDeviceCount()
    if n == 0:
        print("ERROR: No Opal Kelly device found — check USB connection", file=sys.stderr)
        sys.exit(1)

    serial = args.serial or dev.GetDeviceListSerial(0)
    rc = dev.OpenBySerial(serial)
    if rc != ok.FrontPanel.NoError:
        print(f"ERROR: OpenBySerial failed: {ERROR_NAMES.get(rc, rc)} (code {rc})", file=sys.stderr)
        sys.exit(1)

    print(f"Device : {dev.GetDeviceID()}")
    print(f"Serial : {dev.GetSerialNumber()}")
    print(f"Board  : model code {dev.GetBoardModel()}")
    print(f"FW ver : {dev.GetDeviceMajorVersion()}.{dev.GetDeviceMinorVersion()}")
    print(f"Bitfile: {args.bitfile} ({os.path.getsize(args.bitfile)} bytes)")

    rc = dev.ConfigureFPGA(args.bitfile)
    if rc != ok.FrontPanel.NoError:
        name = ERROR_NAMES.get(rc, "Unknown")
        print(f"\nERROR: ConfigureFPGA → {name} (code {rc})", file=sys.stderr)
        if rc == -3:
            print("  DoneNotHigh: FPGA DONE pin did not assert after configuration.", file=sys.stderr)
            print("  Possible causes:", file=sys.stderr)
            print("    - Bitstream targets wrong FPGA part (check xc7a200t vs xc7a75t)", file=sys.stderr)
            print("    - Board model mismatch (see model code above)", file=sys.stderr)
            print("    - USB transfer issue — try unplugging and replugging USB-C", file=sys.stderr)
        sys.exit(1)

    print("FPGA configured successfully")


if __name__ == "__main__":
    main()
