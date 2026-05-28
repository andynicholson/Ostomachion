"""FrontPanel transport for the FFT accelerator demo.

Wraps the Opal Kelly `ok.FrontPanel` API and presents a simple per-frame
RPC:

    transport = FrontPanelFftTransport()
    transport.open()
    transport.send_frame(samples)             # 4096 × packed uint32
    out, hw_cycles, frame_n = transport.recv_frame(timeout_s=2.0)
    transport.close()

Endpoints (must match xem7310_top.vhd + fp_fft_pipe_bridge.vhd):

    BTPipeIn   0x81 — host → fifo_in  (4096 × 32 b per frame)
    BTPipeOut  0xA1 — fifo_out → host (4096 × 32 b per frame)
    WireOut    0x24 — { fifo_out_count[15:0], fifo_in_count[15:0] }
    WireOut    0x25 — hw_cycles[31:0]
    WireOut    0x26 — frame_counter[31:0]

Frame ordering contract:

The firmware publishes hw_cycles BEFORE filling fifo_out, so reading
WireOut 0x25 after seeing fifo_out_count >= FFT_N is guaranteed to
return the matching frame's cycle count.
"""

from __future__ import annotations

import os
import sys
import time
from dataclasses import dataclass


def _bootstrap_frontpanel_path() -> None:
    """Prepend $FRONTPANEL_DIR/API/Python to sys.path if not already importable.

    `scripts/init_dev_env.sh` sets FRONTPANEL_DIR but does not export
    PYTHONPATH (only the Makefile does, for its python3 invocations).
    Doing the fix-up here means `python -m fft_demo` and `python -m
    fft_demo.smoke_test` work straight out of a freshly sourced env
    without the user remembering an extra PYTHONPATH= prefix.
    """
    fp_dir = os.environ.get("FRONTPANEL_DIR")
    if not fp_dir:
        return
    api_python = os.path.join(fp_dir, "API", "Python")
    if os.path.isdir(api_python) and api_python not in sys.path:
        sys.path.insert(0, api_python)


_bootstrap_frontpanel_path()


FFT_N = 4096                  # Transform size (xfft is synthesised for 4096)
FRAME_BYTES = FFT_N * 4       # One frame as raw uint32 little-endian bytes
BT_BLOCK_SIZE = 1024          # Block-throttled pipe block size (must be 2^n)


# ── WireIn / WireOut / Pipe endpoint addresses ────────────────────────────
EP_WIREIN_CFG       = 0x00
EP_WIREOUT_UART_CNT = 0x20
EP_WIREOUT_FFT_DBG  = 0x21
EP_WIREOUT_BEATS    = 0x22
EP_WIREOUT_TLAST    = 0x23
EP_WIREOUT_PIPECNTS = 0x24    # { fifo_out_count[15:0], fifo_in_count[15:0] }
EP_WIREOUT_HW_CYC   = 0x25    # HW FFT cycle count published by firmware
EP_WIREOUT_FRAME_N  = 0x26    # Free-running frame counter
EP_PIPEIN_FFT       = 0x81    # host → fifo_in
EP_PIPEOUT_FFT      = 0xA1    # fifo_out → host


@dataclass
class FrameResult:
    """One round-trip result returned by recv_frame()."""
    samples: "memoryview"     # raw 4096 × 32 b output, packed {im, re}
    hw_cycles: int            # cycles spent inside fft_accel_transform()
    frame_n: int              # value of the firmware's frame counter
    elapsed_s: float          # wall-clock host-side round trip (push→pull done)


class TransportError(RuntimeError):
    """FrontPanel transport / firmware handshake failure."""


class FrontPanelFftTransport:
    """Per-frame send/recv over the FFT pipe bridge endpoints."""

    def __init__(self, serial: str | None = None, timeout_ms: int = 2000) -> None:
        self.serial = serial
        self.timeout_ms = timeout_ms
        self._dev = None
        # FrontPanel always reads 32-bit words little-endian; this byte_order
        # matches the host-x86 native layout, so np.uint32 .tobytes() works.

    # ── Lifecycle ─────────────────────────────────────────────────────────

    def open(self) -> None:
        """Open the Opal Kelly device (FRONTPANEL_DIR must be on PYTHONPATH)."""
        try:
            import ok  # noqa: F401  — provided by the FrontPanel SDK
        except ImportError as exc:
            raise TransportError(
                "Cannot import 'ok' (FrontPanel Python API).  Source "
                "scripts/init_dev_env.sh (so FRONTPANEL_DIR is exported) "
                "and confirm $FRONTPANEL_DIR/API/Python contains ok.py."
            ) from exc

        dev = ok.FrontPanel()
        if self.serial:
            rc = dev.OpenBySerial(self.serial)
        else:
            if dev.GetDeviceCount() < 1:
                raise TransportError("No Opal Kelly device found — check USB cable.")
            rc = dev.OpenBySerial(dev.GetDeviceListSerial(0))
        if rc != ok.FrontPanel.NoError:
            raise TransportError(f"OpenBySerial failed (rc={rc}).  Is the "
                                 "uart_bridge holding the device?")

        dev.SetTimeout(self.timeout_ms)
        self._dev = dev

    def close(self) -> None:
        # `ok.FrontPanel` releases the USB handle in its destructor.
        self._dev = None

    # ── Status queries ────────────────────────────────────────────────────

    def fifo_counts(self) -> tuple[int, int]:
        """Return (fifo_in_count, fifo_out_count) sampled atomically."""
        self._dev.UpdateWireOuts()
        word = self._dev.GetWireOutValue(EP_WIREOUT_PIPECNTS) & 0xFFFFFFFF
        return word & 0xFFFF, (word >> 16) & 0xFFFF

    def hw_cycles(self) -> int:
        self._dev.UpdateWireOuts()
        return self._dev.GetWireOutValue(EP_WIREOUT_HW_CYC) & 0xFFFFFFFF

    def frame_counter(self) -> int:
        self._dev.UpdateWireOuts()
        return self._dev.GetWireOutValue(EP_WIREOUT_FRAME_N) & 0xFFFFFFFF

    def device_info(self) -> str:
        d = self._dev
        return (f"{d.GetDeviceID()} sn={d.GetSerialNumber()} "
                f"fw={d.GetDeviceMajorVersion()}.{d.GetDeviceMinorVersion()}")

    # ── Frame-oriented send / recv ────────────────────────────────────────

    def send_frame(self, frame_bytes: bytes | bytearray | memoryview) -> None:
        """Push one full FFT_N-sample frame (16 KiB raw uint32 LE) to fifo_in.

        The host blocks inside WriteToBlockPipeIn until the FPGA signals
        ep_ready (i.e. fifo_in has room for the next block).  Block size
        is 1024 bytes (256 words) — matches scripts/uart_bridge.py.
        """
        if len(frame_bytes) != FRAME_BYTES:
            raise ValueError(
                f"frame must be exactly {FRAME_BYTES} bytes, got {len(frame_bytes)}"
            )
        buf = bytearray(frame_bytes)
        rc = self._dev.WriteToBlockPipeIn(EP_PIPEIN_FFT, BT_BLOCK_SIZE, buf)
        if rc < 0:
            raise TransportError(f"WriteToBlockPipeIn failed (rc={rc}).")

    def wait_frame_done(self, prev_frame_n: int, timeout_s: float = 2.0) -> int:
        """Block until the firmware bumps frame_counter past prev_frame_n.

        Returns the new frame_counter value.  Raises TransportError on
        timeout.  The poll interval is ~1 ms (UpdateWireOuts is one USB
        round-trip; tight polling has been benchmarked at ~5 kHz, well
        below the realistic firmware frame rate).
        """
        deadline = time.monotonic() + timeout_s
        while True:
            n = self.frame_counter()
            if ((n - prev_frame_n) & 0xFFFFFFFF) != 0:
                return n
            if time.monotonic() > deadline:
                raise TransportError(
                    f"Timed out after {timeout_s:.1f} s waiting for frame "
                    f"{(prev_frame_n + 1) & 0xFFFFFFFF}.  Is the demo "
                    f"firmware running?"
                )
            # Yield briefly so the GUI thread isn't 100 % CPU.
            time.sleep(0.001)

    def recv_frame(self, prev_frame_n: int, timeout_s: float = 2.0) -> FrameResult:
        """Wait for the next frame and read it out.

        Order:
          1. Wait for frame_counter to advance (= cycles + output ready).
          2. Snapshot hw_cycles (already published by the firmware).
          3. Wait for fifo_out_count >= FFT_N just in case the count
             trails the frame counter on the fp_clk side.
          4. ReadFromBlockPipeOut a full FRAME_BYTES block.
        """
        t0 = time.monotonic()
        frame_n = self.wait_frame_done(prev_frame_n, timeout_s=timeout_s)
        hw_cycles = self.hw_cycles()

        # Poll fifo_out_count to confirm data is available.  The firmware
        # writes 4096 words after the publish; on healthy hardware the gap
        # is ≪ 1 ms.
        deadline = time.monotonic() + timeout_s
        while True:
            _in_cnt, out_cnt = self.fifo_counts()
            if out_cnt >= FFT_N:
                break
            if time.monotonic() > deadline:
                raise TransportError(
                    f"fifo_out_count stuck at {out_cnt} after frame {frame_n}; "
                    f"firmware may have stalled."
                )
            time.sleep(0.001)

        buf = bytearray(FRAME_BYTES)
        rc = self._dev.ReadFromBlockPipeOut(EP_PIPEOUT_FFT, BT_BLOCK_SIZE, buf)
        if rc < 0:
            raise TransportError(f"ReadFromBlockPipeOut failed (rc={rc}).")
        elapsed = time.monotonic() - t0
        return FrameResult(samples=memoryview(buf),
                           hw_cycles=hw_cycles,
                           frame_n=frame_n,
                           elapsed_s=elapsed)


__all__ = [
    "FFT_N", "FRAME_BYTES",
    "FrontPanelFftTransport", "FrameResult", "TransportError",
]
