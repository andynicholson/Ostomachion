"""HIL control-channel test for the host-programmable spectral filter (PR-A).

Runs on the remote host against the real XEM7310 with the PR-A bitstream + demo
firmware loaded.  Proves the NEW host→fabric control path end to end via the
pipe transport + WireIn 0x01 (filter cfg) / WireOut 0x28 (status echo):

  1. bypass  → output is forward-FFT bins; peak lands at the input tone bin;
               status echo reports mode=bypass.
  2. filter on → status echo reports the requested mode with avail=1, and the
               output frame stops being frequency bins (it becomes the filtered
               ÷N time-domain signal).
  3. brick-wall response — judged ÷N-independently:  a TWO-tone input (a low
     tone + a high tone) is pushed through ONE filter; a host-side numpy FFT of
     the filtered time-domain output compares the magnitude at the PASS tone vs
     the STOP tone.  The global ÷N inverse scaling hits both tones equally, so
     it cancels in the ratio (this avoids the single-tone "everything sits at
     the ÷N quantisation floor" trap).  LP keeps the low tone / kills the high;
     HP does the opposite.

Uses the staged fft_demo package (transport + filter_mask + sources).  Exit 0
on success, 1 on failure.
"""

from __future__ import annotations

import sys
import numpy as np

from fft_demo.transport import FFT_N, FrontPanelFftTransport, TransportError
from fft_demo import filter_mask as fm
from fft_demo.sources import (
    make_sine, make_two_sines, pack_q15_frame, unpack_q15_frame, Q15_UNIT,
)

LO_TONE = 64       # low tone bin
HI_TONE = 600      # high tone bin
CUT = 256          # cutoff between them (folded bin)
MIN_RATIO = 8.0    # required pass/stop magnitude ratio
# Unity round-trip band: an all-pass / in-passband tone must return at input
# level (the unscaled-inverse gain budget, ACCEL_ARCH §7.1).  A doubly-scaled
# (÷N) inverse would return ~1/4096 of input and fail this — the regression
# guard for the scaling word.  Wide band absorbs Q1.15 quantisation + 1-LSB
# rounding on a full round trip.
UNITY_LO, UNITY_HI = 0.80, 1.20


def _peak_bin(frame_q15) -> int:
    c = (frame_q15[:, 0].astype(np.float64) + 1j * frame_q15[:, 1].astype(np.float64))
    return int(np.argmax(np.abs(c)))


def _peak_frac(frame_q15) -> float:
    """Peak |sample| (either rail) as a fraction of Q1.15 full scale."""
    import numpy as _np
    m = _np.maximum(_np.abs(frame_q15[:, 0]), _np.abs(frame_q15[:, 1]))
    return float(m.max()) / float(Q15_UNIT) if frame_q15.size else 0.0


def _tone_mag(out_q15, bin_idx) -> float:
    """Host-FFT magnitude of the filtered time-domain output at one bin.

    The ÷N inverse scales every bin equally, so ratios between bins are
    scale-independent.  A numpy (float64) FFT concentrates a tone's energy in
    its bin well above the spread quantisation noise."""
    re = out_q15[:, 0].astype(np.float64)
    im = out_q15[:, 1].astype(np.float64)
    spec = np.fft.fft(re + 1j * im)
    return float(np.abs(spec[bin_idx]))


def main() -> int:
    t = FrontPanelFftTransport()
    try:
        t.open()
    except TransportError as exc:
        print(f"FAIL: open: {exc}", file=sys.stderr)
        return 1
    print("open:", t.device_info())

    fails = 0

    def run(frame_pkt, mode, lo, hi, label):
        t.set_filter(fm.pack_filter_cfg(mode, lo, hi))
        # Drive two frames so the firmware's confirmed-change reload (debounce)
        # has applied before we sample the frame we judge.
        prev = t.frame_counter()
        res = None
        for _ in range(2):
            t.send_frame(frame_pkt)
            res = t.recv_frame(prev_frame_n=prev, timeout_s=3.0)
            prev = res.frame_n
        st = fm.unpack_status(t.applied_status())
        out = unpack_q15_frame(res.samples, FFT_N)
        return st, out

    # ── 1. bypass — forward FFT, peak at the tone bin ─────────────────────
    one_tone = pack_q15_frame(make_sine(0.5, LO_TONE, FFT_N))
    st, out = run(one_tone, fm.MODE_BYPASS, 0, 0, "bypass")
    pk = _peak_bin(out)
    print(f"  [bypass]   applied={st} peakbin={pk}")
    if st["mode"] != fm.MODE_BYPASS:
        print("FAIL: bypass mode echo", file=sys.stderr); fails += 1
    if not (abs(pk - LO_TONE) <= 1 or abs(pk - (FFT_N - LO_TONE)) <= 1):
        print(f"FAIL: bypass peak bin {pk} not at tone {LO_TONE}", file=sys.stderr)
        fails += 1
    if not st["avail"]:
        print("NOTE: filter datapath reported UNAVAILABLE — forward-only bitstream?",
              file=sys.stderr)

    # ── 2+3. two-tone through LP then HP — judge pass vs stop per tone ─────
    two_tone = pack_q15_frame(make_two_sines(0.4, LO_TONE, 0.4, HI_TONE, FFT_N))

    st_lp, out_lp = run(two_tone, fm.MODE_LP, 0, CUT, "LP")
    lp_pass = _tone_mag(out_lp, LO_TONE)     # low tone passes
    lp_stop = _tone_mag(out_lp, HI_TONE)     # high tone stopped
    lp_ratio = lp_pass / max(lp_stop, 1e-9)
    print(f"  [LP hi={CUT}] applied={st_lp} "
          f"lo-tone={lp_pass:.1f} hi-tone={lp_stop:.1f} ratio={lp_ratio:.1f}x")
    if not (st_lp["mode"] == fm.MODE_LP and st_lp["avail"]):
        print("FAIL: LP status echo", file=sys.stderr); fails += 1

    st_hp, out_hp = run(two_tone, fm.MODE_HP, CUT, 0, "HP")
    hp_pass = _tone_mag(out_hp, HI_TONE)     # high tone passes
    hp_stop = _tone_mag(out_hp, LO_TONE)     # low tone stopped
    hp_ratio = hp_pass / max(hp_stop, 1e-9)
    print(f"  [HP lo={CUT}] applied={st_hp} "
          f"hi-tone={hp_pass:.1f} lo-tone={hp_stop:.1f} ratio={hp_ratio:.1f}x")
    if not (st_hp["mode"] == fm.MODE_HP and st_hp["avail"]):
        print("FAIL: HP status echo", file=sys.stderr); fails += 1

    if st_lp["avail"] and st_hp["avail"]:
        if lp_ratio < MIN_RATIO:
            print(f"FAIL: LP pass/stop ratio {lp_ratio:.1f}x < {MIN_RATIO}x",
                  file=sys.stderr); fails += 1
        if hp_ratio < MIN_RATIO:
            print(f"FAIL: HP pass/stop ratio {hp_ratio:.1f}x < {MIN_RATIO}x",
                  file=sys.stderr); fails += 1
    else:
        print("SKIP: filter unavailable — cannot judge brick-wall ratio")

    # ── 4. Unity round trip — absolute level, not just ratio ──────────────
    # A single tone INSIDE a low-pass passband must return at ~input amplitude
    # (unscaled inverse => y[n] = x[n]).  Guards against a regression to a
    # scaled (÷N) inverse word, which would return ~1/4096 of input.
    AMP = 0.5
    in_tone = make_sine(AMP, LO_TONE, FFT_N)
    in_frac = _peak_frac(in_tone)
    st_u, out_u = run(pack_q15_frame(in_tone), fm.MODE_LP, 0, CUT, "unity")
    out_frac = _peak_frac(out_u)
    if st_u["avail"]:
        gain = out_frac / in_frac if in_frac else 0.0
        print(f"  [unity]    in={in_frac:.4f}FS out={out_frac:.4f}FS "
              f"out/in={gain:.3f} (want {UNITY_LO}-{UNITY_HI})")
        if not (UNITY_LO <= gain <= UNITY_HI):
            print(f"FAIL: round-trip gain {gain:.3f} outside "
                  f"[{UNITY_LO}, {UNITY_HI}] — inverse xfft scaling word wrong? "
                  f"(a ÷N inverse gives ~1/4096)", file=sys.stderr)
            fails += 1
        if st_u["overflow"]:
            print("FAIL: overflow on an in-passband unity tone", file=sys.stderr)
            fails += 1
    else:
        print("SKIP: filter unavailable — cannot judge unity round trip")

    if st_lp["overflow"] or st_hp["overflow"]:
        print("NOTE: overflow flagged on a filtered frame", file=sys.stderr)

    t.close()
    if fails:
        print(f"\n{fails} check(s) FAILED")
        return 1
    print("\nhil_filter: all checks PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
