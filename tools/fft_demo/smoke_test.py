"""Standalone CLI smoke test for the FFT pipe bridge.

Run this after `make fpga-program` + `make demo-hw` to validate the
end-to-end host ⇄ NEORV32 ⇄ xfft path without launching the GUI:

    source scripts/init_dev_env.sh
    python -m fft_demo.smoke_test

It pushes three canonical frames (DC, bin-1 cosine, bin-64 cosine) and
checks the peak bin of each.  Exit code is 0 on success, 1 on failure;
suitable for `make demo-smoke` or CI.

If this fails before `python -m fft_demo` would: the issue is in the
bridge, firmware, or device-open path — not the GUI.
"""

from __future__ import annotations

import sys

import numpy as np

from .sources import (
    Q15_UNIT, make_dc, make_sine, make_sine_plus_noise,
    pack_q15_frame, unpack_q15_frame, q15_to_complex,
)
from .transport import FFT_N, FrontPanelFftTransport, TransportError


def _peak_bin(spec: np.ndarray) -> int:
    return int(np.argmax(np.abs(spec)))


def _spectrum(frame_q15: np.ndarray) -> np.ndarray:
    return np.fft.fft(q15_to_complex(frame_q15)) / float(FFT_N)


def _check_peak(label: str, hw: np.ndarray,
                expected: set[int], allow_dc: bool = False) -> bool:
    peak = _peak_bin(hw)
    ok = peak in expected
    print(f"  {label:<20}  peak bin={peak:>4}  "
          f"expected={sorted(expected)}  {'PASS' if ok else 'FAIL'}")
    return ok


def main() -> int:
    transport = FrontPanelFftTransport()
    try:
        transport.open()
    except TransportError as exc:
        print(f"ERROR opening FrontPanel: {exc}", file=sys.stderr)
        return 1

    print(f"Device : {transport.device_info()}")
    in_cnt, out_cnt = transport.fifo_counts()
    print(f"FIFOs  : in={in_cnt} out={out_cnt} "
          f"(both should be 0 before first frame)")

    last_n = transport.frame_counter()
    print(f"Frame# : starting at {last_n}")
    print()

    cases: list[tuple[str, np.ndarray, set[int]]] = [
        ("DC (amp=0.5)",        make_dc(0.5, FFT_N),                {0}),
        ("Cosine bin 1",        make_sine(0.4, 1, FFT_N),           {1, FFT_N - 1}),
        ("Cosine bin 64",       make_sine(0.4, 64, FFT_N),          {64, FFT_N - 64}),
        ("Sine+noise bin 200",
         make_sine_plus_noise(0.4, 200, 0.02, FFT_N,
                              rng=np.random.default_rng(1)),
         {200, FFT_N - 200}),
    ]

    n_ok = 0
    for label, frame, expected in cases:
        transport.send_frame(pack_q15_frame(frame))
        try:
            result = transport.recv_frame(prev_frame_n=last_n, timeout_s=3.0)
        except TransportError as exc:
            print(f"  {label:<20}  TIMEOUT: {exc}")
            continue
        last_n = result.frame_n
        hw = q15_to_complex(unpack_q15_frame(result.samples, FFT_N))
        ok = _check_peak(label, hw, expected)
        hw_us = result.hw_cycles * 1e6 / 100e6
        print(f"  {' ' * 20}  hw_cycles={result.hw_cycles}  "
              f"({hw_us:.1f} us)  round_trip={result.elapsed_s*1000:.1f} ms")
        n_ok += int(ok)

    print()
    print(f"Result : {n_ok}/{len(cases)} cases passed")
    return 0 if n_ok == len(cases) else 1


if __name__ == "__main__":
    raise SystemExit(main())
