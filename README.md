<p align="center">
  <a href="https://github.com/andynicholson/Ostomachion/actions/workflows/ci.yml?query=branch%3Amaster+event%3Apush">
    <img src="https://github.com/andynicholson/Ostomachion/actions/workflows/ci.yml/badge.svg?branch=master&event=push" alt="CI">
  </a>
  <a href="https://github.com/andynicholson/Ostomachion/actions/workflows/ci.yml?query=branch%3Amaster+event%3Apush">
    <img src="https://img.shields.io/github/actions/workflow/status/andynicholson/Ostomachion/ci.yml?branch=master&label=VHDL%20lint" alt="VHDL lint">
  </a>
  <a href="https://github.com/andynicholson/Ostomachion/actions/workflows/ci.yml?query=branch%3Amaster+event%3Apush">
    <img src="https://img.shields.io/github/actions/workflow/status/andynicholson/Ostomachion/ci.yml?branch=master&label=GHDL%20sim" alt="GHDL + Zephyr simulation">
  </a>
  <a href="https://github.com/andynicholson/Ostomachion/actions/workflows/ci.yml?query=branch%3Amaster+event%3Apush">
    <img src="https://img.shields.io/github/actions/workflow/status/andynicholson/Ostomachion/ci.yml?branch=master&label=Twister" alt="Twister test suite">
  </a>
  <a href="https://github.com/andynicholson/Ostomachion/actions/workflows/ci.yml?query=branch%3Amaster+event%3Apush">
    <img src="https://img.shields.io/github/actions/workflow/status/andynicholson/Ostomachion/ci.yml?branch=master&label=Firmware%20analysis" alt="Firmware static analysis">
  </a>
  <a href="https://github.com/andynicholson/Ostomachion/actions/workflows/vivado-synth.yml">
    <img src="https://img.shields.io/badge/Vivado-manual-blueviolet" alt="Vivado synthesis (manual workflow)">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-GPL--3.0--or--later-green.svg" alt="License: GPL-3.0-or-later">
  </a>
  <a href="LICENSES/Ostomachion-Commercial-1.0.txt">
    <img src="https://img.shields.io/badge/Commercial-license-blue.svg" alt="Commercial license available">
  </a>
</p>

Ostomachion is Archimedes' dissection puzzle — fourteen geometric pieces that
fit together in hundreds of distinct ways.  The name captures the design
philosophy: a small set of composable, interlocking parts that assemble into a complete, verified FPGA RTOS platform.

<p align="center">
  <img src="docs/img/logo.svg" alt="Ostomachion logo: fourteen-piece dissection of a square" width="220"/>
</p>

## What is Ostomachion?

[NEORV32 RISC-V](https://github.com/stnolting/neorv32) SoC running [Zephyr RTOS](https://www.zephyrproject.org/) on FPGA bare metal - with an extensible accelerator pipeline architecture, including an DMA xFFT RTL pipeline - wrapped in C++20 HAL from fabric to std::span.

The entire FPGA build is programmatic — a single Tcl script regenerates the full Vivado block design (IP configuration, clock tree, AXI address map, interconnect, and optional ILA debug probes) under headless `vivado -mode batch`, so every bitstream is reproducible from version-controlled text alone with no hand-edited checkpoints or saved GUI state anywhere in the tree.

Target hardware: **Opal Kelly XEM7310-A200** (Xilinx Artix-7 XC7A200T).
Simulation: **GHDL** with a full peripheral testbench.

## The fourteen pieces

Archimedes’ puzzle has fourteen tiles; here they are the composable layers of the platform, bottom to top:

1. **Artix-7 FPGA hardware** — XEM7310-A200, pin and timing constraints (`fpga/xem7310/xem7310.xdc`), volatile/persistent programming via FrontPanel USB.
2. **[NEORV32 RISC-V](https://github.com/stnolting/neorv32) SoC RTL** — Upstream `neorv32/` submodule (v1.11.6): RISC-V core, on-chip memory, CLINT, GPIO, UART, SPI, I2C (TWI), and external-bus masters.
3. **Board top-level VHDL** — `fpga/xem7310/xem7310_top.vhd` stitches clocks, resets, SoC, bridge, block-design wrapper, FrontPanel, pads, and the UART pipe bridge.
4. **XBUS → AXI4-Lite bridge** — RTL path from the CPU’s external bus to the Xilinx fabric for memory-mapped control of IP.
5. **Tcl-only Vivado block design** — `fpga/xem7310/ostomachion_bd.tcl` recreates the IP Integrator canvas from script (no hand-edited block design in the GUI necessary); sourced by the batch flow in `build.tcl`.
6. **Clocking and resets in fabric** — On-board LVDS oscillator → IBUFDS → MMCM in the BD (100 MHz system clock, locked status, peripheral reset network).
7. **Programmable frequency-domain transform pipeline** — time → forward **xfft** (4096-point, 16-bit, streaming) → **per-bin complex filter** (a user-programmable mask `H[k]` in a coefficient BRAM, applied by a fabric complex multiply) → inverse **xfft** → time, with **AXI DMA** staging through TX/RX **BRAM**.  A bypass bit lets the same bitstream serve both the plain forward FFT and the filtered round trip, so user-space can synthesise low/high/band-pass, notch, or arbitrary masks and run them in hardware.  **AXI INTC** aggregates the two DMA completion lines and the frame-complete pulse onto NEORV32 `mext_irq`.  Full design contract in [ACCEL_ARCH.md](ACCEL_ARCH.md).
8. **FrontPanel host interface** — `okHost` / pipes / wires in RTL for bitstream load, debug, and high-speed host I/O alongside MC headers.
9. **FrontPanel UART bridge** — `fp_uart_bridge.vhd` connects NEORV32 UART to FrontPanel pipes for host serial without extra USB-UART wiring.
10. **[Zephyr RTOS](https://www.zephyrproject.org/) and board port** — `west.yml` + board/soc glue; Zephyr is the primary RTOS for applications and drivers.
11. **Out-of-tree Zephyr drivers (C)** — `zephyr_app/drivers/` for NEORV32 SPI, TWI, watchdog, and the MMIO/IRQ-heavy `fft_accel` driver (DMA completion, INTC demux, timeouts).
12. **Devicetree and Kconfig** — Bindings under `zephyr_app/dts/`, base and target overlays (`app*.overlay`), and `prj*.conf` splits for simulation, FPGA, accelerator, shell, and hardware-test builds.
13. **C++20 header-only HAL** — `zephyr_app/include/ostomachion/` wraps Zephyr’s C APIs with `std::span`, `[[nodiscard]]`, and RAII-style device handles for GPIO, SPI, I2C, and FFT.
14. **Verification and automation** — GHDL testbench (`sim/`, `rtl/neorv32_wrapper.vhd`) for RTL-level peripherals; **ZTEST** suites and Twister matrix under `zephyr_app/tests/`; `Makefile` and CI for sim, firmware, and Vivado synthesis quality gates (`check_build.tcl`).

## 🏗️ Architecture

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  Application / ZTEST Suites                                      │
  │  (test_spi.cpp, test_i2c.cpp, test_gpio.cpp, test_fft_accel.cpp) │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  ostomachion::hal::SpiDevice / I2cBus
                           │  ostomachion::FftAccel  (: Accel)
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  C++20 HAL  (zephyr_app/include/ostomachion/)                    │
  │  Zero-overhead wrappers — std::span, [[nodiscard]], noexcept     │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  spi_transceive(), fft_accel_transform(), …
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Zephyr BSP — out-of-tree drivers, DTS overlays, Kconfig         │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  MMIO  sys_read32 / sys_write32
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Board RTL — xem7310_top.vhd                                     │
  │  NEORV32 · XBUS→AXI4-Lite bridge · FrontPanel · UART bridge     │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  s_axi_cpu, clocks, resets, mext_irq, …
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  ostomachion_bd_wrapper  (Tcl BD → Xilinx IP only)               │
  │  AXI DMA · xfft 4096-pt 16-bit · TX/RX BRAM · AXI INTC · MMCM    │
  └────────────────────────┬─────────────────────────────────────────┘
                           │
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  XEM7310-A200 hardware  /  GHDL simulation (neorv32_tb.vhd)      │
  └──────────────────────────────────────────────────────────────────┘
```

### RTL design (`xem7310_top` + `ostomachion_bd`)

Fabric RTL is split between **hand-written board VHDL** and a **Tcl-built Vivado block design**. `fpga/xem7310/xem7310_top.vhd` is the top: it brings in the 200 MHz LVDS clock (`IBUFDS`), pads and primitives for SPI, UART, TWI (`IOBUF`), JTAG and LEDs, **FrontPanel** (`okHost`, wires, pipes), **`fp_uart_bridge`** (NEORV32 UART ↔ host pipes), **`neorv32_top`**, and **`xbus2axi4_bridge`**, which terminates in the AXI4-Lite master port **`s_axi_cpu`** on the block design. The SoC external interrupt **`mext_irq`** is driven from the BD (`mext_irq_o`). Vivado generates **`ostomachion_bd_wrapper`** from `fpga/xem7310/ostomachion_bd.tcl` (`make_wrapper`); that wrapper contains **only Xilinx IP** — no application RTL inside the canvas.

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  Custom board RTL — fpga/xem7310/xem7310_top.vhd                 │
  │  IBUFDS (LVDS osc) · resets/LEDs/MC pads · std_ulogic stitching  │
  │  neorv32_top · xbus2axi4_bridge ↔ ostomachion_bd_wrapper ports   │
  │  okHost / okWire* / okPipe* · fp_uart_bridge (UART ↔ pipes)      │
  ├──────────────────────────────────────────────────────────────────┤
  │  ostomachion_bd_wrapper  (Vivado-generated around Tcl BD)        │
  ├──────────────────────────────────────────────────────────────────┤
  │  BD boundary / wrapper I/O (instantiated as entity work.…)       │
  │    s_axi_cpu_* · sys_clk · ck_rst · clk_o · periph_resetn_o      │
  │    mext_irq_o · fft_dbg_mm2s_tvalid · fft_dbg_s_data_tready      │
  ├──────────────────────────────────────────────────────────────────┤
  │  clk_wiz_0 (MMCM)      200 MHz in → 100 MHz aclk · locked        │
  │  proc_sys_reset_0      ext_reset · dcm_locked · aresetn nets     │
  ├──────────────────────────────────────────────────────────────────┤
  │  axi_smc (SmartConnect)   3 AXI masters → 5 MM targets           │
  │    S00 ← s_axi_cpu       S01 ← axi_dma M_AXI_MM2S                │
  │                          S02 ← axi_dma M_AXI_S2MM                │
  │    M00 → axi_dma S_AXI_LITE      @ 0x4000_0000                   │
  │    M01 → tx_bram_ctrl + tx_bram  @ 0x4100_0000 (32 KiB)          │
  │    M02 → rx_bram_ctrl + rx_bram  @ 0x4100_8000 (32 KiB)          │
  │    M03 → axi_intc                @ 0x4001_0000                   │
  │    M04 → axi_gpio (xfft aresetn gate) @ 0x4002_0000              │
  ├──────────────────────────────────────────────────────────────────┤
  │  axi_dma_0   MM2S + S2MM (no SG) · AXI-Lite + AXIS clocks        │
  │  xfft_0      4096-pt · 16b · pipelined streaming · ovfl          │
  │    M_AXIS_MM2S → s_axis_data ; m_axis_data → S_AXIS_S2MM         │
  │    xlconstant / const_one → s_axis_config (tvalid/tlast)         │
  ├──────────────────────────────────────────────────────────────────┤
  │  blk_mem_gen   tx_bram / rx_bram  (single-port BRAM ctrl)        │
  │  util_vector_logic AND  gpio_io_o[0] & periph_aresetn → xfft     │
  ├──────────────────────────────────────────────────────────────────┤
  │  xlconcat → axi_intc   Ch0 MM2S · Ch1 S2MM · Ch2 xfft frame-done │
  │               → mext_irq_o   (frame-done edge, DMA level)        │
  └──────────────────────────────────────────────────────────────────┘
```

## 📂 Repository layout

```
Makefile                  Build orchestration (GHDL sim, Zephyr, FPGA)
fpga/xem7310/             RTL, constraints, Vivado scripts, block design
rtl/                      Simulation wrapper (neorv32_wrapper.vhd)
sim/                      GHDL testbench and UART monitor
neorv32/                  NEORV32 RTL submodule (v1.11.6)
scripts/                  init_dev_env.sh, uart_bridge.py, bin2vhd.py
sw/test_gpio_uart/        Bare-metal smoke-test firmware
zephyr_app/               Zephyr application, drivers, HAL, tests
docs/                     Design documents and acceptance procedure
```

See [DEVELOPER.md](DEVELOPER.md) for the full annotated tree, peripheral map,
HAL API reference, and design rationale.

## ⚡ Quick start

```bash
cd /path/to/ostomachion
source scripts/init_dev_env.sh   # sets ZEPHYR_BASE, venv, FRONTPANEL_DIR, Vivado PATH
make test-zephyr                 # build Zephyr + run GHDL simulation
make fpga-synth                  # synthesise bitstream   (needs Vivado + FRONTPANEL_DIR)
make fpga-program                # load bitstream via FrontPanel USB
make fpga-fw                     # upload firmware via UART bootloader
```

See [GETTING_STARTED.md](GETTING_STARTED.md) for the full setup walkthrough.

## 🎯 Common make targets

| Target | Description |
|--------|-------------|
| `make test-zephyr` | Build Zephyr (sim config) + run GHDL simulation |
| `make test-baremetal` | Build bare-metal firmware + simulate |
| `make zephyr-fpga` | Build Zephyr firmware for FPGA |
| `make fpga-synth` | Synthesise + implement + bitstream |
| `make fpga-program` | Load bitstream (volatile, FrontPanel USB) |
| `make fpga-flash` | Program SPI flash (persistent) |
| `make fpga-fw` | Upload firmware via UART bootloader |
| `make uart-bridge` | Start FrontPanel UART bridge (PTY) |
| `make test-accel-hw` | Upload and run FFT accelerator ZTEST suite |
| `make shell-hw` | Upload interactive shell firmware |

## License

Ostomachion is dual-licensed under **GPL-3.0-or-later** or a **commercial
license** from the copyright holder.  See [`LICENSE`](LICENSE) for the full
GPL text and [`LICENSES/Ostomachion-Commercial-1.0.txt`](LICENSES/Ostomachion-Commercial-1.0.txt)
for commercial terms.  Contact **intothemist@gmail.com** to obtain a
commercial license.

Third-party components (NEORV32, Zephyr, Xilinx IP, Opal Kelly FrontPanel)
remain under their respective licenses.

## 🗺️ Known limitations

| Item | Status |
|------|--------|
| FFT GHDL simulation | Not supported — Xilinx encrypted IP is not simulatable in GHDL |
| 10-bit I2C addressing | Not supported — NEORV32 TWI is 7-bit only |
| Multi-instance FFT | Design constraint — one `FftAccel` instance, serialised by mutex |
| Additional FPGA board targets | Roadmap — parameterised `fpga/` layout supports new boards |
