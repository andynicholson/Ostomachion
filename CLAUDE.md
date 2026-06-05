# CLAUDE.md — Ostomachion FPGA Platform Guide

Guidance for AI assistants and contributors working on Ostomachion from a
**senior FPGA architect** perspective.  For setup walkthroughs see
[GETTING_STARTED.md](GETTING_STARTED.md); for API and tree detail see
[DEVELOPER.md](DEVELOPER.md).

---

## Project identity

Ostomachion is a **NEORV32 RISC-V SoC + Zephyr RTOS** platform on the
**Opal Kelly XEM7310-A200** (Xilinx Artix-7 XC7A200T), with a DMA-driven
**4096-point xFFT** accelerator pipeline in fabric.

Design philosophy: a small set of composable, interlocking parts — fourteen
architectural layers documented in [README.md](README.md#the-fourteen-pieces).

- **License:** GPL-3.0-or-later or commercial ([LICENSE](LICENSE))
- **NEORV32:** upstream submodule at `neorv32/` — do not edit casually
- **Zephyr:** pinned via [west.yml](west.yml)

---

## Non-negotiable architecture rules

1. **No hand-edited Vivado checkpoints in the tree.**  The block design is
   recreated from Tcl on every build.  There must be no saved `.bd` files,
   `.xpr` projects, or GUI-generated wrappers under version control.

2. **Block design source of truth:** [`fpga/xem7310/ostomachion_bd.tcl`](fpga/xem7310/ostomachion_bd.tcl).
   All Xilinx IP (SmartConnect, AXI DMA, xfft, BRAM controllers, INTC, GPIO,
   clock wizard) lives inside the generated `ostomachion_bd_wrapper`.

3. **Board RTL source of truth:** [`fpga/xem7310/xem7310_top.vhd`](fpga/xem7310/xem7310_top.vhd).
   Hand-written VHDL for clocks, pads, NEORV32, bridge, FrontPanel, and UART/pipe
   bridges.  Do not put application logic inside the BD canvas.

4. **Simulation wrapper is separate:** [`rtl/neorv32_wrapper.vhd`](rtl/neorv32_wrapper.vhd)
   wraps `neorv32_top` for GHDL — it is not the FPGA top.

5. **Batch build entry point:** [`fpga/xem7310/build.tcl`](fpga/xem7310/build.tcl)
   invoked by `make fpga-synth`.  Quality gates in
   [`fpga/xem7310/check_build.tcl`](fpga/xem7310/check_build.tcl).

6. **All development happens on branches, merged via squash PRs.**  `master`
   (and `main`/`develop`) are protected: never commit or push directly to them.
   Every change — code, RTL, docs — lands through this flow:

   ```bash
   git checkout -b <type>/<short-topic>     # feat/, fix/, chore/, docs/, ci/
   # ... edit, build, verify ...
   git push -u origin <branch>
   gh pr create --base master --fill        # open the PR
   gh pr merge   --squash --delete-branch    # squash-merge once CI + review pass
   ```

   - **Squash-merge only** — one logical change becomes one commit on `master`,
     so history stays linear and bisectable.  Do not use merge commits or
     rebase-merge.
   - The PR must pass the automatic CI jobs (below) before merge.  Self-hosted
     Vivado synthesis is manual; run it for any RTL/constraints/BD change and
     cite the WNS/WHS/DRC result in the PR.
   - Branch names are typed: `feat/`, `fix/`, `chore/`, `docs/`, `ci/`,
     `refactor/`.  Delete the branch on merge (`--delete-branch`).
   - Record any non-obvious architectural decision or revert as a clause in
     [REVIEW.md](REVIEW.md) (the standing architectural contract / open ledger)
     in the same PR — treat docs as code.

---

## Fabric hierarchy

```
xem7310_top.vhd
├── IBUFDS (200 MHz LVDS oscillator)
├── neorv32_top + xbus2axi4_bridge → s_axi_cpu
├── ostomachion_bd_wrapper (Vivado-generated from ostomachion_bd.tcl)
│   ├── clk_wiz_0 (MMCM → 100 MHz aclk)
│   ├── proc_sys_reset_0
│   ├── axi_smc (SmartConnect: 3 masters × 5 slaves)
│   ├── axi_dma_0 (MM2S + S2MM)
│   ├── xfft_0 (4096-pt, 16-bit streaming)
│   ├── tx_bram / rx_bram + BRAM controllers
│   ├── axi_intc → mext_irq_o
│   └── axi_gpio (xfft aresetn gate)
├── okHost / okWire* / okPipe* (FrontPanel)
├── fp_uart_bridge (NEORV32 UART ↔ FrontPanel pipes)
├── fp_fft_pipe_bridge (host FFT pipe I/O)
└── fft_beat_counter (AXIS observability → WireOut 0x22)
```

**Boundary discipline:** CPU sees the accelerator only through the AXI map
(DMA registers + BRAM windows + INTC).  Host PC sees FrontPanel wires/pipes
in parallel — never substitute host pipes for CPU DMA paths without explicit
RTL design.

---

## Clock and reset domains

| Domain | Source | Consumers |
|--------|--------|-----------|
| `sys_clk` / `aclk` | 200 MHz LVDS → MMCM → 100 MHz | AXI, DMA, xfft, BRAM |
| NEORV32 core clock | Same 100 MHz from BD `clk_o` | CPU, peripherals |
| `okClk` | FrontPanel USB clock | WireIn/WireOut sampling |
| Async FIFO CDC | `fp_uart_bridge`, `fp_fft_pipe_bridge` | UART/pipe ↔ NEORV32 |

**Reset chain:** external reset → `proc_sys_reset_0` → peripheral `aresetn`.
The xfft core has an additional **software-gated** reset via AXI GPIO bit 0
(see [ACCEL_ARCH.md](ACCEL_ARCH.md)).

**CDC rule:** do not sample AXI-side beat counters directly into FrontPanel
without registered staging — `fft_beat_counter` outputs are registered on
`aclk` and sampled in `okClk` after stabilisation.

---

## AXI memory map (accelerator)

| Target | Base address | Size | Purpose |
|--------|-------------|------|---------|
| AXI DMA | `0x4000_0000` | 128 B | MM2S/S2MM channel registers |
| AXI INTC | `0x4001_0000` | 128 B | IRQ enable/status/vector |
| AXI GPIO | `0x4002_0000` | 128 B | xfft `aresetn` gate (ch1 bit 0) + overflow readback (ch2 0x08 bit 0) |
| TX BRAM | `0x4100_0000` | 32 KiB | Input frame staging (8192×32) |
| RX BRAM | `0x4100_8000` | 32 KiB | Output frame staging (8192×32) |

**INTC channel map:** Ch0 = MM2S complete, Ch1 = S2MM complete, Ch2 = xfft
frame-done (edge).  All aggregate onto NEORV32 `mext_irq_i`.

Full ordering invariants and failure modes: [ACCEL_ARCH.md](ACCEL_ARCH.md).

---

## Build flows

```bash
source scripts/init_dev_env.sh   # ZEPHYR_BASE, venv, FRONTPANEL_DIR, Vivado PATH
make test-zephyr                 # GHDL co-simulation (no Xilinx IP)
make fpga-synth                  # Vivado batch: synth + implement + bitstream
make fpga-check                  # timing / utilisation / DRC gates
make fpga-program                # FrontPanel USB bitstream load
```

**Required environment variables:**

| Variable | Purpose |
|----------|---------|
| `FRONTPANEL_DIR` | Opal Kelly SDK root (HDL + host libs) |
| `OSTOMACHION_VIVADO_SETTINGS` | Path to Vivado `settings64.sh` |
| `WEST_TOPDIR` | West workspace root (parent of `ostomachion/`) |

**NEORV32 IMEM image:** Zephyr builds emit `zephyr.vhd` via `image_gen`;
CI builds `neorv32/sw/image_gen/image_gen` before simulation.

---

## Verification boundaries

| Layer | Tool | What it validates |
|-------|------|-------------------|
| VHDL syntax/types | GHDL `-i` (CI `vhdl-lint`) | NEORV32 core, bridge, sim wrapper |
| Peripheral behaviour | GHDL + Zephyr ZTEST | GPIO, SPI loopback, I2C slave model |
| Firmware static analysis | clang-tidy, nm | C/C++ sources, memory map |
| FPGA synthesis | Vivado batch (manual CI) | Timing, utilisation, DRC |
| Hardware-in-the-loop | Twister on `xem7310` runner | Real FPGA + JTAG + UART |

**Not simulatable in GHDL:** xfft, AXI DMA, SmartConnect, encrypted Xilinx IP.
Do not attempt to elaborate `xem7310_top` or the BD wrapper in GHDL on CI.

**Sim time:** full ZTEST suite needs ~800 ms simulated time (~90 min on
GitHub-hosted GHDL).  CI sets `ZEPHYR_SIM_TIME=800ms`.

---

## What not to change casually

- **`neorv32/` submodule** — bump only with [docs/neorv32_upgrade_notes.md](docs/neorv32_upgrade_notes.md)
- **xfft transform sequencing** in [`zephyr_app/drivers/accel/fft_accel.c`](zephyr_app/drivers/accel/fft_accel.c) — frame order, DMA descriptor layout, INTC ack sequence
- **SmartConnect address map** in `ostomachion_bd.tcl` — driver and DTS assume fixed bases
- **INTC channel assignment** — Zephyr driver demuxes by channel index
- **Pin constraints** in [`fpga/xem7310/xem7310.xdc`](fpga/xem7310/xem7310.xdc) — board-specific, timing-critical

---

## CI expectations

**Automatic on every PR/push** (`.github/workflows/ci.yml`):

| Job | Runner | ~Duration |
|-----|--------|-----------|
| VHDL RTL lint | ubuntu-latest | ~20 s |
| GHDL + Zephyr simulation | ubuntu-latest | ~80–90 min |
| Twister test suite | ubuntu-latest | ~1 min |
| Firmware static analysis | ubuntu-latest | ~1 min |

**Manual only** (`.github/workflows/vivado-synth.yml`):

| Job | Runner | Trigger |
|-----|--------|---------|
| Vivado synthesis + timing closure | self-hosted, label `vivado` | Actions → Run workflow |

Register a self-hosted runner with label `vivado` on a machine with Vivado
2024.1+, FrontPanel SDK, and Artix-7 device support.  A separate `xem7310`
runner label is for hardware-in-the-loop Twister tests — see
[docs/acceptance_test_procedure.md](docs/acceptance_test_procedure.md)
Appendix B.

---

## Key documentation

| Document | Contents |
|----------|----------|
| [README.md](README.md) | Architecture overview, fourteen pieces, quick start |
| [ACCEL_ARCH.md](ACCEL_ARCH.md) | FFT pipeline contract and invariants |
| [DEVELOPER.md](DEVELOPER.md) | Full repo tree, HAL API, Twister matrix |
| [GETTING_STARTED.md](GETTING_STARTED.md) | First-time environment setup |
| [docs/acceptance_test_procedure.md](docs/acceptance_test_procedure.md) | HIL acceptance flow |
