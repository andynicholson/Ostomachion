#!/usr/bin/env python3
"""FrontPanel UART-over-USB bridge for the XEM7310 Ostomachion platform.

Creates a pseudo-terminal (PTY) that can be used by minicom or the NEORV32
bootloader upload script as if it were a real serial port.  Data is shuttled
between the PTY and the FPGA's FrontPanel Pipe endpoints.

Usage:
    python3 scripts/uart_bridge.py [--baud 19200] [--serial SERIAL]
    python3 scripts/uart_bridge.py --program build/xem7310/ostomachion_xem7310.bit

    # Then in another terminal:
    minicom -D /dev/pts/<N> -b 19200

With --program the script creates the PTY first, then programs the FPGA
and immediately starts bridging.  This avoids a race between fpga-program
and uart-bridge (both need exclusive FrontPanel USB access), and ensures
the bootloader banner is captured in the RX FIFO before the bridge loop
starts reading.

FrontPanel endpoint map (matching xem7310_top.vhd):
    WireIn  0x00  [15:0] baud divisor, [16] UART source (0=bridge, 1=MC1)
    WireOut 0x20  [10:0] RX FIFO entry count
    PipeIn  0x80  host → NEORV32 UART data
    PipeOut 0xA0  NEORV32 UART data → host
"""

import argparse
import errno
import os
import select
import sys
import time

SYS_CLK_HZ = 100_000_000

EP_WIREIN_CFG  = 0x00
EP_WIREOUT_CNT = 0x20
EP_PIPEIN_TX   = 0x80
EP_PIPEOUT_RX  = 0xA0

PIPE_WORD_BYTES = 4
PIPE_BLOCK_SIZE = 1024  # USB 3.0 bulk transfer alignment

MAX_PIPE_WORDS = 256


def baud_to_divisor(baud: int) -> int:
    return round(SYS_CLK_HZ / baud) - 1


def open_device(serial: str | None = None):
    """Open the first available Opal Kelly device (or a specific serial)."""
    try:
        import ok  # noqa: F811 — FrontPanel Python module
    except ImportError:
        print("ERROR: Cannot import the 'ok' module (FrontPanel Python API).",
              file=sys.stderr)
        print("       Install the FrontPanel SDK and ensure the 'ok' package",
              file=sys.stderr)
        print("       is on PYTHONPATH.", file=sys.stderr)
        sys.exit(1)

    dev = ok.FrontPanel()
    if serial:
        rc = dev.OpenBySerial(serial)
    else:
        if dev.GetDeviceCount() < 1:
            print("ERROR: No Opal Kelly device found — check USB connection.",
                  file=sys.stderr)
            sys.exit(1)
        rc = dev.OpenBySerial(dev.GetDeviceListSerial(0))

    if rc != ok.FrontPanel.NoError:
        print(f"ERROR: OpenBySerial failed (error code {rc}).", file=sys.stderr)
        sys.exit(1)

    print(f"Device : {dev.GetDeviceID()}")
    print(f"Serial : {dev.GetSerialNumber()}")
    print(f"FW ver : {dev.GetDeviceMajorVersion()}.{dev.GetDeviceMinorVersion()}")
    return dev


def set_baud(dev, baud: int, uart_src: int = 0):
    """Write the baud divisor and UART source select to WireIn 0x00."""
    divisor = baud_to_divisor(baud)
    value = (uart_src << 16) | (divisor & 0xFFFF)
    dev.SetWireInValue(EP_WIREIN_CFG, value)
    dev.UpdateWireIns()
    actual_baud = SYS_CLK_HZ / (divisor + 1)
    print(f"Baud   : {baud} (divisor={divisor}, actual={actual_baud:.0f})")


def get_rx_count(dev) -> int:
    """Read the RX FIFO entry count from WireOut 0x20."""
    dev.UpdateWireOuts()
    return dev.GetWireOutValue(EP_WIREOUT_CNT) & 0x7FF


def read_uart_bytes(dev, count: int) -> bytes:
    """Read `count` UART bytes from PipeOut 0xA0.

    Each pipe 32-bit word carries one byte in bits [7:0].  A transfer of
    `count` words requires `count * 4` API bytes.
    """
    if count <= 0:
        return b""
    n = min(count, MAX_PIPE_WORDS)
    buf = bytearray(n * PIPE_WORD_BYTES)
    dev.ReadFromPipeOut(EP_PIPEOUT_RX, buf)
    return bytes(buf[i] for i in range(0, len(buf), PIPE_WORD_BYTES))


def write_uart_bytes(dev, data: bytes, debug: bool = False):
    """Write UART bytes to PipeIn 0x80.

    Each byte is packed into a 32-bit pipe word in bits [7:0].
    The buffer is padded to a multiple of PIPE_BLOCK_SIZE because
    FrontPanel USB 3.0 transfers require block-aligned lengths.
    """
    if not data:
        return
    n = len(data)
    raw_size = n * PIPE_WORD_BYTES
    padded_size = ((raw_size + PIPE_BLOCK_SIZE - 1) // PIPE_BLOCK_SIZE) * PIPE_BLOCK_SIZE
    buf = bytearray(padded_size)
    for i, b in enumerate(data):
        offset = i * PIPE_WORD_BYTES
        buf[offset] = b
        buf[offset + 1] = 0x01  # valid-byte flag (bit 8)
    rc = dev.WriteToPipeIn(EP_PIPEIN_TX, buf)
    if debug:
        print(f"[TX] {n} byte(s) {list(data)}, buf={raw_size}→{padded_size}, rc={rc}")


def program_fpga(dev, bitfile: str):
    """Program the FPGA via FrontPanel and return True on success."""
    import ok

    if not os.path.isfile(bitfile):
        print(f"ERROR: Bitstream not found: {bitfile}", file=sys.stderr)
        return False

    print(f"Programming FPGA with {bitfile} "
          f"({os.path.getsize(bitfile)} bytes)...")
    rc = dev.ConfigureFPGA(bitfile)
    if rc != ok.FrontPanel.NoError:
        print(f"ERROR: ConfigureFPGA failed (error code {rc})", file=sys.stderr)
        return False

    print("FPGA configured successfully")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="FrontPanel UART-over-USB bridge for XEM7310")
    parser.add_argument("--baud", type=int, default=19200,
                        help="UART baud rate (default: 19200 for bootloader)")
    parser.add_argument("--serial", type=str, default=None,
                        help="Opal Kelly device serial number")
    parser.add_argument("--uart-src", type=int, default=0, choices=[0, 1],
                        help="UART source: 0=FrontPanel bridge, 1=MC1 pin")
    parser.add_argument("--program", type=str, default=None, metavar="BITFILE",
                        help="Program FPGA with this bitstream before bridging")
    parser.add_argument("--debug", action="store_true",
                        help="Print TX/RX debug traces")
    args = parser.parse_args()

    dev = open_device(args.serial)

    # Create PTY first so minicom can connect before the FPGA is programmed.
    # Keep slave_fd open so writes to master_fd are buffered in the kernel
    # even before minicom opens the slave path.  Closing it early causes
    # writes to return EIO and the bootloader banner would be lost.
    master_fd, slave_fd = os.openpty()
    slave_name = os.ttyname(slave_fd)

    print(f"\n{'='*60}")
    print(f"  PTY ready: {slave_name}")
    print(f"  Connect with:  minicom -D {slave_name} -b {args.baud}")
    if args.program:
        print(f"  FPGA will be programmed after PTY is ready.")
    print(f"  Press Ctrl-C to stop.")
    print(f"{'='*60}\n")
    sys.stdout.flush()

    if args.program:
        if not program_fpga(dev, args.program):
            os.close(master_fd)
            os.close(slave_fd)
            sys.exit(1)

    set_baud(dev, args.baud, args.uart_src)

    try:
        while True:
            rx_n = get_rx_count(dev)
            if rx_n > 0:
                rx_data = read_uart_bytes(dev, rx_n)
                if rx_data:
                    try:
                        os.write(master_fd, rx_data)
                    except OSError as e:
                        if e.errno != errno.EIO:
                            raise

            rd_ready, _, _ = select.select([master_fd], [], [], 0)
            if rd_ready:
                try:
                    tx_data = os.read(master_fd, 1024)
                    if tx_data:
                        if args.debug:
                            print(f"[PTY] read {len(tx_data)} byte(s): {list(tx_data)}")
                        write_uart_bytes(dev, tx_data, debug=args.debug)
                except OSError as e:
                    if e.errno != errno.EIO:
                        raise

            if rx_n == 0 and not rd_ready:
                time.sleep(0.001)

    except KeyboardInterrupt:
        print("\nBridge stopped.")
    finally:
        os.close(master_fd)
        os.close(slave_fd)


if __name__ == "__main__":
    main()
