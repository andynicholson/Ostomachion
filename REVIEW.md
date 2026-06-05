# Ostomachion — Architecture & Code Review

_Top-to-bottom review of the entire stack (RTL, Vivado block design, Zephyr
firmware, host tooling, build/CI, docs). Findings were produced by parallel
subsystem reviews and every Critical/Major item was verified against source._

> **Status legend:** ✅ FIXED in this pass · ⏳ TODO (tracked here) ·
> 🔍 needs hardware / `neorv32/` submodule checkout to confirm

---

## 1. Overall assessment

The architecture is sound and unusually disciplined. The boundary model — the
CPU reaches the accelerator **only** through the AXI map (DMA registers + BRAM
windows + INTC), while the host PC reaches FrontPanel wires/pipes in parallel —
is clean and consistently enforced. The block design is genuinely recreated
from Tcl (no checkpoints in the tree), the SmartConnect address-space isolation
between the MM2S/S2MM channels is correct, the xfft scaling schedule is
arithmetically right, and the `west.yml` / SDK pinning is reproducible.

The problems are not architectural. They cluster around a single recurring
failure mode that runs through every layer:

> **Documentation and comments assert guarantees that the implementation does
> not provide, and the CI that should catch the drift is itself non-functional.**

Several headline features (overflow detection, CDC "stabilisation", watchdog
tamper-resistance, the static-analysis and Twister gates) are described in
detail but are dead, racy, or theatrical in the code. The single highest-leverage
remediation is to **close the loop between documentation and verification**:
make the CI gates able to fail, then treat every documented guarantee as
something a test or constraint must enforce.

---

## 2. Critical findings

### C1 — FFT driver has no memory barrier between BRAM fill and the DMA trigger ✅ FIXED
`zephyr_app/drivers/accel/fft_accel.c`. The TX-BRAM fill (`sys_write32`) and the
`DMA_MM2S_LENGTH` trigger write target **different AXI slaves** through the
SmartConnect, with no global-ordering guarantee. NEORV32 has no D-cache, so this
is a store-ordering bug, not a coherency bug: if the LENGTH write overtakes the
last BRAM store, the DMA reads stale data for the final beat(s). The reverse
hazard exists before the RX-BRAM read loop. `volatile` orders the compiler, not
the XBUS→AXI fabric.

**Fix applied:** `#include <zephyr/sys/barrier.h>`; `barrier_dmem_fence_full()`
after the TX-BRAM fill loop (before any DMA register access) and again after
`k_sem_take()` succeeds, before the RX-BRAM read loop.

### C2 — The CI "static analysis" and "Twister" gates validate nothing ✅ FIXED
`.github/workflows/ci.yml`. The safety net that should have caught most of this
review was inert:
- **clang-tidy could not fail:** the step ended in `| tee … || true` and
  `.clang-tidy` set `WarningsAsErrors: ''`.
- **`nm` could not fail and ran a binary that is never installed:** it tried
  `riscv64-unknown-elf-nm` first (only `binutils-riscv64-linux-gnu` is
  installed), redirected errors *into* the uploaded "memory map," and ended
  `|| true`.
- **Twister could not fail and had no buildable test project:** the invocation
  piped to `tee` with no `pipefail`, omitted `--exclude-tag hw` (so HW-only
  cases error on the hosted runner), and `zephyr_app/tests/` contained only
  `.cpp` + `testcase.yaml` — **no `CMakeLists.txt` / `prj.conf`**, so
  `west twister -T zephyr_app/tests` finds no application to build. (The tests
  are actually compiled into the app build via `zephyr_app/CMakeLists.txt`.)
- The analysis build targeted `-b neorv32` while everything else uses
  `neorv32/neorv32/minimalboot`, and that step also piped to `tee` with no
  `pipefail`.

**Fix applied:** added `set -o pipefail` to every piped step and removed the
`|| true` masks; made clang-tidy a real gate (`--warnings-as-errors='*'`);
rewrote the `nm` step to select an installed binary, keep errors out of the
artifact, and fail if none is found; corrected the analysis board to
`neorv32/neorv32/minimalboot`; moved `testcase.yaml` to the app root
(`zephyr_app/testcase.yaml`) so Twister has a buildable project, and pointed the
job at `-T zephyr_app --exclude-tag hw`.

> ⚠️ Because these gates are now enforced, the first CI run may surface
> pre-existing clang-tidy findings or build issues that were previously hidden.
> That is the intended behaviour — triage them rather than re-muting the gate.

### C3 — Async-FIFO reset-busy outputs discarded; reset crosses domains unsynchronized ✅ FIXED
`fpga/xem7310/fp_fft_pipe_bridge.vhd` and `fpga/xem7310/fp_uart_bridge.vhd`. All
four `xpm_fifo_async` instances drove `rst => not sys_rstn` (an `aclk`-domain
reset) while straddling `aclk`↔`fp_clk`, and tied `wr_rst_busy`/`rd_rst_busy` to
`open`. XPM **drops** writes/reads issued while reset-busy is asserted, so every
reset opened a silent data-loss / lockup window.

**Fix applied:** exposed `wr_rst_busy`/`rd_rst_busy` on all four FIFOs and gated
the corresponding `wr_en`/`rd_en` (and the `pi_ready`/`po_ready`/`tx_ready`/
`rx_ready` host-handshake flags) with them, following the XPM-recommended
pattern. The busy flags are consumed in their own clock domain, so no new CDC
and no XDC change is required.

---

## 3. Major findings

| ID | File | Summary |
|----|------|---------|
| M1 ✅ FIXED 🔍 | `ostomachion_bd.tcl`, `xem7310_top.vhd`, `fft_accel.c` | **Overflow detection was dead code** (`last_overflow` never set). Implemented in fabric: the BD slices `m_axis_status_tdata[0]` out and exposes it (+ its `tvalid` and the xfft `aresetn`) as ports; `xem7310_top.vhd` holds a sticky latch (cleared by the per-transform `aresetn` pulse) fed into the AXI GPIO input channel; the driver reads it at `GPIO_DATA2` (0x08) after IOC and sets `last_overflow`. **🔍 The fabric portions require Vivado synthesis to verify** — see §3a. |
| M2 ✅ FIXED | `fft_accel.c` | **Stale-IRQ window.** `k_sem_reset()` moved to *after* both DMA channels are reset and the xfft is back out of reset, but before either channel is armed — so a late IOC/ERR ISR from a prior timed-out transfer can no longer survive into the next one. (Previously the reset preceded the ~4096-word fill, leaving the window open.) |
| M3 ✅ FIXED | `fp_fft_pipe_bridge.vhd`, `xem7310_top.vhd` | **Multi-bit CDC could tear.** The arbitrary 32-bit `cycles` value now crosses via `xpm_cdc_handshake` (atomic whole-bus transfer) instead of per-bit `xpm_cdc_array_single`; the fp-side `frame_count` is derived from the handshake `dest_req` so "new frame_count ⇒ cycles coherent and fresh" holds by construction. The three aclk-domain beat-counter status words (previously fed combinationally into okClk-sampled WireOuts 0x22/0x23) are now staged through `xpm_cdc_array_single` in `xem7310_top.vhd`. **Verified:** synthesizes with 0 errors/0 critical warnings, timing closes. |
| M4 ✅ FIXED | `xem7310.xdc` | Added `set_clock_groups -asynchronous` between the `sys_clk`, `okUH0`, and `jtag_tck` trees (`-include_generated_clocks`) as the *primary* CDC exception, so coverage is structural rather than dependent on name-matched `set_false_path` globs. **Verified on the implemented checkpoint:** `report_clock_interaction` shows `clk_out1_…clk_wiz ↔ mmcm0_clk0` and `jtag_tck ↔ *` as **"Ignored / Asynchronous Groups"**, while the okHost-internal `mmcm0_clk0 ↔ okUH0` pair stays correctly **"Timed"** (they are synchronous to each other). WNS +0.042 / WHS +0.018, DRC clean. |
| M5 ✅ FIXED | `i2c_neorv32.c`, `spi_neorv32.c` | **`K_FOREVER` wait with unchecked `_nb` FIFO pushes in the ISR.** I2C: every ISR `twi_*_nb()` push is now checked and aborts to `done` on failure, and the completion wait uses a 1 s `TWI_XFER_TIMEOUT` backstop (releases the bus + disables IRQ on a lost FIRQ). SPI: the chained TX write in the ISR now guards `TX_FULL` and completes with `-EIO` rather than silently dropping the byte. (The SPI wait was `spi_context_wait_for_completion`, which already derives a master-mode timeout — not a literal `K_FOREVER` — so the genuine hazard there was the dropped-byte stall, now fixed.) |
| M6 ✅ FIXED | `i2c_neorv32.c` | **Double STOP** on the normal IRQ completion path. Restructured `next_msg:` so each path (final-with-STOP, final-without-STOP, more-messages, error) issues at most one STOP. Also fixed a latent off-by-one: the STOP-flag decision now reads `msgs[msg_idx]` *before* `msg_idx++`. |
| M7 ✅ VERIFIED — NOT A BUG | `spi_neorv32.c` | Checked against NEORV32 v1.11.6 (`56e1324d`). **No defect.** (1) The polling `put → while(BUSY) → read DATA` sequence is the *exact* upstream `neorv32_spi_transfer()` pattern, and `SPI_CTRL_BUSY` (bit 31) is defined as "transceiver busy **or TX FIFO not empty**" — so when it clears the full-duplex byte has completed and the RX FIFO holds the result; reading `DATA` then is correct, not a stale read. (2) The clock-field shifts are right: `PRSC<<3`, `CDIV<<6`, `HIGHSPEED=BIT(10)` match upstream `SPI_CTRL_PRSC0=3`, `CDIV0=6`, `HIGHSPEED=10`. The original review flagged this as a risk pending header confirmation; the headers confirm the driver is correct. |
| M8 ✅ FIXED | `wdt_neorv32.c`, `wdt/Kconfig` | **STRICT-without-LOCK** contradicted the "cannot be silently disabled" claim. Added opt-in `CONFIG_WDT_NEORV32_LOCK` (default n): when set, `setup()` also sets the CTRL LOCK bit so `disable()` returns `-EPERM` and the config is immutable until reset — that is what actually delivers tamper resistance. Corrected the Kconfig/`setup()` text to stop claiming STRICT alone prevents disable. Default-n keeps the existing `disable()`-based tests working. (RCAUSE reset-cause reporting remains unimplemented — deferred.) |
| M9 ✅ FIXED | `tools/fft_demo/app.py` | **PyQt demo ran the FFT round-trip on the GUI thread.** Moved the blocking `send_frame`/`recv_frame` (up to 2 s) and the SW FFT into a `QThread`-based `_AcquisitionWorker`; the GUI thread now only renders, via queued `frameReady`/`opened`/`failed` signals. The FrontPanel handle is created/opened/used/closed entirely on the worker thread (it is not thread-safe). Added a `closeEvent` that stops and joins the worker — which **also fixes the Minor finding** that `transport.close()` never released the device. **Verified headlessly** (offscreen Qt): worker signals/slots present, window constructs with the thread running, clean shutdown joins the thread. |
| M10 ✅ FIXED | `ci.yml`, `vivado-synth.yml` | **Supply chain.** All third-party actions SHA-pinned: `actions/checkout@11bd719` (v4.2.2), `actions/upload-artifact@b4b15b8` (v4.4.3), each with a version comment. The self-hosted Vivado runner now does a clean checkout (`clean: true`, `fetch-depth: 0`) plus a `git clean -ffdx` scrub (including submodules) before building, so a previous `inputs.ref` build cannot leave a dirty tree or stale artifacts. Both workflows validated as well-formed YAML. |

### 3a. M1 fabric change — hardware verification checklist

Verified on a remote **Vivado 2025.1** host (Artix-7 `xc7a200tfbg484-1`) against
branch HEAD. Status of each item:

- ✅ **`m_axis_status_tdata` width.** The width-querying Tcl ran against the real
  xfft IP; `validate_bd_design` + `make_wrapper` completed cleanly and the
  `xlslice`-vs-straight-through branch resolved without error. (Bit 0 = `OVFLO`
  per PG109 still to be confirmed by the over-amplitude HW test below.)
- ✅ **AXI GPIO dual-channel.** `C_IS_DUAL=1` with `gpio2_io_i` synthesized; the
  generated wrapper exposes the input port and the existing `0x80` range is
  unchanged (no address-map edit needed).
- ✅ **BD wrapper port names.** The generated `ostomachion_bd_wrapper.vhd`
  exposes `fft_status_tvalid`, `xfft_aresetn_o`, `fft_overflow_latched`, and
  `fft_status_overflow`. **This surfaced a real bug:** single-bit ports sourced
  from a vector are emitted as `STD_LOGIC_VECTOR(0 to 0)`, but `xem7310_top.vhd`
  had declared the matching actuals as scalar `std_logic` — a type error that
  failed `synth_design` elaboration. Fixed (commit "Fix M1 scalar/vector port
  mismatch …"): both actuals are now `std_logic_vector(0 downto 0)`, indexed
  `(0)` at the latch. Full top + BD now elaborates with **0 Errors, 0 Critical
  Warnings**. This bug was invisible to GHDL/local review.
- ✅ **End-to-end on the XEM7310 DUT.** Ran a new `fft overflow` shell command
  (amplitude sweep from quiet to full-scale random complex) on real hardware via
  the FrontPanel UART bridge. Findings:
  - All transforms complete correctly (4096 beats/frame, PG109-correct) and the
    overflow readback register reads cleanly (`GPIO2 = 0x00000000`, not floating)
    — so the dual-channel GPIO input path and CPU read are functional.
  - With the production scaling schedule, `overflow=false` at *every* amplitude
    including full-scale random. This is **correct behaviour, not a stuck flag**:
    the config word `0x1555` decodes to a per-stage right-shift of `[2,2,2,2,2,2]`
    = ÷4 per radix-4 stage × 6 = **÷4096 exact unity gain** — the conservative
    schedule under which in-range Q1.15 input cannot overflow an intermediate
    stage. No normal input trips the flag by design.
  - **Positive-assertion proof (flag is not stuck-at-0) — CONFIRMED on the DUT.**
    Built a throwaway bitstream with stage 1 unscaled (`0x1551`, ÷1024 total) so
    full-scale input overflows an intermediate stage, programmed it, and reran
    `fft overflow`. Result:
    ```
    rand peak~ 1024  overflow=false  GPIO2=0x00000000
    rand peak~ 8190  overflow=false  GPIO2=0x00000000
    rand peak~32760  overflow=TRUE   GPIO2=0x00000001
    clear-check quiet frame after full-scale  overflow=false
    saw_false=1 saw_true=1 clears_after_high=1  PASS
    ```
    plus the driver's `LOG_WRN("FFT overflow occurred …")` fired. This proves the
    *entire* M1 chain toggles correctly: xfft `m_axis_status_tdata[0]` → fabric
    sticky latch (`GPIO2` bit 0) → driver `last_overflow` → `LOG_WRN`, and the
    per-transform `aresetn` clears the latch. The under-scaling edit was reverted
    immediately (BD tcl back to `5461`); the throwaway config is **not** in the
    tree, and the production bitstream (sha `06afbae5…`) was restored to the DUT.

**M1 verdict: fully verified.** On the production unity-gain schedule the flag
correctly stays low for all in-range input; on a deliberately under-scaled
config it asserts and clears exactly as designed. Permanent test artifact added:
the `fft overflow` shell command. Upload-path robustness fix (`uart_upload.py`:
retry + longer FrontPanel-pipe handshake timeout) committed alongside.

### 3b. Timing closure — baseline correction + regression check

An initial `build/xem7310/timing_summary.rpt` on the remote (dated Jun 1,
`25e235f4-dirty`) showed **WNS −3.673 ns / 202 failing endpoints** and a full
**DDR3 MIG** (`mig_0`, 800 MHz `freq_refclk`, a 24,993-endpoint `clk_pll_i`).
The current tree has **no MIG** — that report came from a *different
in-development branch* and is **not a valid baseline**. The correct baseline is
`master`, which closes timing with the present constraint set.

Regression scope of this branch vs `master` is therefore the relevant question,
and it is small and low-risk:
- **`xem7310.xdc` is unchanged vs `master`** → zero clock-constraint deltas; the
  same exceptions that let master close still apply.
- **No new clock-domain crossing was introduced.** The M1 overflow path is
  entirely `aclk → aclk` (status latch) → AXI GPIO → CPU; it never touches
  `okClk`/`okUH0`. C3's added logic (FIFO reset-busy AND-gates) is same-domain.
- A full `make fpga-synth` on this branch HEAD **completed and PASSED**:
  **WNS +0.042 ns, WHS +0.011 ns, 0 failing endpoints** (61,069 setup /
  60,893 hold), DRC clean, bitstream + MCS written. Utilisation 11% LUT /
  26% BRAM. So this branch *does* close timing — but the +42 ps setup margin is
  thin, and the ten worst paths all sit in the async FIFOs touched by C3
  (`fft_pipe_bridge_i/fifo_in_i`, `uart_bridge_i/tx_fifo_i`) in the
  ~100.8 MHz `okClk`/`mmcm0_clk0` domain. A `master` build is running to confirm
  whether +0.042 is the pre-existing margin or a C3 regression; result appended
  in §3c.

> **Note (PR hygiene, not timing):** `xem7310_top.vhd` was rewritten with CRLF
> line endings on this branch (master is LF), so git reports ~1470 changed lines
> where the real content delta is only +37/−1. Normalize to LF (`dos2unix`) and
> recommit before the PR. No synthesis impact.

### 3c. Timing regression check vs master — NO REGRESSION

Both builds run, same Vivado 2025.1 / `xc7a200tfbg484-1`:

| Build | WNS | WHS | Failing | LUT | BRAM |
|-------|-----|-----|---------|-----|------|
| `master` (`2d44acc`)        | **+0.042 ns** | +0.020 ns | 0 / 60,481 | 10.79% | 26.44% |
| branch (`8c68125`, C1/C3/M1) | **+0.042 ns** | +0.011 ns | 0 / 61,069 | 10.99% | 26.44% |

**Conclusion: the +0.042 ns setup margin is master's pre-existing
characteristic, not a regression from this branch.** The worst setup path has
identical slack (+0.042 ns) and structure (4 logic levels, RAMB18→RAMD32,
`mmcm0_clk0`) in both — it is the same path, untouched by C1/C3/M1. The branch
adds 588 setup endpoints (+0.97% LUT) for the C3 reset-busy gates and M1 latch,
and the worst path is unchanged. WHS dropped 9 ps (+0.020 → +0.011) but stays
comfortably positive with 0 failing hold endpoints.

The thin +42 ps margin is therefore an existing property of the design (the
~100.8 MHz `okClk` FIFO/CDC paths), and is exactly what **M4** addresses: a
`set_clock_groups -asynchronous` between `aclk` and `okUH0` would remove these
cross-domain paths from analysis entirely and recover margin. That remains the
recommended robustness improvement, but it does **not** gate this branch.

> **M3/M4 remain open and are the real timing-robustness work:** the current
> closure relies on name-matched `set_false_path` globs (M4) rather than a
> `set_clock_groups -asynchronous` between `aclk` and `okUH0`, and the multi-bit
> `cycles` CDC can tear (M3). These don't block this branch (XDC unchanged) but
> should be done before depending on the constraints across instance renames.

---

## 4. Minor findings (✅ ALL FIXED)

- ✅ **Address-map docs reconciled.** `CLAUDE.md` and `ACCEL_ARCH.md` now show
  DMA/INTC/GPIO as **128 B** each (matching the Tcl `0x80` assignment); the GPIO
  row notes the dual-channel overflow readback. The DTS `dma` reg size was bumped
  `0x40 -> 0x80` so it actually covers the S2MM registers the driver touches
  (up to `0x5C`).
- ✅ **Dead runtime guards.** `reset_err |= ...` replaced with explicit
  per-channel checks that propagate the real errno (`-ETIMEDOUT`) instead of an
  OR of two negative values; the `byte_len > dma_max_bytes` check is kept but
  documented as an intentional defense-in-depth backstop (redundant only while
  `n` is pinned to 4096).
- ✅ **FFT-region address aliasing.** The XBUS demux now requires `adr[27:4]=0`
  within the `0x9xxx_xxxx` region, so only `0x9000_000{0,4,8,C}` select the pipe
  bridge; any other in-region address falls through to the BD bridge path (which
  is unmapped there and raises `xbus_err`) instead of aliasing onto a FIFO
  register. **Verified:** elaborates with 0 errors.
- ✅ **UART RX FIFO drops are now observable.** Added a sticky `rx_overflow`
  latch (set when a byte is dropped on `rxf_full`, cleared on reset) surfaced on
  WireOut 0x20 bit 11. There is no back-pressure to the UART line by design, but
  a drop is no longer silent.
- ✅ **`prj.conf` is a clean base config.** `CONFIG_ZTEST=y` removed; ZTEST is now
  opt-in — added by the `zephyr` Makefile target for the GHDL sim run and by
  `testcase.yaml` for Twister/HW. The CI firmware-analysis build is now a real
  production image. Sim firmware re-verified to build.
- ✅ **DRC/timing gates are severity-aware.** Both `build.tcl` and
  `check_build.tcl` now use `get_drc_violations` filtered on Error/Critical
  severity instead of `regexp {ERROR}` on report text; `check_build.tcl` also
  flags unconstrained timing endpoints (WNS/WHS only cover constrained paths).
- ✅ **`test-zephyr` PASS check tightened.** It now requires non-empty output AND
  the `PROJECT EXECUTION SUCCESSFUL` marker AND the *absence* of ZTEST failure
  markers (`FAIL - `, `TESTSUITE ... failed`, `Assertion failed`, `FATAL`), so a
  failing assertion can no longer pass silently.
- ✅ **`transport.close()` releases the device explicitly** (`dev.Close()` guarded
  by `IsOpen()`), and M9's `closeEvent` invokes it on the worker thread — the
  FrontPanel handle is freed on exit rather than at GC.
- ✅ **`openocd.cfg`** duplicate `pld device` removed (the sourced
  `cpld/xilinx-xc7.cfg` already declares it). Note added that OpenOCD's series-7
  PLD driver is *named* `virtex2` for all xc7 parts, so the name was actually
  correct — the real issue was the redundant declaration in a debug-only cfg.

---

## 5. Verified-correct, non-trivial work

- xfft config word `0x1555` = FWD + six `>>2` stages = ÷4096, exactly cancelling
  the radix-4 butterfly gain.
- SmartConnect address-space isolation (MM2S sees only `tx_bram`, S2MM only
  `rx_bram`, via `exclude_bd_addr_seg`).
- S2MM-armed-before-MM2S ordering to avoid backpressure deadlock in nonrealtime
  throttle mode.
- Q1.15 endianness consistent across host, firmware, and RTL.
- Part number `xc7a200tfbg484-1`; `west.yml` SHA pin; SDK 1.0.0 consistency;
  `bin2vhd.py` byte/padding format; the `gpio`/`i2c`/`spi` C++ HAL wrappers; the
  `neorv32_wrapper.vhd` sim adapter.

---

## 6. Recommended priority order

1. ✅ **Make CI real (C2)** — done; everything else is unverifiable until the
   gates can fail.
2. ✅ **C1 fences, C3 FIFO reset-busy** — the two genuine data-corruption /
   lockup bugs in the shipped datapath.
3. ✅ **M1/M2/M5/M6/M8** — driver correctness: overflow detection in fabric
   (pending HW verify, §3a), stale-IRQ DMA-reset reorder, bounded I2C wait +
   ISR push checks, SPI dropped-byte guard, I2C double-STOP, and the opt-in
   WDT lock. ✅ **M7 verified NOT a bug** against NEORV32 v1.11.6 headers
   (SPI read pattern and clock-field shifts are upstream-correct). The same
   submodule check confirmed all SPI/TWI/WDT register bitfields touched by
   M5/M6/M8 match upstream (`SPI_CTRL_*`, `TWI_CTRL_*`, `TWI_CMD_*`,
   `WDT_CTRL_*`, and the WDT password).
4. ⏳ **M4 / M3** — timing exceptions and CDC staging before real timing closure.
5. ⏳ **Doc reconciliation pass** — address map, "stabilisation," overflow API,
   WDT guarantee. Treat docs as code: a claimed guarantee needs an enforcing
   test or constraint.
