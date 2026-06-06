"""Headless mock-transport smoke test for the demo GUI logic.

Runs offscreen (QT_QPA_PLATFORM=offscreen) with NO Opal Kelly device — a fake
transport feeds canned frames so the widget/worker plumbing is exercised end to
end without hardware:

    QT_QPA_PLATFORM=offscreen python -m fft_demo.test_ui_mock

Exit 0 on success, 1 on failure.  Validates that:
  * the 3-pane _PlotPanel and the slider/_FilterPanel widgets construct;
  * _FilterPanel.edges() maps mode→(lo,hi) per the firmware convention and
    keeps lo<=hi for BP/notch;
  * _AcquisitionWorker._process_one_frame() interprets the firmware status echo
    correctly — bypass → frequency-bin frame (out_re None), filtered → time
    frame with an autoranged out_re and an H[k] passband; overflow/avail/failed
    flags propagate;
  * _PlotPanel.update() accepts both shapes without raising.
"""

from __future__ import annotations

import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import numpy as np

from . import filter_mask as fm
from .transport import FFT_N
from .sources import make_sine, pack_q15_frame, unpack_q15_frame


class _FakeFrame:
    def __init__(self, samples, frame_n):
        self.samples = samples
        self.hw_cycles = 12345
        self.frame_n = frame_n
        self.elapsed_s = 0.01


class _FakeTransport:
    """Stand-in for FrontPanelFftTransport.

    Echoes back either a forward FFT (bypass) or the input frame as a
    "filtered" time-domain result (it doesn't matter that it isn't a real IFFT;
    we only test plumbing/interpretation).  applied_status() reflects the last
    set_filter() so the worker's freq/time decision can be checked.
    """

    def __init__(self):
        self._mode = fm.MODE_BYPASS
        self._avail = True
        self._frame_n = 0
        self._last_in = None
        self.overflow = False

    # lifecycle / status
    def open(self): pass
    def close(self): pass
    def device_info(self): return "FAKE sn=0 fw=0.0"
    def frame_counter(self): return self._frame_n
    def fifo_counts(self): return (0, 0)
    def hw_cycles(self): return 12345

    def set_filter(self, cfg_word):
        self._mode = cfg_word & 0x7

    def applied_status(self):
        word = (self._mode & 0x7)
        if self._avail:
            word |= 0x8
        if self.overflow:
            word |= 0x10
        return word

    # frame I/O
    def send_frame(self, frame_bytes):
        self._last_in = unpack_q15_frame(frame_bytes, FFT_N)

    def recv_frame(self, prev_frame_n, timeout_s=2.0):
        self._frame_n += 1
        if self._mode != fm.MODE_BYPASS and self._avail:
            # "filtered": echo the input as the time-domain result.
            out = self._last_in
        else:
            # bypass: a forward-FFT-shaped frame (use input as a stand-in).
            out = self._last_in
        return _FakeFrame(pack_q15_frame(out), self._frame_n)


def _check(cond, msg):
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    from PyQt6 import QtWidgets
    import fft_demo.app as appmod

    fails = 0
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv)

    # ── Widgets construct ─────────────────────────────────────────────────
    win = appmod.FftDemoWindow(serial=None)
    fails += _check(win.plots.out_curve is not None, "out pane missing")
    fails += _check(win.plots.mask_curve is not None, "mask overlay missing")
    fails += _check(hasattr(win.source_panel, "bin1_slider"), "bin slider missing")

    # ── _FilterPanel.edges() mapping ──────────────────────────────────────
    fp = win.filter_panel
    fp.mode_combo.setCurrentIndex(fm.MODE_LP)
    fp.cutoff_slider.setValue(300)
    m, lo, hi = fp.edges()
    fails += _check((m, lo, hi) == (fm.MODE_LP, 0, 300), f"LP edges {m,lo,hi}")
    fp.mode_combo.setCurrentIndex(fm.MODE_HP)
    fp.cutoff_slider.setValue(150)
    m, lo, hi = fp.edges()
    fails += _check((m, lo, hi) == (fm.MODE_HP, 150, 0), f"HP edges {m,lo,hi}")
    fp.mode_combo.setCurrentIndex(fm.MODE_BP)
    fp.lo_slider.setValue(700)
    fp.hi_slider.setValue(200)            # inverted on purpose
    m, lo, hi = fp.edges()
    fails += _check((m, lo, hi) == (fm.MODE_BP, 200, 700), f"BP lo<=hi swap {m,lo,hi}")

    # ── Worker frame interpretation against the fake transport ────────────
    worker = win._worker
    worker._transport = _FakeTransport()
    worker._open = True

    # bypass frame → frequency bins, no out_re, no passband
    worker.set_filter(fm.MODE_BYPASS, 0, 0)
    frame = make_sine(0.5, 64, FFT_N)
    r = worker._process_one_frame(frame)
    fails += _check(r["filtered"] is False, "bypass should not be 'filtered'")
    fails += _check(r["out_re"] is None, "bypass out_re must be None")
    fails += _check(r["passband"] is None, "bypass passband must be None")
    fails += _check(r["mode"] == fm.MODE_BYPASS, "bypass mode echo")

    # LP filtered frame → time-domain interpretation, out_re + passband present
    worker.set_filter(fm.MODE_LP, 0, 100)
    r = worker._process_one_frame(frame)
    fails += _check(r["filtered"] is True, "LP should be 'filtered'")
    fails += _check(r["out_re"] is not None and r["out_re"].size == FFT_N,
                    "filtered out_re shape")
    fails += _check(r["passband"] is not None
                    and bool(r["passband"][50]) and not bool(r["passband"][200]),
                    "LP passband shape (bin50 pass, bin200 stop)")
    fails += _check(r["out_peak_fs"] is not None, "filtered out_peak_fs present")
    fails += _check(r["avail"] is True, "filter_avail echo true")

    # overflow flag propagates
    worker._transport.overflow = True
    r = worker._process_one_frame(frame)
    fails += _check(r["overflow"] is True, "overflow flag must propagate")

    # ── _PlotPanel.update accepts both shapes ─────────────────────────────
    try:
        win.plots.update(r["input_re"], r["hw_db"], r["sw_db"],
                         filtered=True, out_re=r["out_re"], passband=r["passband"])
        win.plots.update(r["input_re"], r["hw_db"], r["sw_db"],
                         filtered=False, out_re=None, passband=None)
    except Exception as exc:  # noqa: BLE001
        fails += _check(False, f"_PlotPanel.update raised: {exc}")

    # ── Forward-only bitstream (avail=False) → fall back to freq frame ────
    worker._transport._avail = False
    worker.set_filter(fm.MODE_LP, 0, 100)
    r = worker._process_one_frame(frame)
    fails += _check(r["filtered"] is False, "no-filter bitstream must not be 'filtered'")
    fails += _check(r["avail"] is False, "filter_avail echo false")

    win.close()
    if fails:
        print(f"\n{fails} check(s) FAILED")
        return 1
    print("ui_mock: all checks PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
