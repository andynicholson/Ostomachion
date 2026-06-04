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

## 3. Major findings (⏳ TODO — not addressed in this pass)

| ID | File | Summary |
|----|------|---------|
| M1 | `fft_accel.c` | **Overflow detection is dead code.** `last_overflow` is declared/cleared/read but **never set** anywhere. `fft_accel_get_last_overflow()` always returns false. Either route `m_axis_status_tdata[0]` to a readable register and set the flag, or delete the API. |
| M2 | `fft_accel.c:323,352` | **Stale-IRQ window.** DMA channels are reset *after* `k_sem_reset()` + the 4096-word fill; a late IOC/ERR ISR in that window re-gives the sem and the next `k_sem_take` returns immediately on stale data. Reset the DMA channels *before* `k_sem_reset()`. |
| M3 | `fft_beat_counter.vhd`, `fp_fft_pipe_bridge.vhd:348` | **CDC contradicts the "stabilisation" docs.** Beat counts feed `okWireOut` combinationally with no synchronizer staging; the 32-bit `cycles`/`frame_count` cross via `xpm_cdc_array_single` (per-bit, can tear). Use `xpm_cdc_array_single` for the quasi-static beat counts and `xpm_cdc_handshake` for the multi-bit cycle count. |
| M4 | `xem7310.xdc` | **No `set_clock_groups -asynchronous`** between `aclk` and `okUH0`; CDC is guarded only by name-matched `set_false_path` globs that silently match nothing if instances are renamed. Add the async clock group as the primary exception. |
| M5 | `i2c_neorv32.c:420`, `spi_neorv32.c:346` | **`K_FOREVER` waits with unchecked `_nb` FIFO pushes in the ISR.** A single dropped push / lost FIRQ hangs the calling thread permanently. Use bounded `k_sem_take` timeouts and check the `_nb` return codes. |
| M6 | `i2c_neorv32.c:340,361` | **Double STOP** on the normal IRQ completion path (STOP at `next_msg:` then again at `done:`). The polling path guards this; the IRQ path does not. |
| M7 🔍 | `spi_neorv32.c:240` | SPI polling reads `DATA` gated on `BUSY` rather than an RX-available flag → stale read on hardware; `<<3`/`<<6`/`BIT(10)` clock-field shifts are unguarded magic numbers. **Verify against the pinned NEORV32 revision.** |
| M8 | `wdt_neorv32.c:164` | **STRICT-without-LOCK** contradicts the Kconfig claim that the WDT "cannot be silently disabled"; `disable()` just writes 0. RCAUSE reset-cause reporting is documented but unimplemented. |
| M9 | `tools/fft_demo/app.py` | **PyQt demo runs the whole FFT round-trip on the GUI thread** (`QTimer.singleShot` → blocking `recv_frame`/`send_frame`), freezing the UI up to 2 s. Move acquisition to a worker thread with queued signal/slot delivery. |
| M10 | `ci.yml`, `vivado-synth.yml` | **Supply chain:** no third-party action is SHA-pinned (`@v4`); the self-hosted Vivado runner builds an arbitrary `inputs.ref` with no workspace cleanup. Pin actions to SHAs; add `git clean -ffdx` or use an ephemeral runner. |

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
3. ⏳ **M1/M2/M5/M6/M8** — driver correctness (implement-or-remove overflow,
   reorder the DMA reset, bounded waits, double-STOP, WDT lock contradiction).
4. ⏳ **M4 / M3** — timing exceptions and CDC staging before real timing closure.
5. ⏳ **Doc reconciliation pass** — address map, "stabilisation," overflow API,
   WDT guarantee. Treat docs as code: a claimed guarantee needs an enforcing
   test or constraint.
