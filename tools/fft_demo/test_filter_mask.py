"""Standalone unit test for the host filter-mask synthesis + cfg packing.

Runs without hardware, pytest, or Qt — pure numpy:

    python -m fft_demo.test_filter_mask

Exit code 0 on success, 1 on failure.  Validates that:

  * synth_mask() matches an independent brick-wall reference for LP/HP/BP/notch,
    including the exact boundary bins (0, lo, hi, N/2) — these are where a
    ``<`` vs ``<=`` slip would diverge from the firmware and make the on-screen
    H[k] overlay lie about where the passband edge is;
  * the folded-frequency mirror makes masks Hermitian (H[k] == H[N-k]);
  * pack_filter_cfg() / unpack_status() round-trip the wire fields.

The firmware (zephyr_app/src/fft_demo_main.c demo_synth_mask) and the C++
filter_mask.hpp use the identical band-edge conditions, so a green run here is
strong evidence the three implementations agree bit-for-bit.
"""

from __future__ import annotations

import sys

import numpy as np

from .filter_mask import (
    MODE_BYPASS, MODE_LP, MODE_HP, MODE_BP, MODE_NOTCH, PASS_GAIN,
    folded_freq, synth_mask, mask_passband, pack_filter_cfg, unpack_status,
)


def _ref_pass(mode: int, lo: int, hi: int, n: int) -> np.ndarray:
    """Independent (loop-based) brick-wall reference — deliberately NOT the
    vectorised production code, so a bug in one is unlikely to hide in both."""
    out = np.zeros(n, dtype=bool)
    for k in range(n):
        f = k if k <= (n - k) else (n - k)
        if mode == MODE_LP:
            p = f <= hi
        elif mode == MODE_HP:
            p = f >= lo
        elif mode == MODE_BP:
            p = lo <= f <= hi
        elif mode == MODE_NOTCH:
            p = f < lo or f > hi
        else:
            p = False
        out[k] = p
    return out


def _check(cond: bool, msg: str) -> int:
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    n = 4096
    fails = 0

    # ── folded_freq basic identities ──────────────────────────────────────
    fails += _check(int(folded_freq(0, n)) == 0, "folded_freq(0) != 0")
    fails += _check(int(folded_freq(n // 2, n)) == n // 2, "folded_freq(N/2) != N/2")
    fails += _check(int(folded_freq(n - 7, n)) == 7, "folded_freq(N-7) != 7")

    # ── synth_mask vs reference over a spread of (mode, lo, hi) incl. edges ─
    cases = [
        (MODE_LP,    0,    0),     # cutoff at DC
        (MODE_LP,    0,    100),
        (MODE_LP,    0,    2048),  # cutoff at Nyquist (all pass)
        (MODE_HP,    1,    0),
        (MODE_HP,    500,  0),
        (MODE_HP,    2048, 0),     # cutoff at Nyquist (only Nyquist passes)
        (MODE_BP,    100,  300),
        (MODE_BP,    300,  300),   # degenerate single-bin band
        (MODE_NOTCH, 100,  300),
        (MODE_NOTCH, 0,    2048),  # notch everything
        (MODE_BYPASS, 50,  500),   # all-stop
    ]
    for mode, lo, hi in cases:
        m = synth_mask(mode, lo, hi, n)
        fails += _check(m.shape == (n, 2) and m.dtype == np.int16,
                        f"synth_mask shape/dtype mode={mode}")
        # im channel is always zero
        fails += _check(np.all(m[:, 1] == 0), f"synth_mask im!=0 mode={mode}")
        # passband bins are exactly PASS_GAIN, stopband exactly 0
        ref = _ref_pass(mode, lo, hi, n)
        re = m[:, 0]
        fails += _check(np.all(re[ref] == PASS_GAIN) and np.all(re[~ref] == 0),
                        f"synth_mask re mismatch vs ref mode={mode} lo={lo} hi={hi}")
        # mask_passband agrees with synth_mask
        fails += _check(np.array_equal(mask_passband(mode, lo, hi, n), ref),
                        f"mask_passband != synth mode={mode}")
        # Hermitian symmetry: H[k] == H[N-k] for k in 1..N-1
        k = np.arange(1, n)
        fails += _check(np.array_equal(re[k], re[n - k]),
                        f"mask not Hermitian mode={mode} lo={lo} hi={hi}")

    # ── explicit boundary-bin assertions (the <= / < edges) ────────────────
    lp = synth_mask(MODE_LP, 0, 100, n)[:, 0]
    fails += _check(lp[100] == PASS_GAIN and lp[101] == 0,
                    "LP boundary: bin100 must pass, bin101 must stop")
    hp = synth_mask(MODE_HP, 100, 0, n)[:, 0]
    fails += _check(hp[100] == PASS_GAIN and hp[99] == 0,
                    "HP boundary: bin100 must pass, bin99 must stop")
    bp = synth_mask(MODE_BP, 100, 300, n)[:, 0]
    fails += _check(bp[100] == PASS_GAIN and bp[300] == PASS_GAIN
                    and bp[99] == 0 and bp[301] == 0,
                    "BP boundary: [100..300] pass, 99/301 stop")
    nt = synth_mask(MODE_NOTCH, 100, 300, n)[:, 0]
    fails += _check(nt[100] == 0 and nt[300] == 0
                    and nt[99] == PASS_GAIN and nt[301] == PASS_GAIN,
                    "Notch boundary: [100..300] stop, 99/301 pass")

    # ── control-word packing round-trip ───────────────────────────────────
    for mode, lo, hi in [(MODE_LP, 0, 100), (MODE_BP, 7, 2048), (MODE_NOTCH, 2047, 1)]:
        w = pack_filter_cfg(mode, lo, hi)
        fails += _check((w & 0x7) == mode, f"cfg mode field pack mode={mode}")
        fails += _check(((w >> 3) & 0xFFF) == (lo & 0xFFF), f"cfg lo pack lo={lo}")
        fails += _check(((w >> 15) & 0xFFF) == (hi & 0xFFF), f"cfg hi pack hi={hi}")
        fails += _check((w >> 27) == 0, "cfg reserved bits not zero")

    # ── status unpack ──────────────────────────────────────────────────────
    st = unpack_status(0x3 | 0x8 | 0x10)   # mode=3, avail, overflow, !failed
    fails += _check(st == {"mode": 3, "avail": True, "overflow": True,
                           "failed": False}, "unpack_status mismatch")

    if fails:
        print(f"\n{fails} check(s) FAILED")
        return 1
    print("filter_mask: all checks PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
