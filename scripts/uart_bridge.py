#!/usr/bin/env python3
"""FrontPanel UART-over-USB bridge for the XEM7310 Ostomachion platform.

Creates a pseudo-terminal (PTY) that can be used by minicom or the NEORV32
bootloader upload script as if it were a real serial port.  Data is shuttled
between the PTY and the FPGA's FrontPanel Block-Throttled Pipe endpoints.

The BTPipe endpoints provide hardware flow control: the host-side API blocks
until the FPGA signals readiness (TX FIFO not full / RX FIFO not empty),
eliminating the need for software rate-limiting.

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
    WireIn    0x00  [15:0] baud divisor, [16] UART source (0=bridge, 1=MC1)
    WireOut   0x20  [10:0] RX FIFO entry count
    BTPipeIn  0x80  host → NEORV32 UART data  (block-throttled, ep_ready = not full)
    BTPipeOut 0xA0  NEORV32 UART data → host  (block-throttled, ep_ready = not empty)
"""

import argparse
import errno
import os
import select
import signal
import sys
import time
import tty

SYS_CLK_HZ = 100_000_000
PID_FILE = "/tmp/uart_bridge.pid"

EP_WIREIN_CFG  = 0x00
EP_WIREOUT_CNT = 0x20
EP_PIPEIN_TX   = 0x80
EP_PIPEOUT_RX  = 0xA0

PIPE_WORD_BYTES = 4
BT_BLOCK_SIZE = 1024  # BTPipe block size (USB 3.0, power-of-2, 16..16384)


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


def read_uart_bytes(dev) -> bytes:
    """Read UART bytes from BTPipeOut 0xA0.

    Reads one block (BT_BLOCK_SIZE bytes).  The BTPipeOut only transfers
    when ep_ready is high (RX FIFO not empty), so this call blocks in the
    host API until there is data.  Each 32-bit pipe word carries a valid
    flag in bit 8 and the UART byte in [7:0]; padding words have bit 8 = 0.
    """
    buf = bytearray(BT_BLOCK_SIZE)
    dev.ReadFromBlockPipeOut(EP_PIPEOUT_RX, BT_BLOCK_SIZE, buf)
    result = []
    for i in range(0, len(buf), PIPE_WORD_BYTES):
        if buf[i + 1] & 0x01:
            result.append(buf[i])
    return bytes(result)


def write_uart_bytes(dev, data: bytes, debug: bool = False):
    """Write UART bytes to BTPipeIn 0x80.

    Each byte is packed into a 32-bit pipe word in bits [7:0] with the
    valid flag set in bit 8.  The buffer is padded to a multiple of
    BT_BLOCK_SIZE.  The BTPipeIn endpoint has hardware flow control:
    the host API blocks until ep_ready (TX FIFO not full) is asserted
    by the FPGA, so no software rate-limiting is needed.
    """
    if not data:
        return
    n = len(data)
    raw_size = n * PIPE_WORD_BYTES
    padded_size = ((raw_size + BT_BLOCK_SIZE - 1) // BT_BLOCK_SIZE) * BT_BLOCK_SIZE
    buf = bytearray(padded_size)
    for i, b in enumerate(data):
        offset = i * PIPE_WORD_BYTES
        buf[offset] = b
        buf[offset + 1] = 0x01  # valid-byte flag (bit 8)
    t0 = time.monotonic()
    rc = dev.WriteToBlockPipeIn(EP_PIPEIN_TX, BT_BLOCK_SIZE, buf)
    dt = time.monotonic() - t0
    if debug:
        print(f"[TX] {n} byte(s), buf={padded_size}, rc={rc}, dt={dt*1000:.1f}ms")


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
    parser.add_argument("--baud-after", type=int, default=None, metavar="BAUD",
                        help="Switch to this baud rate on SIGUSR1 (e.g. 115200)")
    parser.add_argument("--program", type=str, default=None, metavar="BITFILE",
                        help="Program FPGA with this bitstream before bridging")
    parser.add_argument("--debug", action="store_true",
                        help="Print TX/RX debug traces")
    args = parser.parse_args()

    dev = open_device(args.serial)

    # SIGUSR1 triggers a baud rate switch when --baud-after is set.
    baud_switch_pending = [False]

    def _handle_sigusr1(signum, frame):
        baud_switch_pending[0] = True

    if args.baud_after is not None:
        signal.signal(signal.SIGUSR1, _handle_sigusr1)

    # Create PTY first so minicom can connect before the FPGA is programmed.
    # Keep slave_fd open so writes to master_fd are buffered in the kernel
    # even before minicom opens the slave path.  Closing it early causes
    # writes to return EIO and the bootloader banner would be lost.
    master_fd, slave_fd = os.openpty()
    tty.setraw(slave_fd)
    slave_name = os.ttyname(slave_fd)

    print(f"\n{'='*60}")
    print(f"  PTY ready: {slave_name}")
    print(f"  Connect with:  minicom -D {slave_name} -b {args.baud}")
    if args.baud_after:
        print(f"  Baud will switch to {args.baud_after} on SIGUSR1")
    if args.program:
        print(f"  FPGA will be programmed after PTY is ready.")
    print(f"  Press Ctrl-C to stop.")
    print(f"{'='*60}\n")
    sys.stdout.flush()

    # Write PID file so external scripts (e.g. make fpga-fw) can signal us.
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    if args.program:
        if not program_fpga(dev, args.program):
            os.close(master_fd)
            os.close(slave_fd)
            os.unlink(PID_FILE)
            sys.exit(1)

    current_baud = args.baud
    set_baud(dev, current_baud, args.uart_src)

    try:
        while True:
            if baud_switch_pending[0]:
                baud_switch_pending[0] = False
                current_baud = args.baud_after
                print(f"\n>>> Switching baud to {current_baud} (SIGUSR1 received)")
                set_baud(dev, current_baud, args.uart_src)
                sys.stdout.flush()

            # RX: check FIFO count first to avoid blocking on an empty BTPipeOut.
            rx_data = b""
            rx_count = get_rx_count(dev)
            if rx_count > 0:
                rx_data = read_uart_bytes(dev)
                if rx_data:
                    if args.debug:
                        print(f"[RX] {len(rx_data)} byte(s): {list(rx_data)}")
                    try:
                        os.write(master_fd, rx_data)
                    except OSError as e:
                        if e.errno != errno.EIO:
                            raise

            # TX: read from PTY and send via BTPipeIn.
            # WriteToBlockPipeIn blocks until ep_ready (TX FIFO not full),
            # providing hardware flow control — no software rate-limiting.
            rd_ready, _, _ = select.select([master_fd], [], [], 0)
            tx_sent = False
            if rd_ready:
                try:
                    chunk = os.read(master_fd, 256)
                    if chunk:
                        write_uart_bytes(dev, chunk, debug=args.debug)
                        tx_sent = True
                except OSError as e:
                    if e.errno != errno.EIO:
                        raise

            if not rx_data and not tx_sent:
                time.sleep(0.001)

    except KeyboardInterrupt:
        print("\nBridge stopped.")
    finally:
        os.close(master_fd)
        os.close(slave_fd)
        try:
            os.unlink(PID_FILE)
        except OSError:
            pass


if __name__ == "__main__":
    main()
