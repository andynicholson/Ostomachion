#!/usr/bin/env python3
"""Upload a NEORV32 executable binary via the bootloader UART protocol.

Replaces the upstream uart_upload.sh for PTY-based serial ports (e.g. the
FrontPanel UART bridge) where the pipeline latency makes fixed-sleep timing
unreliable.  This script waits for actual bootloader responses with a
configurable timeout instead of sleeping a fixed number of seconds.

Protocol:
    1. Send a space to abort the auto-boot countdown.
    2. Send 'u' — bootloader prints "Awaiting neorv32_exe.bin".
    3. Stream the binary file.
    4. Bootloader replies "OK" on success.
    5. Send 'e' to execute the uploaded image.

Usage:
    python3 scripts/uart_upload.py /dev/pts/4 build/.../zephyr_exe.bin
    python3 scripts/uart_upload.py --timeout 120 /dev/ttyUSB0 firmware.bin
"""

import argparse
import os
import select
import sys
import termios
import time
import tty


CHUNK_SIZE = 256
DEFAULT_TIMEOUT = 120  # seconds — 120KB @ 19200 baud ≈ 63s


def configure_port(fd: int, baud: int = 19200):
    """Set the terminal to raw mode at the given baud rate."""
    baud_const = getattr(termios, f"B{baud}", None)
    if baud_const is None:
        print(f"ERROR: unsupported baud rate {baud}", file=sys.stderr)
        sys.exit(1)
    attrs = termios.tcgetattr(fd)
    attrs[4] = baud_const  # ispeed
    attrs[5] = baud_const  # ospeed
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    tty.setraw(fd)


def drain(fd: int, timeout: float = 0.3) -> bytes:
    """Read all available data from fd until idle for *timeout* seconds."""
    buf = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        rd, _, _ = select.select([fd], [], [], remaining)
        if rd:
            data = os.read(fd, 4096)
            if data:
                buf.extend(data)
                deadline = time.monotonic() + timeout
            else:
                break
        else:
            break
    return bytes(buf)


def wait_for(fd: int, needle: bytes, timeout: float) -> tuple[bool, bytes]:
    """Read from fd until *needle* appears or *timeout* expires.

    Returns (found, accumulated_data).
    """
    buf = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False, bytes(buf)
        rd, _, _ = select.select([fd], [], [], min(remaining, 0.1))
        if rd:
            data = os.read(fd, 4096)
            if data:
                buf.extend(data)
                if needle in buf:
                    return True, bytes(buf)
            else:
                return False, bytes(buf)
    return False, bytes(buf)


def main():
    parser = argparse.ArgumentParser(
        description="Upload NEORV32 executable via bootloader UART")
    parser.add_argument("device", help="Serial device (e.g. /dev/pts/4)")
    parser.add_argument("binary", help="Path to neorv32_exe.bin")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help=f"Max seconds to wait for upload OK (default: {DEFAULT_TIMEOUT})")
    parser.add_argument("--baud", type=int, default=19200,
                        help="Baud rate (default: 19200)")
    args = parser.parse_args()

    if not os.path.isfile(args.binary):
        print(f"ERROR: binary not found: {args.binary}", file=sys.stderr)
        sys.exit(1)

    bin_size = os.path.getsize(args.binary)
    est_seconds = bin_size / (args.baud / 10)  # 10 bits per byte

    fd = os.open(args.device, os.O_RDWR | os.O_NOCTTY)
    try:
        configure_port(fd, args.baud)

        # Abort auto-boot (retry: the FrontPanel USB-pipe round-trip can exceed
        # the old fixed 5s, and a single stray byte can desync the prompt).
        found = False
        for attempt in range(3):
            os.write(fd, b" ")
            drain(fd, timeout=0.5)
            os.write(fd, b"u")
            found, resp = wait_for(fd, b"Awaiting neorv32_exe.bin", timeout=20.0)
            if found:
                break
            print(f"  (retry {attempt+1}: no Awaiting yet)", file=sys.stderr)
            time.sleep(0.3)
            drain(fd, timeout=1.0)
        if not found:
            print("Bootloader response error!", file=sys.stderr)
            print("Reset processor before starting the upload.", file=sys.stderr)
            sys.exit(1)

        # Stream binary
        print(f"Uploading executable ({bin_size} bytes, ~{est_seconds:.0f}s)...",
              end="", flush=True)

        with open(args.binary, "rb") as f:
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                os.write(fd, chunk)

        # Wait for bootloader "OK" — the PTY pipeline may still be draining
        upload_timeout = max(args.timeout, est_seconds + 30)
        found, resp = wait_for(fd, b"OK", timeout=upload_timeout)
        if not found:
            print(" FAILED!", flush=True)
            sys.exit(1)

        print(" OK", flush=True)

        # Execute
        print("Starting application...")
        os.write(fd, b"e")
        time.sleep(0.2)

    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
