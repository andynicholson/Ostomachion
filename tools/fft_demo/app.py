"""PyQt6 desktop GUI for the Ostomachion FFT-accelerator demo.

Visualises one realtime frame at a time:

  - Generates the input frame on the host (sine / noise / sum / dc).
  - Computes the FFT three ways:
      * Hardware  — round-trip through fp_fft_pipe_bridge + xfft.
      * Software  — numpy.fft.fft of the same input, scaled by 1/N to
                    match the xfft scaled-output convention.
  - Overlays both magnitude spectra (dB) and the input time-domain trace.
  - Reports HW compute time (firmware cycle counter), SW compute time
    (numpy on host), end-to-end frame rate, and two correctness numbers:
    peak-bin |HW − SW| dB (how well the spectra agree at the loudest
    bin), and the HW spurious-free dynamic range (peak HW bin − loudest
    non-peak HW bin) — the latter is essentially the Q1.15 noise floor.
"""

from __future__ import annotations

import argparse
import sys
import time
import traceback

import numpy as np

try:
    from PyQt6 import QtCore, QtWidgets
    from PyQt6.QtCore import Qt
    import pyqtgraph as pg
except ImportError as exc:  # pragma: no cover — runtime guard for users
    print(f"ERROR: missing GUI dependency: {exc}", file=sys.stderr)
    print("       pip install -r tools/fft_demo/requirements.txt", file=sys.stderr)
    raise SystemExit(1) from exc

from .sources import (
    Q15_UNIT, make_dc, make_sine, make_two_sines, make_noise,
    make_sine_plus_noise, pack_q15_frame, unpack_q15_frame, q15_to_complex,
)
from .transport import FFT_N, FrontPanelFftTransport, TransportError


SYS_CLK_HZ = 100_000_000


# Sources the user can pick from the source combo box.
SOURCES = [
    "Sine",
    "Two sines",
    "Noise",
    "Sine + noise",
    "DC",
]


def db_magnitude(complex_spectrum: np.ndarray, eps: float = 1e-12) -> np.ndarray:
    """20·log10(|X|), with a floor to keep -inf out of the plot."""
    mag = np.abs(complex_spectrum)
    return 20.0 * np.log10(np.maximum(mag, eps))


def spectrum_quality(hw_db: np.ndarray, sw_db: np.ndarray) -> tuple[float, float]:
    """Return (peak_err_db, sfdr_db) for the HW vs SW magnitude spectra.

    - peak_err_db : |hw_db − sw_db| at the SW peak bin and its
      conjugate alias (N − peak).  For an integer-bin sinusoid this
      is the only place where signal energy lives, so the comparison
      ignores the noise-floor bins where Q1.15 quantisation (HW
      ≈ −90 dB) and float64 roundoff (SW ≪ −150 dB) disagree by 100+
      dB without indicating an FFT correctness problem.

    - sfdr_db : HW peak bin minus the loudest HW bin that *isn't* the
      peak or its conjugate alias — standard spurious-free dynamic
      range.  For a clean Q1.15 single-tone the FPGA pipeline sits
      around 85–95 dB SFDR.
    """
    n = hw_db.size
    sw_peak = int(np.argmax(sw_db))
    peak_bins = np.array(sorted({sw_peak, (n - sw_peak) % n}), dtype=np.intp)
    peak_err_db = float(np.max(np.abs(hw_db[peak_bins] - sw_db[peak_bins])))

    mask = np.ones(n, dtype=bool)
    mask[peak_bins] = False
    if mask.any():
        sfdr_db = float(np.max(hw_db) - np.max(hw_db[mask]))
    else:
        sfdr_db = 0.0
    return peak_err_db, sfdr_db


# ──────────────────────────────────────────────────────────────────────────
# Source-control widget (left panel)
# ──────────────────────────────────────────────────────────────────────────

class _SourcePanel(QtWidgets.QWidget):
    """Combo box + sliders for the demo input-signal generator."""

    def __init__(self, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self._rng = np.random.default_rng(seed=0xFFEED)

        layout = QtWidgets.QFormLayout(self)
        layout.setFieldGrowthPolicy(
            QtWidgets.QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)

        self.source_combo = QtWidgets.QComboBox()
        self.source_combo.addItems(SOURCES)
        self.source_combo.setCurrentText("Sine + noise")
        layout.addRow("Source", self.source_combo)

        self.amp_spin = QtWidgets.QDoubleSpinBox()
        self.amp_spin.setRange(0.0, 1.0)
        self.amp_spin.setSingleStep(0.05)
        self.amp_spin.setValue(0.5)
        layout.addRow("Amplitude", self.amp_spin)

        self.bin1_spin = QtWidgets.QSpinBox()
        self.bin1_spin.setRange(1, FFT_N // 2 - 1)
        self.bin1_spin.setValue(64)
        layout.addRow("Sine bin", self.bin1_spin)

        self.amp2_spin = QtWidgets.QDoubleSpinBox()
        self.amp2_spin.setRange(0.0, 1.0)
        self.amp2_spin.setSingleStep(0.05)
        self.amp2_spin.setValue(0.25)
        layout.addRow("Sine 2 amp", self.amp2_spin)

        self.bin2_spin = QtWidgets.QSpinBox()
        self.bin2_spin.setRange(1, FFT_N // 2 - 1)
        self.bin2_spin.setValue(200)
        layout.addRow("Sine 2 bin", self.bin2_spin)

        self.sigma_spin = QtWidgets.QDoubleSpinBox()
        self.sigma_spin.setRange(0.0, 0.5)
        self.sigma_spin.setSingleStep(0.01)
        self.sigma_spin.setValue(0.05)
        layout.addRow("Noise σ", self.sigma_spin)

        self.source_combo.currentTextChanged.connect(self._refresh_enabled)
        self._refresh_enabled(self.source_combo.currentText())

    # ── Enable/disable parameter widgets per source kind ──────────────────
    def _refresh_enabled(self, name: str) -> None:
        is_sine     = name in ("Sine", "Sine + noise", "Two sines")
        is_two      = name == "Two sines"
        is_noise    = name in ("Noise", "Sine + noise")
        is_dc       = name == "DC"
        self.amp_spin.setEnabled(is_sine or is_dc)
        self.bin1_spin.setEnabled(is_sine)
        self.amp2_spin.setEnabled(is_two)
        self.bin2_spin.setEnabled(is_two)
        self.sigma_spin.setEnabled(is_noise)

    # ── Build one frame from the current control values ───────────────────
    def make_frame(self) -> np.ndarray:
        kind = self.source_combo.currentText()
        amp  = self.amp_spin.value()
        bin1 = self.bin1_spin.value()
        amp2 = self.amp2_spin.value()
        bin2 = self.bin2_spin.value()
        sigma = self.sigma_spin.value()
        if kind == "Sine":
            return make_sine(amp, bin1, FFT_N)
        if kind == "Two sines":
            return make_two_sines(amp, bin1, amp2, bin2, FFT_N)
        if kind == "Noise":
            return make_noise(sigma, FFT_N, rng=self._rng)
        if kind == "Sine + noise":
            return make_sine_plus_noise(amp, bin1, sigma, FFT_N, rng=self._rng)
        if kind == "DC":
            return make_dc(amp, FFT_N)
        raise ValueError(f"unknown source {kind!r}")


# ──────────────────────────────────────────────────────────────────────────
# Stats panel
# ──────────────────────────────────────────────────────────────────────────

class _StatsPanel(QtWidgets.QGroupBox):
    """Compact read-out of HW vs SW performance + correctness."""

    def __init__(self) -> None:
        super().__init__("Per-frame statistics")
        layout = QtWidgets.QFormLayout(self)
        font_mono = self.font()
        font_mono.setFamily("Monospace")

        def _mk_label() -> QtWidgets.QLabel:
            lbl = QtWidgets.QLabel("—")
            lbl.setFont(font_mono)
            lbl.setMinimumWidth(120)
            return lbl

        self.lbl_hw         = _mk_label()
        self.lbl_sw         = _mk_label()
        self.lbl_round      = _mk_label()
        self.lbl_fps        = _mk_label()
        self.lbl_peak_err   = _mk_label()
        self.lbl_sfdr       = _mk_label()
        self.lbl_frame      = _mk_label()
        self.lbl_status     = _mk_label()
        layout.addRow("Frame #",            self.lbl_frame)
        layout.addRow("HW FFT cycles",      self.lbl_hw)
        layout.addRow("SW FFT (numpy)",     self.lbl_sw)
        layout.addRow("Host round-trip",    self.lbl_round)
        layout.addRow("End-to-end rate",    self.lbl_fps)
        layout.addRow("Peak bin |HW−SW|",   self.lbl_peak_err)
        layout.addRow("HW SFDR",            self.lbl_sfdr)
        layout.addRow("Status",             self.lbl_status)
        self.lbl_status.setText("idle")

    def update_frame(self, frame_n: int, hw_cycles: int, sw_us: float,
                     round_s: float, fps: float,
                     peak_err_db: float, sfdr_db: float) -> None:
        hw_us = hw_cycles * 1e6 / SYS_CLK_HZ
        self.lbl_frame.setText(f"{frame_n}")
        self.lbl_hw.setText(f"{hw_cycles:>8} ({hw_us:7.1f} µs)")
        self.lbl_sw.setText(f"{sw_us:7.1f} µs")
        self.lbl_round.setText(f"{round_s*1000:7.1f} ms")
        self.lbl_fps.setText(f"{fps:5.1f} fps")
        self.lbl_peak_err.setText(f"{peak_err_db:7.3f} dB")
        self.lbl_sfdr.setText(f"{sfdr_db:7.2f} dB")

    def set_status(self, text: str, ok: bool = True) -> None:
        self.lbl_status.setText(text)
        self.lbl_status.setStyleSheet("color: #2a7;" if ok else "color: #c44;")


# ──────────────────────────────────────────────────────────────────────────
# Plotting panel
# ──────────────────────────────────────────────────────────────────────────

class _PlotPanel(QtWidgets.QWidget):
    """Two stacked pyqtgraph plot widgets: time-domain + magnitude spectrum."""

    def __init__(self) -> None:
        super().__init__()
        pg.setConfigOption("antialias", True)
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # ── Time-domain plot ──────────────────────────────────────────────
        # Lock both axes — autorange would otherwise slide the X span
        # to a "nice" multiple (e.g. 0..6000) that doesn't align with
        # the bin grid, making peaks appear offset from their integer
        # bin index in the FFT plot below.
        self.time_plot = pg.PlotWidget(title="Input signal (time domain, Re)")
        self.time_plot.setLabel("bottom", "Sample")
        self.time_plot.setLabel("left", "Q1.15 value")
        self.time_plot.enableAutoRange(x=False, y=False)
        self.time_plot.setXRange(0, FFT_N - 1, padding=0)
        self.time_plot.setYRange(-1.05, 1.05, padding=0)
        self.time_plot.setMouseEnabled(x=False, y=False)
        self.time_plot.setMenuEnabled(False)
        self.time_curve = self.time_plot.plot(pen=pg.mkPen("#4af", width=1))
        layout.addWidget(self.time_plot, 1)

        # ── Frequency-domain plot ─────────────────────────────────────────
        # Same lock: bin axis runs exactly 0..FFT_N-1 so a peak at bin k
        # lands directly above the k tick on the X axis.  The Y range is
        # clamped to the useful Q1.15 dynamic range — float64 numpy
        # noise can dip below this, which is fine (clipped to the bottom
        # edge of the plot).
        self.freq_plot = pg.PlotWidget(title="FFT magnitude (dB)")
        self.freq_plot.setLabel("bottom", "Bin")
        self.freq_plot.setLabel("left", "Magnitude (dB)")
        self.freq_plot.enableAutoRange(x=False, y=False)
        self.freq_plot.setXRange(0, FFT_N - 1, padding=0)
        self.freq_plot.setYRange(-150, 5, padding=0)
        self.freq_plot.setMouseEnabled(x=False, y=False)
        self.freq_plot.setMenuEnabled(False)
        self.freq_plot.addLegend(offset=(-30, 10))
        self.hw_curve = self.freq_plot.plot(pen=pg.mkPen("#fa3", width=1),
                                            name="Hardware (xfft)")
        self.sw_curve = self.freq_plot.plot(pen=pg.mkPen("#5e8", width=1,
                                                          style=Qt.PenStyle.DashLine),
                                            name="Software (numpy)")
        layout.addWidget(self.freq_plot, 2)

    def update(self, input_re: np.ndarray, hw_mag_db: np.ndarray,
               sw_mag_db: np.ndarray) -> None:
        # Use an explicit bin axis so the curve x-coords stay integer,
        # even if the input array length ever drifts from FFT_N.
        bins = np.arange(hw_mag_db.size)
        self.time_curve.setData(np.arange(input_re.size), input_re)
        self.hw_curve.setData(bins, hw_mag_db)
        self.sw_curve.setData(bins, sw_mag_db)


# ──────────────────────────────────────────────────────────────────────────
# Main window
# ──────────────────────────────────────────────────────────────────────────

class _AcquisitionWorker(QtCore.QObject):
    """Owns the FrontPanel transport and runs the blocking FFT round-trip.

    Lives in its own QThread so the up-to-2 s send/recv USB round-trip never
    blocks the GUI thread.  The transport handle is created, opened, used, and
    closed entirely on this thread — the Opal Kelly handle is not thread-safe,
    so the GUI thread must never touch it directly.  Communication is via
    queued signals only.
    """

    # Emitted after open(): (info_text, ok, initial_frame_n)
    opened = QtCore.pyqtSignal(str, bool, int)
    # Emitted once per completed frame with everything the GUI needs to render.
    frameReady = QtCore.pyqtSignal(object)
    # Emitted on any transport/processing error: (message,)
    failed = QtCore.pyqtSignal(str)
    # Emitted when the worker has stopped its run loop (clean stop / error).
    stopped = QtCore.pyqtSignal()

    def __init__(self, serial: str | None) -> None:
        super().__init__()
        self._serial = serial
        self._transport = FrontPanelFftTransport(serial=serial)
        self._open = False
        self._running = False
        self._last_frame_n = 0
        # make_frame() reads Qt widgets and must run on the GUI thread, so the
        # window pushes the next input frame in here under this lock.
        self._pending_lock = QtCore.QMutex()
        self._pending_frame = None  # np.ndarray (Q1.15) set by the GUI thread

    # ── slots (run on the worker thread) ──────────────────────────────────

    @QtCore.pyqtSlot()
    def open(self) -> None:
        try:
            self._transport.open()
            self._open = True
            self._last_frame_n = self._transport.frame_counter()
            self.opened.emit(self._transport.device_info(), True,
                             self._last_frame_n)
        except TransportError as exc:
            self.opened.emit(str(exc), False, 0)

    @QtCore.pyqtSlot(object)
    def set_input(self, frame_q15) -> None:
        """Called from the GUI thread to hand over the next input frame."""
        self._pending_lock.lock()
        self._pending_frame = frame_q15
        self._pending_lock.unlock()

    @QtCore.pyqtSlot()
    def start(self) -> None:
        if not self._open:
            self.failed.emit("Open FrontPanel first.")
            return
        # Resync to the device's current frame counter on every (re)start so
        # a previous timed-out run cannot poison this one with a stale
        # _last_frame_n that wait_frame_done would never see equal again.
        try:
            self._last_frame_n = self._transport.frame_counter()
        except TransportError as exc:
            self.failed.emit(f"transport: {exc}")
            return
        self._pending_lock.lock()
        self._pending_frame = None  # drop anything stale from the prior run
        self._pending_lock.unlock()
        self._running = True
        self._run_loop()

    @QtCore.pyqtSlot()
    def stop(self) -> None:
        self._running = False

    @QtCore.pyqtSlot()
    def close(self) -> None:
        self._running = False
        try:
            self._transport.close()
        except Exception:  # noqa: BLE001 — best-effort on shutdown
            pass

    # ── internal ──────────────────────────────────────────────────────────

    def _run_loop(self) -> None:
        # Drives frames back-to-back; yields to this threads event loop
        # between frames so stop()/close() slots can be delivered.
        while self._running:
            self._pending_lock.lock()
            frame = self._pending_frame
            # CONSUME the staged frame: clearing it under the lock guarantees
            # one transform per push.  If we left it set, the loop would race
            # ahead of the GUI's _on_frame_ready -> _push_input cycle and
            # re-send the same input frame, queueing duplicate output frames
            # in the host-pipe FIFO.  Eventually the FIFO/firmware backpressure
            # stalls frame_count_o and the next recv_frame times out.
            self._pending_frame = None
            self._pending_lock.unlock()
            if frame is None:
                # No input staged yet — yield briefly and re-poll.  We process
                # events here so queued slots (set_input, stop, close) actually
                # get delivered between iterations.
                QtCore.QCoreApplication.processEvents()
                QtCore.QThread.msleep(2)
                continue
            try:
                result = self._process_one_frame(frame)
            except TransportError as exc:
                # Capture the device state at the moment of failure so we can
                # tell apart wait_frame_done timeouts from fifo_out stalls and
                # see whether frame_counter advanced past us, fell behind, or
                # wrapped weirdly across the M3 handshake.
                state = self._snapshot_state()
                self._running = False
                self.failed.emit(f"transport: {exc}  [{state}]")
                break
            except Exception:  # noqa: BLE001
                self._running = False
                traceback.print_exc()
                self.failed.emit("unhandled error (see stderr)")
                break
            self.frameReady.emit(result)
            # Deliver any queued stop()/set_input()/close() calls.
            QtCore.QCoreApplication.processEvents()
        self.stopped.emit()

    def _snapshot_state(self) -> str:
        # Best-effort device-state dump for failure messages.  Does not raise:
        # if the transport is wedged we still want to print whatever we can.
        try:
            in_cnt, out_cnt = self._transport.fifo_counts()
        except Exception:  # noqa: BLE001
            in_cnt = out_cnt = -1
        try:
            cur_frame = self._transport.frame_counter()
        except Exception:  # noqa: BLE001
            cur_frame = -1
        try:
            cur_cycles = self._transport.hw_cycles()
        except Exception:  # noqa: BLE001
            cur_cycles = -1
        return (f"last_frame_n={self._last_frame_n} "
                f"device_frame={cur_frame} "
                f"fifo_in={in_cnt} fifo_out={out_cnt} "
                f"hw_cycles={cur_cycles}")

    def _process_one_frame(self, input_q15) -> dict:
        input_complex = q15_to_complex(input_q15)

        t_sw0 = time.perf_counter()
        sw_spectrum = np.fft.fft(input_complex) / float(FFT_N)
        t_sw_us = (time.perf_counter() - t_sw0) * 1e6

        self._transport.send_frame(pack_q15_frame(input_q15))
        result = self._transport.recv_frame(prev_frame_n=self._last_frame_n,
                                            timeout_s=2.0)
        self._last_frame_n = result.frame_n

        hw_q15 = unpack_q15_frame(result.samples, FFT_N)
        hw_spectrum = q15_to_complex(hw_q15)
        hw_db = db_magnitude(hw_spectrum)
        sw_db = db_magnitude(sw_spectrum)
        peak_err_db, sfdr_db = spectrum_quality(hw_db, sw_db)

        return {
            "input_re": input_q15[:, 0].astype(np.float32) / float(Q15_UNIT),
            "hw_db": hw_db,
            "sw_db": sw_db,
            "frame_n": result.frame_n,
            "hw_cycles": result.hw_cycles,
            "sw_us": t_sw_us,
            "round_s": result.elapsed_s,
            "peak_err_db": peak_err_db,
            "sfdr_db": sfdr_db,
        }


class FftDemoWindow(QtWidgets.QMainWindow):

    # Signals into the worker (queued across the thread boundary).
    _request_open = QtCore.pyqtSignal()
    _request_start = QtCore.pyqtSignal()
    _request_stop = QtCore.pyqtSignal()
    _request_close = QtCore.pyqtSignal()
    _push_input = QtCore.pyqtSignal(object)

    def __init__(self, serial: str | None) -> None:
        super().__init__()
        self.setWindowTitle("Ostomachion FFT accelerator demo")
        self.resize(1200, 800)

        self.transport_open = False
        self.running = False
        self._fps_t0 = time.monotonic()
        self._fps_frames = 0
        self._fps_value = 0.0

        # Layout: left = controls, right = plots + stats
        central = QtWidgets.QWidget()
        main_lo = QtWidgets.QHBoxLayout(central)

        left = QtWidgets.QVBoxLayout()
        self.source_panel = _SourcePanel()
        left.addWidget(self.source_panel)

        self.btn_open  = QtWidgets.QPushButton("Open FrontPanel")
        self.btn_start = QtWidgets.QPushButton("Start")
        self.btn_stop  = QtWidgets.QPushButton("Stop")
        self.btn_start.setEnabled(False)
        self.btn_stop.setEnabled(False)
        left.addWidget(self.btn_open)
        left.addWidget(self.btn_start)
        left.addWidget(self.btn_stop)

        self.stats = _StatsPanel()
        left.addWidget(self.stats)
        left.addStretch(1)

        main_lo.addLayout(left, 0)
        self.plots = _PlotPanel()
        main_lo.addWidget(self.plots, 1)
        self.setCentralWidget(central)

        # ── Acquisition worker on its own thread ──────────────────────────
        self._thread = QtCore.QThread(self)
        self._worker = _AcquisitionWorker(serial)
        self._worker.moveToThread(self._thread)
        self._thread.start()

        # GUI → worker (queued)
        self._request_open.connect(self._worker.open)
        self._request_start.connect(self._worker.start)
        self._request_stop.connect(self._worker.stop)
        self._request_close.connect(self._worker.close)
        self._push_input.connect(self._worker.set_input)

        # worker → GUI (queued)
        self._worker.opened.connect(self._on_opened)
        self._worker.frameReady.connect(self._on_frame_ready)
        self._worker.failed.connect(self._on_failed)

        # Button signals
        self.btn_open.clicked.connect(self.on_open)
        self.btn_start.clicked.connect(self.on_start)
        self.btn_stop.clicked.connect(self.on_stop)

    # ── FrontPanel lifecycle ──────────────────────────────────────────────

    def on_open(self) -> None:
        self.btn_open.setEnabled(False)
        self.stats.set_status("opening…", ok=True)
        self._request_open.emit()

    @QtCore.pyqtSlot(str, bool, int)
    def _on_opened(self, info: str, ok: bool, frame_n: int) -> None:
        if ok:
            self.transport_open = True
            self.stats.set_status(f"open: {info}", ok=True)
            self.btn_start.setEnabled(True)
        else:
            self.stats.set_status(info, ok=False)
            self.btn_open.setEnabled(True)

    # ── Realtime loop control ─────────────────────────────────────────────

    def on_start(self) -> None:
        if not self.transport_open:
            self.stats.set_status("Open FrontPanel first.", ok=False)
            return
        self.running = True
        self._fps_t0 = time.monotonic()
        self._fps_frames = 0
        self.btn_start.setEnabled(False)
        self.btn_stop.setEnabled(True)
        self.stats.set_status("running", ok=True)
        # Order matters: request the start FIRST (worker resyncs frame_counter
        # there), THEN stage the first input frame.  Both are queued slots, so
        # Qt preserves order — but reading frame_counter before pushing input
        # makes the dependency obvious in the source.
        self._request_start.emit()
        self._push_input.emit(self.source_panel.make_frame())

    def on_stop(self) -> None:
        self.running = False
        self._request_stop.emit()
        self.btn_start.setEnabled(True)
        self.btn_stop.setEnabled(False)
        self.stats.set_status("stopped", ok=True)

    # ── worker results (run on the GUI thread) ────────────────────────────

    @QtCore.pyqtSlot(object)
    def _on_frame_ready(self, r: dict) -> None:
        if not self.running:
            return
        self.plots.update(r["input_re"], r["hw_db"], r["sw_db"])

        self._fps_frames += 1
        elapsed = time.monotonic() - self._fps_t0
        if elapsed > 0.5:
            self._fps_value = self._fps_frames / elapsed
            self._fps_t0 = time.monotonic()
            self._fps_frames = 0
        self.stats.update_frame(frame_n=r["frame_n"],
                                hw_cycles=r["hw_cycles"],
                                sw_us=r["sw_us"],
                                round_s=r["round_s"],
                                fps=self._fps_value,
                                peak_err_db=r["peak_err_db"],
                                sfdr_db=r["sfdr_db"])
        # Stage the next input frame (read GUI widgets here, on the GUI thread).
        self._push_input.emit(self.source_panel.make_frame())

    @QtCore.pyqtSlot(str)
    def _on_failed(self, msg: str) -> None:
        self.running = False
        self.btn_start.setEnabled(True)
        self.btn_stop.setEnabled(False)
        self.stats.set_status(msg, ok=False)

    # ── Clean shutdown ─────────────────────────────────────────────────────

    def closeEvent(self, event) -> None:
        # Stop the loop, close the transport on the worker thread, then join.
        self.running = False
        self._request_stop.emit()
        self._request_close.emit()
        self._thread.quit()
        self._thread.wait(3000)
        super().closeEvent(event)


# ──────────────────────────────────────────────────────────────────────────
# CLI / entry point
# ──────────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ostomachion FFT demo")
    parser.add_argument("--serial", type=str, default=None,
                        help="Opal Kelly device serial number "
                             "(default: first available)")
    args = parser.parse_args(argv)

    app = QtWidgets.QApplication(sys.argv)
    win = FftDemoWindow(serial=args.serial)
    win.show()
    return app.exec()


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
