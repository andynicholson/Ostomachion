<p align="center">
  <img src="docs/img/logo.png" width="200" alt="Ostomachion logo"/>
</p>
<p align="center">
  <b>NEORV32 RISC-V Processor &middot; Zephyr RTOS &middot; Custom RTL Accelerator Pipeline</b><br/>
  <i>Targeted to modern C++20 and FPGAs</i>
</p>

<p align="center">
  <a href="https://github.com/stnolting/neorv32">NEORV32</a> &middot;
  <a href="https://www.zephyrproject.org/">Zephyr Project</a>
</p>

---

## What is Ostomachion?

Ostomachion is Archimedes' dissection puzzle — fourteen geometric pieces that
fit together in hundreds of distinct ways.  The name captures the design
philosophy: a small set of composable, interlocking parts (NEORV32 RTL, Zephyr
RTOS, out-of-tree C drivers, C++20 HAL) that assemble into a complete,
verified FPGA RTOS platform.

The goal is a **professional starting point**, not a finished product.  Every
layer is independently testable and follows a consistent pattern, making it
straightforward to add new hardware accelerators and software components
without disturbing what already works.

Target hardware: **Opal Kelly XEM7310-A200** (Xilinx Artix-7 XC7A200T).
Simulation: **GHDL** with a full peripheral testbench.

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
  │  FPGA RTL — NEORV32 v1.11.6, XBUS→AXI4 bridge, FrontPanel UART  │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  AXI4-Lite
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Xilinx IP Subsystem  (ostomachion_bd.tcl)                       │
  │  AXI DMA · xfft 4096-pt 16-bit · TX/RX BRAM · AXI INTC · MMCM  │
  └────────────────────────┬─────────────────────────────────────────┘
                           │
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  XEM7310-A200 hardware  /  GHDL simulation (neorv32_tb.vhd)      │
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

## 🗺️ Known limitations

| Item | Status |
|------|--------|
| FFT GHDL simulation | Not supported — Xilinx encrypted IP is not simulatable in GHDL |
| 10-bit I2C addressing | Not supported — NEORV32 TWI is 7-bit only |
| Multi-instance FFT | Design constraint — one `FftAccel` instance, serialised by mutex |
| Additional FPGA board targets | Roadmap — parameterised `fpga/` layout supports new boards |
