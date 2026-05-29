# `fft_demo` — desktop demo for the Ostomachion FFT accelerator

A PyQt6 + pyqtgraph application that drives the on-FPGA Xilinx **xfft**
pipeline in realtime, overlays the same input's `numpy.fft` spectrum, and
reports HW / SW timing alongside a numerical-agreement gauge.

The CPU stays in the loop: the demo firmware reads each input frame from
the FrontPanel `BTPipeIn 0x81` FIFO into TX BRAM, calls
`fft_accel_transform()`, and pushes the result back through `BTPipeOut
0xA1`.  The host transport replaces UART for bulk samples only — the
existing accelerator driver, HAL, and DMA contract from
[`ACCEL_ARCH.md`](../../ACCEL_ARCH.md) are untouched.

```
+--------------+      BTPipe 0x81           +-----------+
|   PyQt6 GUI  |---- 4096 × 32 b samples -->| fifo_in   |--+
| (numpy.fft   |                            |           |  |  XBUS
|  reference)  |<----- 4096 × 32 b samples -| fifo_out  |  |  copy  fft_accel_transform()
+--------------+      BTPipe 0xA1           +-----------+  +-->  +-----------+
   WireOut 0x25 (hw_cycles)                      ^             |  AXI DMA  |
   WireOut 0x26 (frame_n)                        +-------------|   + xfft  |
                                                                +-----------+
```

## Prerequisites

The bitstream **must include** `fp_fft_pipe_bridge` in
`fpga/xem7310/xem7310_top.vhd` (merged on `master`).  Older bitstreams
built before that integration do not respond to `BTPipe 0x81 / 0xA1` or
`WireOuts 0x24..0x26`.

1. **Build & program the bitstream** (one-time after clone, or when FPGA RTL changes):

   ```bash
   source scripts/init_dev_env.sh
   make fpga-synth      # ~20-40 min in Vivado
   make fpga-program    # over FrontPanel USB
   ```

2. **Build & upload the demo firmware**:

   The Zephyr app needs the `fp_uart_bridge` PTY available for the
   bootloader upload step.  Run, in three terminals:

   ```bash
   # Terminal 1 — keep the UART bridge running:
   make uart-bridge                   # prints PTY path (e.g. /dev/pts/3)

   # Terminal 2 — upload demo firmware over that PTY:
   make demo-hw UART_DEVICE=/dev/pts/3

   # Stop the bridge once upload completes (Ctrl-C in Terminal 1).
   # The bridge holds the FrontPanel device exclusively, so the demo
   # cannot open it while the bridge is running.
   ```

3. **Install the Python deps** (once per environment):

   ```bash
   source scripts/init_dev_env.sh    # activates ~/.zephyr-venv, exports FRONTPANEL_DIR
   pip install -r tools/fft_demo/requirements.txt
   ```

   `transport.py` adds `$FRONTPANEL_DIR/API/Python` to `sys.path`
   automatically, so `import ok` works as long as `FRONTPANEL_DIR` is
   set (which `scripts/init_dev_env.sh` does).

## Smoke test (recommended first run)

Headless CLI verification of the full bitstream + firmware + transport
chain.  Run from the repository root:

```bash
source scripts/init_dev_env.sh
PYTHONPATH=tools python -m fft_demo.smoke_test
```

The script pushes DC, single-bin cosines, and a sine + noise frame
through the bridge, checks the HW peak bins against `np.fft` expectations,
and prints HW cycles per frame.  Exit code is 0 on success.

Typical good run with a current `master` bitstream and `demo-hw` firmware:

```
Device : Opal Kelly XEM7310 sn=2537001HTD fw=1.60
FIFOs  : in=0 out=0
  DC (amp=0.5)          peak bin=   0  expected=[0]          PASS
  Cosine bin 1          peak bin=   1  expected=[1, 4095]    PASS
  Cosine bin 64         peak bin=  64  expected=[64, 4032]   PASS
  Sine+noise bin 200    peak bin=3896  expected=[200, 3896]  PASS
Result : 4/4 cases passed
```

## Run

From the repository root:

```bash
source scripts/init_dev_env.sh
PYTHONPATH=tools python -m fft_demo
```

Then in the UI:

1. Click **Open FrontPanel**.  The status line shows the device serial.
2. Pick a source (Sine / Two sines / Noise / Sine + noise / DC) and
   tweak amplitude / bin / noise σ.
3. Click **Start**.

The top plot shows the input (time-domain Re); the bottom plot overlays
the HW spectrum (orange) and the numpy reference (dashed green) in dB.
The stats panel updates every frame:

| Field | Meaning |
|-------|---------|
| Frame #              | Firmware's free-running frame counter (WireOut 0x26). |
| HW FFT cycles        | `t1 - t0` around `fft_accel_transform()` in firmware (WireOut 0x25). |
| SW FFT (numpy)       | `time.perf_counter` around `np.fft.fft` on the host. |
| Host round-trip      | `send_frame` → frame_done → `recv_frame` wall-clock on the host. |
| End-to-end rate      | Frames per second, averaged over the last ~0.5 s. |
| Peak bin \|HW − SW\| | dB disagreement at the SW peak bin (and its conjugate alias). |
| HW SFDR              | Spurious-free dynamic range of the HW spectrum (peak − loudest non-peak bin). |

## What the numbers mean

- **HW FFT cycles** is the *compute-only* time inside
  `fft_accel_transform()` (DMA + xfft pipeline + IOC).  On healthy
  hardware it sits around 15 000 – 30 000 cycles (≈ 150 – 300 µs at
  100 MHz, see [`test_roundtrip_latency`](../../zephyr_app/tests/test_fft_accel.cpp)).
- **SW FFT (numpy)** runs on the host desktop CPU.  On a modern x86 with
  AVX numpy is typically *faster* than the FPGA for a single 4096-point
  transform — that's expected.  The interesting comparison would be
  against a NEORV32-side software FFT (kissfft), which is on the
  roadmap; the firmware reports HW cycles in isolation so we can add
  that later without changing the protocol.
- **Host round-trip** is dominated by USB latency and FrontPanel
  framing, not by the FFT itself.  Frame rate is normally limited by
  this, not by compute.
- **Peak bin \|HW − SW\|** evaluates the disagreement only at the bin
  where the SW spectrum is loudest (and at its conjugate alias for
  real-valued inputs).  For an integer-bin sinusoid this is the only
  bin that carries actual signal, so it cleanly separates "does the
  HW agree with numpy at the tone?" from "what does each path's
  noise floor look like?".  Expect ≲ 0.5 dB on healthy hardware.
- **HW SFDR** is the standard spurious-free-dynamic-range figure:
  peak HW bin minus the loudest HW bin that is *not* the peak.  For
  a single clean Q1.15 tone the FPGA pipeline sits in the 85 – 95 dB
  range; noisier inputs naturally bring it down.

## Operational notes

- The FrontPanel device is held exclusively.  The demo cannot run at
  the same time as `make uart-bridge` (or any other process holding the
  device).  Stop the bridge first.
- For a different board: `python -m fft_demo --serial <SERIAL>`.
- The transport blocks for at most 2 s waiting for the firmware to
  publish a new frame counter; if you see a timeout in the status line,
  the firmware probably isn't running (no `demo-hw` upload, wrong
  bitstream, or the `fft_accel` device failed to initialise).

## Files

| File | Purpose |
|------|---------|
| [`app.py`](app.py)          | PyQt6 main window, plotting, realtime loop. |
| [`transport.py`](transport.py)  | FrontPanel `ok.FrontPanel` wrapper (`send_frame`/`recv_frame`). |
| [`sources.py`](sources.py)      | Signal generators + Q1.15 / pipe pack-unpack. |
| [`requirements.txt`](requirements.txt) | `PyQt6`, `pyqtgraph`, `numpy`. |

The matching firmware is
[`zephyr_app/src/fft_demo_main.c`](../../zephyr_app/src/fft_demo_main.c)
(built by `make demo-hw`), and the bridge RTL is
[`fpga/xem7310/fp_fft_pipe_bridge.vhd`](../../fpga/xem7310/fp_fft_pipe_bridge.vhd).
