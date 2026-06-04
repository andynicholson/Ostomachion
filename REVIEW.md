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
| M3 | `fft_beat_counter.vhd`, `fp_fft_pipe_bridge.vhd:348` | **CDC contradicts the "stabilisation" docs.** Beat counts feed `okWireOut` combinationally with no synchronizer staging; the 32-bit `cycles`/`frame_count` cross via `xpm_cdc_array_single` (per-bit, can tear). Use `xpm_cdc_array_single` for the quasi-static beat counts and `xpm_cdc_handshake` for the multi-bit cycle count. |
| M4 | `xem7310.xdc` | **No `set_clock_groups -asynchronous`** between `aclk` and `okUH0`; CDC is guarded only by name-matched `set_false_path` globs that silently match nothing if instances are renamed. Add the async clock group as the primary exception. |
| M5 ✅ FIXED | `i2c_neorv32.c`, `spi_neorv32.c` | **`K_FOREVER` wait with unchecked `_nb` FIFO pushes in the ISR.** I2C: every ISR `twi_*_nb()` push is now checked and aborts to `done` on failure, and the completion wait uses a 1 s `TWI_XFER_TIMEOUT` backstop (releases the bus + disables IRQ on a lost FIRQ). SPI: the chained TX write in the ISR now guards `TX_FULL` and completes with `-EIO` rather than silently dropping the byte. (The SPI wait was `spi_context_wait_for_completion`, which already derives a master-mode timeout — not a literal `K_FOREVER` — so the genuine hazard there was the dropped-byte stall, now fixed.) |
| M6 ✅ FIXED | `i2c_neorv32.c` | **Double STOP** on the normal IRQ completion path. Restructured `next_msg:` so each path (final-with-STOP, final-without-STOP, more-messages, error) issues at most one STOP. Also fixed a latent off-by-one: the STOP-flag decision now reads `msgs[msg_idx]` *before* `msg_idx++`. |
| M7 ✅ VERIFIED — NOT A BUG | `spi_neorv32.c` | Checked against NEORV32 v1.11.6 (`56e1324d`). **No defect.** (1) The polling `put → while(BUSY) → read DATA` sequence is the *exact* upstream `neorv32_spi_transfer()` pattern, and `SPI_CTRL_BUSY` (bit 31) is defined as "transceiver busy **or TX FIFO not empty**" — so when it clears the full-duplex byte has completed and the RX FIFO holds the result; reading `DATA` then is correct, not a stale read. (2) The clock-field shifts are right: `PRSC<<3`, `CDIV<<6`, `HIGHSPEED=BIT(10)` match upstream `SPI_CTRL_PRSC0=3`, `CDIV0=6`, `HIGHSPEED=10`. The original review flagged this as a risk pending header confirmation; the headers confirm the driver is correct. |
| M8 ✅ FIXED | `wdt_neorv32.c`, `wdt/Kconfig` | **STRICT-without-LOCK** contradicted the "cannot be silently disabled" claim. Added opt-in `CONFIG_WDT_NEORV32_LOCK` (default n): when set, `setup()` also sets the CTRL LOCK bit so `disable()` returns `-EPERM` and the config is immutable until reset — that is what actually delivers tamper resistance. Corrected the Kconfig/`setup()` text to stop claiming STRICT alone prevents disable. Default-n keeps the existing `disable()`-based tests working. (RCAUSE reset-cause reporting remains unimplemented — deferred.) |
| M9 | `tools/fft_demo/app.py` | **PyQt demo runs the whole FFT round-trip on the GUI thread** (`QTimer.singleShot` → blocking `recv_frame`/`send_frame`), freezing the UI up to 2 s. Move acquisition to a worker thread with queued signal/slot delivery. |
| M10 | `ci.yml`, `vivado-synth.yml` | **Supply chain:** no third-party action is SHA-pinned (`@v4`); the self-hosted Vivado runner builds an arbitrary `inputs.ref` with no workspace cleanup. Pin actions to SHAs; add `git clean -ffdx` or use an ephemeral runner. |

### 3a. M1 fabric change — hardware verification checklist 🔍

The overflow path touches the block design and top RTL, **neither of which can
be synthesized or simulated in the review environment** (no Vivado / Artix-7,
and GHDL cannot elaborate the BD wrapper or `unisim`/`xpm` primitives). The
following must be confirmed on the next `vivado-synth` run before M1 is
considered closed:

- **`m_axis_status_tdata` width.** The Tcl queries the pin width and only
  inserts an `xlslice` when it is > 1 bit. Confirm the slice (or the
  straight-through connect) elaborates and that bit 0 is the overflow flag for
  this xfft config (PG109: `OVFLO` is the LSB of the status word).
- **AXI GPIO dual-channel.** Confirm `C_IS_DUAL=1` with `gpio2_io_i` as a
  1-bit input synthesizes and that `GPIO2_DATA` (0x08) reads bit 0 within the
  existing `0x80` range (no address-map change needed).
- **BD wrapper port names.** The new scalar ports (`fft_status_tvalid`,
  `fft_status_overflow`, `xfft_aresetn_o`, `fft_overflow_latched`) should pass
  through `make_wrapper` verbatim (Vivado only mangles bus/interface ports).
  Verify the generated `ostomachion_bd_wrapper.vhd` matches the names used in
  `xem7310_top.vhd`.
- **End-to-end.** With a deliberately over-amplitude input frame, confirm
  `fft_accel_get_last_overflow()` returns true, and that it returns false for a
  well-scaled frame (the latch clears on the per-transform `aresetn`).

---

## 4. Minor findings (⏳ TODO)

- **Address-map docs are wrong by orders of magnitude.** `CLAUDE.md` says
  DMA/INTC/GPIO are **64 KiB** each; the Tcl assigns `0x80` (128 B) and the DTS
  agrees with the Tcl. The DTS `dma` reg size is `0x40` but the driver touches
  S2MM registers up to `0x58`. Reconcile `CLAUDE.md`, `ACCEL_ARCH.md`, the Tcl,
  and the overlay.
- **Dead runtime guards:** `byte_len > dma_max_bytes` can never trip (`n==4096`
  is already forced); `reset_err |= …` works only by two's-complement luck.
- **FFT-region address aliasing:** the host-pipe bridge decodes only
  `xbus_addr(3:0)`, so any 16-byte-aligned address in the 256 MB `0x9xxx_xxxx`
  region aliases onto the FIFO-pop register; stray accesses pop samples.
- **UART RX FIFO silently drops bytes** on `rxf_full` with `overflow` tied open.
- **`prj.conf` forces `CONFIG_ZTEST=y`** unconditionally, so the "production"
  firmware analyzed by CI is a test build pulling in all `tests/*.cpp`.
- **DRC/timing gates are text-matched, not severity-parsed** (`regexp {ERROR}`
  on `report_drc` strings); the timing gate ignores the unconstrained-path count.
- **`test-zephyr` PASS grep is too loose:** greps for `PROJECT EXECUTION
  SUCCESSFUL`, which prints even when individual ZTEST assertions FAIL.
- **`transport.close()` doesn't release the USB device** (relies on GC); no
  `closeEvent`, so the demo holds the FrontPanel handle until process exit.
- **`openocd.cfg` declares `pld device virtex2`** for a 7-series Artix (wrong
  family, vestigial).

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
