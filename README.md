# Ostomachion

**A NEORV32 + Zephyr RTOS project targeted to modern C++20 and FPGAs.**

---

## What is Ostomachion?

Ostomachion is Archimedes' dissection puzzle — a grid of fourteen geometric
pieces that fit together in hundreds of distinct ways.  The name captures the
project's design philosophy: a small set of composable interlocking pieces
(NEORV32 RTL, Zephyr RTOS, out-of-tree C drivers, C++20 HAL) that assemble
into a complete, verified FPGA RTOS platform.

The goal is not a finished product but a **professional starting point**.
Every architectural decision is documented, every layer is independently
testable, and every peripheral follows the same pattern — making it
straightforward to add new hardware and software components without
disturbing what already works.

---

## Architecture

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  Application / ztest Suites                                      │
  │  (tests/test_spi.cpp, tests/test_i2c.cpp,                        │
  │   tests/test_gpio.cpp, tests/test_fft_accel.cpp)                 │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  ostomachion::hal::SpiDevice
                           │  ostomachion::hal::I2cBus
                           │  ostomachion::hal::GpioOutput
                           │  ostomachion::FftAccel
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  C++20 HAL  (zephyr_app/include/ostomachion/hal/)                │
  │  Zero-overhead wrappers — std::span, [[nodiscard]], noexcept     │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  spi_transceive(), i2c_write_read(),
                           │  fft_accel_transform(), …
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Zephyr BSP Layer                                                │
  │  • Out-of-tree drivers  (drivers/spi/, drivers/i2c/,            │
  │                          drivers/accel/)                          │
  │  • Device Tree overlays (app.overlay, app_accel.overlay)         │
  │  • DTS bindings         (dts/bindings/)                          │
  │  • Kconfig              (prj.conf, prj_accel.conf)               │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  MMIO reads/writes via sys_read32/write32
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  FPGA RTL  (NEORV32 v1.11.6  +  XBUS→AXI4-Lite bridge)          │
  │  RISC-V RV32IMAC soft-core, SPI master, TWI master, GPIO, UART  │
  │  Arty A7: fpga/arty_a7/arty_a7_top.vhd  (BUFG, IOBUF, OCD)     │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  AXI4-Lite  (rtl/xbus_axi4lite_bridge.vhd)
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Xilinx IP Subsystem  (fpga/arty_a7/ostomachion_bd.tcl)          │
  │  • AXI SmartConnect + AXI DMA                                    │
  │  • TX BRAM (0x41000000) ── xfft IP (64-pt, 16-bit) ── RX BRAM   │
  │  • TX BRAM (0x41004000)                                          │
  │  • MMCM clocking, proc_sys_reset                                 │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  (physical I/O pins / GHDL stimulus)
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Hardware (Arty A7-100T) / GHDL Simulation  (sim/neorv32_tb.vhd) │
  │  SPI loopback, I2C slave model, UART monitor, watchdog           │
  └──────────────────────────────────────────────────────────────────┘
```

---

## Repository layout

```
.
├── Makefile                          # Top-level build orchestration
├── scripts/
│   └── bin2vhd.py                   # ELF binary → VHDL IMEM image
├── rtl/
│   ├── neorv32_wrapper.vhd           # Simulation wrapper around neorv32_top
│   └── xbus_axi4lite_bridge.vhd      # XBUS (Wishbone) → AXI4-Lite master bridge
├── fpga/
│   └── arty_a7/
│       ├── arty_a7_top.vhd           # Arty A7-100T board top (NEORV32 + bridge + BD)
│       ├── arty_a7.xdc               # Vivado pin + timing constraints
│       ├── build.tcl                 # Non-interactive Vivado batch script
│       ├── ostomachion_bd.tcl        # IP Integrator block design (AXI DMA, xfft, BRAMs)
│       ├── check_build.tcl           # Post-build quality gates (timing, DRC)
│       └── openocd.cfg               # JTAG bitstream programming (OpenOCD)
├── sim/
│   ├── neorv32_tb.vhd                # GHDL testbench (clock, reset, bus monitors)
│   └── sim_uart_rx.vhd               # UART character decoder
├── neorv32/                          # NEORV32 RTL submodule (v1.11.6)
├── sw/test_gpio_uart/                # Bare-metal smoke-test firmware (C)
├── zephyr_app/
│   ├── CMakeLists.txt                # Zephyr app build (project: ostomachion)
│   ├── prj.conf                      # Kconfig — simulation target (polling drivers)
│   ├── prj_fpga.conf                 # Kconfig overlay — FPGA target (IRQ drivers)
│   ├── prj_accel.conf                # Kconfig overlay — FFT accelerator (CONFIG_FFT_ACCEL=y)
│   ├── prj_shell.conf                # Kconfig overlay — interactive shell image
│   ├── app.overlay                   # Device Tree — spi0, i2c0 nodes (simulation)
│   ├── app_fpga.overlay              # Device Tree overlay — 115200 baud (FPGA)
│   ├── app_accel.overlay             # Device Tree overlay — fft_accel node (FPGA)
│   ├── zephyr/module.yml             # Out-of-tree module descriptor
│   ├── include/
│   │   ├── zephyr/drivers/misc/
│   │   │   └── fft_accel.h           # Public C API: fft_accel_transform()
│   │   └── ostomachion/hal/
│   │       ├── gpio.hpp              # GpioOutput
│   │       ├── spi.hpp               # SpiDevice (std::span API)
│   │       ├── i2c.hpp               # I2cBus   (std::span API)
│   │       └── fft_accel.hpp         # FftAccel (C++20 RAII wrapper)
│   ├── src/
│   │   ├── main.cpp                  # LED heartbeat thread (K_THREAD_DEFINE)
│   │   ├── fft_shell.c               # "fft" shell commands (CONFIG_FFT_ACCEL guard)
│   │   └── test_runner.c             # "test run" shell command (peripheral test suites)
│   ├── tests/
│   │   ├── test_spi.cpp              # ZTEST_SUITE ostomachion_spi
│   │   ├── test_i2c.cpp              # ZTEST_SUITE ostomachion_i2c
│   │   ├── test_gpio.cpp             # ZTEST_SUITE ostomachion_gpio
│   │   └── test_fft_accel.cpp        # ZTEST_SUITE ostomachion_fft (CONFIG_FFT_ACCEL)
│   ├── dts/bindings/
│   │   ├── vendor-prefixes.txt       # "ostomachion" vendor prefix
│   │   ├── misc/ostomachion,fft-accel.yaml  # AXI DMA + xfft binding
│   │   ├── spi/neorv32,spi.yaml
│   │   └── i2c/neorv32,twi.yaml
│   └── drivers/
│       ├── neorv32_regs.h            # Shared poll budget + soc.h re-export
│       ├── spi/spi_neorv32.c         # SPI driver (polling + IRQ paths, Kconfig-gated)
│       ├── spi/Kconfig               # CONFIG_SPI_NEORV32 / CONFIG_SPI_NEORV32_INTERRUPT
│       ├── i2c/i2c_neorv32.c         # I2C driver (polling + IRQ paths, Kconfig-gated)
│       ├── i2c/Kconfig               # CONFIG_I2C_NEORV32 / CONFIG_I2C_NEORV32_INTERRUPT
│       ├── accel/fft_accel.c         # FFT accelerator driver (CONFIG_FFT_ACCEL)
│       ├── accel/Kconfig             # CONFIG_FFT_ACCEL
│       ├── Kconfig
│       └── CMakeLists.txt
```

---

## Peripheral map

| NEORV32 Generic    | Simulation | Arty A7-100T | MMIO Base    | IRQ/FIRQ | Zephyr compatible        | DT node      |
|--------------------|------------|--------------|--------------|----------|--------------------------|--------------|
| `IO_GPIO_NUM`      | 8          | 8            | `0xFFFFFFC0` | —        | `neorv32,gpio`           | (board)      |
| `IO_UART0_EN`      | true       | true         | `0xFFFFFFE0` | FIRQ 2   | `neorv32,uart`           | (board)      |
| `IO_SPI_EN`        | true       | true         | `0xFFF80000` | FIRQ 6   | `neorv32,spi`            | `spi0`       |
| `IO_TWI_EN`        | true       | true         | `0xFFF90000` | FIRQ 7   | `neorv32,twi`            | `i2c0`       |
| `IO_CLINT_EN`      | true       | true         | `0xF0000000` | —        | `neorv32,clint`          | (board)      |
| `IO_SPI_FIFO`      | 4          | 32           | —            | —        | FIFO depth               | —            |
| `IO_TWI_FIFO`      | 4          | 32           | —            | —        | FIFO depth               | —            |
| `IO_UART0_TX_FIFO` | 1          | 32           | —            | —        | TX FIFO depth            | —            |
| `BOOT_MODE_SELECT` | 2 (IMEM)   | 0 (bootloader)| —           | —        | Boot mode                | —            |
| `OCD_EN`           | false      | true         | —            | —        | On-chip debugger         | —            |
| `IO_WDT_EN`        | false      | true         | —            | —        | Watchdog                 | —            |
| `IMEM_SIZE`        | 64 KB      | 128 KB       | —            | —        | Instruction memory       | —            |
| `DMEM_SIZE`        | 64 KB      | 64 KB        | —            | —        | Data memory              | —            |
| AXI DMA ctrl       | —          | FPGA only    | `0x40000000` | MEI/IRQ 11 | `ostomachion,fft-accel`| `fft_accel`  |
| TX BRAM            | —          | FPGA only    | `0x41000000` | —        | (part of fft_accel)      | `fft_accel`  |
| RX BRAM            | —          | FPGA only    | `0x41004000` | —        | (part of fft_accel)      | `fft_accel`  |

---

## HAL API overview

All classes live in `namespace ostomachion::hal` and are header-only (2–5
lines each).  They are zero-overhead wrappers: the compiler sees through them
as easily as the underlying C calls.

### `GpioOutput`  (`include/ostomachion/hal/gpio.hpp`)

```cpp
ostomachion::hal::GpioOutput led{GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios)};
led.set(true);   // drive high
led.toggle();    // toggle
```

Panics at construction if `gpio_pin_configure_dt` fails — a misconfigured
GPIO is an unrecoverable hardware error.

### `SpiDevice`  (`include/ostomachion/hal/spi.hpp`)

```cpp
static const spi_config cfg = {
    .frequency = 1'000'000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
    .slave = 0,
};
ostomachion::hal::SpiDevice spi{DEVICE_DT_GET(DT_NODELABEL(spi0)), cfg};

std::array<std::byte, 4> tx{std::byte{0x11}, std::byte{0x22},
                             std::byte{0x33}, std::byte{0x44}};
std::array<std::byte, 4> rx{};
int err = spi.transfer(std::span{tx}, std::span{rx}); // [[nodiscard]]
```

Both a fixed-extent template overload (deduced from `std::array`) and a
dynamic-extent overload (`std::span<const std::byte>`) are provided.

### `I2cBus`  (`include/ostomachion/hal/i2c.hpp`)

```cpp
ostomachion::hal::I2cBus i2c{DEVICE_DT_GET(DT_NODELABEL(i2c0))};

std::array<std::byte, 1> tx{std::byte{0x42}};
std::array<std::byte, 1> rx{};
int err = i2c.write_then_read(0x50U, tx, rx); // [[nodiscard]]
```

Provides `write()`, `read()`, and `write_then_read()` (REPEATED START).

### `FftAccel`  (`include/ostomachion/hal/fft_accel.hpp`)

```cpp
#include <ostomachion/hal/fft_accel.hpp>

const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
ostomachion::FftAccel accel{dev};

if (!accel.ready()) { /* handle missing bitstream */ }

fft_sample_t in[64]{};
fft_sample_t out[64]{};

// Fill in[] with Q1.15 complex samples (re = int16_t, im = int16_t)
in[0].re = 16384; // 0.5 in Q1.15

int err = accel.transform(in, out, 64); // [[nodiscard]]
// out[] now contains the 64-point forward FFT result
// Frequency bin k occupies out[k].re + j·out[k].im (Q1.15, scaled)
```

`FftAccel` is non-copyable and non-movable by design; the underlying
driver serialises concurrent callers via a mutex, but sharing an instance
across threads without external synchronisation is not recommended.

---

## Testing

### Running the Zephyr test suite

```bash
source ~/.zephyr-venv/bin/activate
export ZEPHYR_BASE=~/src/zephyrproject/zephyr
make test-zephyr
```

The Zephyr application embeds the [ztest](https://docs.zephyrproject.org/latest/develop/test/ztest.html)
framework.  Two suites register automatically; the framework discovers and
runs them before the LED thread takes over.  The CI-parseable output (via
UART0) looks like:

```
Running TESTSUITE ostomachion_spi
===================================================================
START - test_loopback_zero
 PASS - test_loopback_zero in 0.XXX seconds
START - test_loopback_ff
 PASS - test_loopback_ff in 0.XXX seconds
START - test_loopback_a5
 PASS - test_loopback_a5 in 0.XXX seconds
START - test_multibyte
 PASS - test_multibyte in 0.XXX seconds
TESTSUITE ostomachion_spi succeeded

Running TESTSUITE ostomachion_i2c
===================================================================
START - test_write_read
 PASS - test_write_read in 0.XXX seconds
START - test_multibyte_write
 PASS - test_multibyte_write in 0.XXX seconds
START - test_multibyte_read
 PASS - test_multibyte_read in 0.XXX seconds
TESTSUITE ostomachion_i2c succeeded

PROJECT EXECUTION SUCCESSFUL
```

The `PROJECT EXECUTION SUCCESSFUL` / `FAILED` line is what CI tools
(including Zephyr's `twister` runner) parse to determine pass/fail.

### How the GHDL testbench validates each suite

**SPI** (`sim/neorv32_tb.vhd`): MOSI is wired directly to MISO.  Every
transmitted byte is echoed back unchanged.  The SPI bus monitor logs each
byte and reports partial transfers as warnings.

**I2C** (`sim/neorv32_tb.vhd`): A synthesized I2C slave state machine
responds at 7-bit address **0x50**.  It ACKs every write byte (logging
each to the console) and returns `0x5A` per read byte.  The open-drain bus
is modelled with resolved `std_logic` (`'0'` wins; released lines are `'1'`).

**Watchdog**: A separate testbench process asserts a fatal failure if the
GPIO toggle count is below a threshold at 190 ms of simulated time.  This
catches hangs where the system boots but never reaches the LED blink loop.

### Bare-metal smoke test

```bash
make test-baremetal
```

Builds a minimal C firmware that toggles GPIO pin 0 and prints a banner
over UART0 in sim-mode (characters go directly to the GHDL console,
bypassing the baud-rate generator).

---

## Getting started

### System packages

```bash
sudo apt install ghdl gtkwave gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf \
                 ninja-build device-tree-compiler cmake python3-venv
```

### Zephyr SDK

```bash
cd ~
wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.0/zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
tar xf zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
cd zephyr-sdk-1.0.0 && ./setup.sh
```

### Zephyr workspace

```bash
python3 -m venv ~/.zephyr-venv
source ~/.zephyr-venv/bin/activate
pip install west
west init -m https://github.com/zephyrproject-rtos/zephyr --mr main ~/src/zephyrproject
cd ~/src/zephyrproject && west update
pip install -r zephyr/scripts/requirements.txt
```

---

## Extending the platform

Adding a new NEORV32 peripheral (e.g. TRNG, PWM) follows a five-step recipe:

1. **Enable in RTL** — set the corresponding `IO_*_EN` generic in
   `rtl/neorv32_wrapper.vhd`.  Expose the I/O ports and connect them.

2. **Add a DTS binding** — create
   `zephyr_app/dts/bindings/<bus>/neorv32,<peripheral>.yaml` following the
   pattern in `neorv32,spi.yaml`.  Declare `reg`, `interrupts` (optional),
   and `syscon`.

3. **Write a Zephyr driver** — create `drivers/<bus>/<peripheral>_neorv32.c`.
   Follow the `spi_neorv32.c` / `i2c_neorv32.c` pattern:
   - Include `../neorv32_regs.h` for `NEORV32_POLL_RETRIES`.
   - Use `dev->config` inside `reg_read`/`reg_write` helpers (not a raw `cfg*`).
   - Add Kconfig and CMakeLists entries; wire them into `drivers/Kconfig` and
     `drivers/CMakeLists.txt`.

4. **Add a HAL class** — create
   `zephyr_app/include/ostomachion/hal/<peripheral>.hpp` in
   `namespace ostomachion::hal`.  Use `std::span<std::byte>` for buffers,
   `[[nodiscard]]` on error-returning methods, and `noexcept` throughout.

5. **Write a ztest suite** — create `zephyr_app/tests/test_<peripheral>.cpp`,
   register it with `ZTEST_SUITE(ostomachion_<peripheral>, ...)`, and add it
   to `CMakeLists.txt` `target_sources`.

---

## Makefile targets

| Target                | Description                                                       |
|-----------------------|-------------------------------------------------------------------|
| `make all`            | Analyze + simulate with default IMEM image                        |
| `make test-default`   | Clean + simulate with the built-in NEORV32 demo                   |
| `make test-baremetal` | Build bare-metal firmware + simulate                              |
| `make test-zephyr`    | Build Zephyr app + simulate (needs venv active)                   |
| `make zephyr`         | Build Zephyr app only (simulation target)                         |
| `make zephyr-fpga`    | Build Zephyr firmware for the FPGA target (115200 baud, IRQ drivers) |
| `make sw`             | Build bare-metal firmware only                                    |
| `make clean-ghdl`     | Remove GHDL artifacts (keeps firmware)                            |
| `make clean`          | Full clean (GHDL + firmware + all Zephyr build dirs)              |
| `make fpga-synth`     | Run Vivado: synthesise + implement + generate bitstream           |
| `make fpga-program`   | Load bitstream onto Arty A7 via JTAG (OpenOCD)                   |
| `make fpga-fw`        | Build + upload FPGA Zephyr firmware via UART bootloader           |
| `make fpga-check`     | Run post-build timing/DRC quality gates (`check_build.tcl`)       |
| `make test-hw`        | Build + upload hardware test firmware (SPI/I2C/GPIO ztest)        |
| `make test-accel-hw`  | Build + upload FFT accelerator ztest firmware                     |
| `make shell-hw`       | Build + upload interactive shell firmware (`fft`, `test` commands) |

Override `SIM_TIME` to control simulation duration:

```bash
make test-zephyr SIM_TIME=100ms   # faster iteration
make test-zephyr SIM_TIME=300ms   # more LED blink cycles for watchdog
```

---

## Design decisions

**Two build targets, one codebase.**
The project is designed for deployment on real FPGA hardware (Arty A7) with
GHDL simulation as a fast development and regression tool.  The same Zephyr
firmware, out-of-tree drivers, and C++20 HAL compile for both targets.
Target-specific differences are isolated to a VHDL top-level file, a DTS
overlay, and a Kconfig fragment — nothing in the shared application layer
knows which environment it is running in.

**Interrupt-driven drivers on hardware, polling available for simulation.**
The production driver path (`CONFIG_SPI_NEORV32_INTERRUPT=y`,
`CONFIG_I2C_NEORV32_INTERRUPT=y`, enabled by `prj_fpga.conf`) uses FIRQ 6
and 7 to yield the Zephyr thread between bytes, allowing other threads to
run while the bus hardware clocks data.  The polling fallback
(default in `prj.conf`) is retained for simulation convenience — it avoids
FIRQ timing dependencies in the testbench and keeps the simulation fast.
Both paths are compiled from the same source files, gated by `#ifdef`.

**19200 baud for simulation, 115200 for the FPGA application.**
GHDL evaluates the RTL cycle-by-cycle at ~200 kHz wall-clock speed.  19200
baud requires ~5200 simulated clock cycles per character — a practical
trade-off that keeps the 200 ms simulation window usable.  The FPGA
application overrides this to 115200 baud via `app_fpga.overlay`.  Note that
the NEORV32 BROM bootloader always runs at 19200 baud and cannot be changed
without recompiling the bootloader image.

**`BOOT_MODE_SELECT = 2` for simulation, `0` for FPGA.**
Mode 2 (boot from pre-initialised IMEM) skips the UART bootloader entirely,
avoiding a multi-second UART negotiation on every GHDL run.  On the Arty A7,
mode 0 (internal BROM bootloader) is used so firmware can be uploaded over
UART without re-synthesising — only `make fpga-fw` is needed for each
firmware iteration after the initial `make fpga-synth` + `make fpga-program`.

**BUFG and IOBUF in the FPGA top, not the simulation wrapper.**
`fpga/arty_a7/arty_a7_top.vhd` instantiates Xilinx `BUFG` (clock buffer)
and `IOBUF` (open-drain I2C) primitives directly.
`rtl/neorv32_wrapper.vhd` remains technology-neutral for simulation.
This separation means the NEORV32 core RTL is never touched for
board-specific concerns; each target has its own thin board-level wrapper.

**`std::span` + `std::byte` in the HAL.**
`std::byte` (C++17) is the standard type for uninterpreted binary data.
`std::span` (C++20) provides a zero-overhead, bounds-safe view of contiguous
buffers that replaces `void * + size_t` pairs without any runtime cost.
The Zephyr C API uses `void *` internally; the HAL bridges this cleanly with
a documented `const_cast` in `SpiDevice::transfer`.

**Ztest as the test runner.**
The `PROJECT EXECUTION SUCCESSFUL` / `FAILED` line in ztest output is what
Zephyr's `twister` CI runner parses.  Using ztest makes the project
immediately compatible with the standard Zephyr CI infrastructure.

---

## Known limitations and roadmap

| Item | Status |
|------|--------|
| Interrupt-driven SPI/I2C drivers | **Done** — `CONFIG_SPI_NEORV32_INTERRUPT` / `CONFIG_I2C_NEORV32_INTERRUPT`; enabled by `prj_fpga.conf` |
| Physical FPGA target (Arty A7-100T) | **Done** — `fpga/arty_a7/` with VHDL top, XDC, Vivado TCL, OpenOCD config |
| UART bootloader firmware upload | **Done** — `make fpga-fw` via `neorv32_upload.py` |
| JTAG on-chip debug | **Done** — `OCD_EN=true` in FPGA top, `openocd.cfg` + NEORV32 OCD config |
| Xilinx xfft FFT accelerator | **Done** — `ostomachion_bd.tcl` + `drivers/accel/fft_accel.c` + `hal/fft_accel.hpp` |
| FFT driver thread safety | **Known limitation** — callers serialised by mutex; concurrent multi-thread use discouraged |
| FFT GHDL simulation | **Not supported** — Xilinx encrypted IP is not simulatable in GHDL |
| `GpioInput` HAL class | Roadmap — trivial to add alongside `GpioOutput` |
| `twister` integration | Roadmap — add `testcase.yaml` and board YAML for Zephyr CI |
| SPI flash boot (`BOOT_MODE_SELECT=1`) | Roadmap — requires SPI flash programming flow |
| 10-bit I2C addressing | Not supported — NEORV32 TWI is 7-bit only |
| Second FPGA board target | Roadmap — parameterised `fpga/` layout supports additional boards |

---

## NEORV32 version lock

This project uses **NEORV32 v1.11.6**.  Newer versions (v1.12+) reorganized
the UART control register bits and are **not** compatible with the Zephyr
`uart_neorv32` driver in the supported Zephyr SDK.  Check the Zephyr board
support file `boards/riscv/neorv32/` before upgrading the submodule.

---

## Debugging with waveforms

Every simulation produces `output.ghw` in GHDL's native format:

```bash
gtkwave output.ghw
```

Useful signal paths:

| Signal path                              | What it shows             |
|------------------------------------------|---------------------------|
| `neorv32_tb.dut.neorv32_inst.clk_i`     | System clock              |
| `neorv32_tb.dut.neorv32_inst.rstn_i`    | Active-low reset          |
| `neorv32_tb.gpio`                        | GPIO output (8 bits)      |
| `neorv32_tb.uart_tx`                     | UART TX serial line       |
| `neorv32_tb.spi_mosi`                    | SPI MOSI                  |
| `neorv32_tb.twi_sda`                     | I2C SDA (open-drain)      |
| `neorv32_tb.twi_scl`                     | I2C SCL (open-drain)      |

The UART monitor also writes decoded characters to
`neorv32_tb.UART0_rx.out`:

```bash
cat neorv32_tb.UART0_rx.out
```

---

## Troubleshooting

**`image_gen` not found during `make test-zephyr`**
: Ensure the venv is activated and `ZEPHYR_BASE` is set before running.

**Simulation takes very long**
: GHDL interprets the RTL cycle-by-cycle.  200 ms at 100 MHz = 20 million
  clock cycles.  Reduce `SIM_TIME` for faster iteration; all SPI and I2C
  tests complete within the first ~120 ms of simulated time.

**No UART output in simulation**
: The bare-metal test uses UART sim-mode (characters go directly to stdout).
  The Zephyr test uses real 19200-baud serial — look for `UART0:` prefixed
  lines in the GHDL console output.  Confirm the testbench `BAUD` generic
  (19200) matches the firmware's configured baud rate.

**`CONFIG_UART_INTERRUPT_DRIVEN` causes hangs**
: The application uses polling UART mode (`CONFIG_UART_INTERRUPT_DRIVEN=n`).
  Interrupt-driven TX can hang in simulation if the FIRQ routing is not
  fully exercised.  The SPI and I2C drivers have their own independent
  interrupt paths gated by `CONFIG_SPI_NEORV32_INTERRUPT` and
  `CONFIG_I2C_NEORV32_INTERRUPT` (see `prj_fpga.conf`).

**ztest reports `PROJECT EXECUTION FAILED`**
: Check the `FAIL -` lines in the UART log for the specific assertion that
  fired.  The most common cause is the testbench I2C slave timing out if
  `SIM_TIME` is too short — try `SIM_TIME=300ms`.

---

## Deploying to Arty A7

The FPGA build targets the Digilent **Arty A7-100T** (XC7A100T, CSG324 package).
All required files live in `fpga/arty_a7/`.

> **Board variant note:** The Arty A7-100T and A7-35T share the same PCB and
> pin-compatible CSG324 package.  The 100T is required because the design
> uses ~58 RAMB36 (xfft IP, AXI DMA, TX/RX BRAMs, NEORV32 IMEM/DMEM) and
> the 35T provides only 50 RAMB36.  Build-time utilisation: **LUTs 14.9%,
> BRAMs 43%** (WNS +0.83 ns at 100 MHz).

### Prerequisites

| Tool | Minimum version | Notes |
|------|----------------|-------|
| Vivado | 2024.1 | Any edition; add to `PATH` or set `VIVADO=` |
| OpenOCD | 0.12.0 | Must include `cpld/xilinx-xc7.cfg` |
| West / Zephyr SDK | current | Same environment as simulation build |
| Python 3 | 3.8+ | For `neorv32_upload.py` (UART bootloader) |

### Pin map

| Signal | Arty A7 pin | Connector / function |
|--------|-------------|----------------------|
| `sys_clk` | E3 | 100 MHz LVCMOS33 oscillator |
| `ck_rst` | C2 | BTN RESET (active-low) |
| `uart_txd_out` | D10 | USB-UART TX (FTDI FT2232HQ) |
| `uart_rxd_in` | A9 | USB-UART RX |
| `led[0..3]` | H5/J5/T9/T10 | On-board green LEDs LD0–LD3 |
| `spi_clk_o` | G13 | Pmod JA pin 1 (SCK) |
| `spi_dat_o` | B11 | Pmod JA pin 2 (MOSI) |
| `spi_dat_i` | A11 | Pmod JA pin 3 (MISO) |
| `spi_csn_o` | D12 | Pmod JA pin 4 (CS0) |
| `twi_sda` | E15 | Pmod JB pin 1 — **needs 4.7 kΩ pull-up to 3V3** |
| `twi_scl` | E16 | Pmod JB pin 2 — **needs 4.7 kΩ pull-up to 3V3** |
| `jtag_tck_i` | K17 | Pmod JC pin 1 |
| `jtag_tdi_i` | M18 | Pmod JC pin 2 |
| `jtag_tdo_o` | N17 | Pmod JC pin 3 |
| `jtag_tms_i` | P18 | Pmod JC pin 4 |

### One-time bitstream build

Synthesise, implement, and generate the bitstream:

```bash
make fpga-synth
# equivalent to: vivado -mode batch -source fpga/arty_a7/build.tcl
# output: build/arty_a7/ostomachion_arty_a7.bit
```

Build time is typically 10–20 minutes on a modern workstation.

### Program the FPGA

Load the bitstream into the FPGA's SRAM via JTAG (volatile — erased on power-cycle):

```bash
make fpga-program
# equivalent to: openocd -f fpga/arty_a7/openocd.cfg \
#                        -c "pld load 0 build/arty_a7/ostomachion_arty_a7.bit" -c shutdown
```

For persistent storage, use Vivado's `write_cfgmem` to generate an SPI flash image and program the on-board Quad-SPI flash.

### Iterating on firmware (no re-synthesis)

After the bitstream is loaded, the NEORV32 BROM bootloader runs at **19200 baud**
and waits for an executable image.  Upload via:

```bash
make fpga-fw          # builds FPGA Zephyr image, then uploads
# or manually:
make zephyr-fpga      # builds to build_zephyr_fpga/
python3 neorv32/sw/bootloader/neorv32_upload.py --port /dev/ttyUSB1 \
    build_zephyr_fpga/zephyr/zephyr.bin
```

Subsequent firmware iterations only require `make fpga-fw` — no Vivado run.

### Baud rate note

| Context | UART baud | Set by |
|---------|-----------|--------|
| Simulation | 115200 | `app.overlay` (`current-speed = <115200>`) |
| NEORV32 bootloader | 19200 | BROM fixed — cannot be changed without modifying the bootloader |
| Application (FPGA) | 115200 | `app_fpga.overlay` (`current-speed = <115200>`) |

Both simulation and the FPGA application run at 115200 baud, giving a uniform
development experience.  The NEORV32 bootloader (BROM) always runs at 19200 baud
before handing off to the application; this is a fixed hardware constraint.

### Interrupt vs. polling drivers

The SPI and I2C drivers support two transfer modes, selected by Kconfig:

| Mode | Kconfig symbol | Default | Used for |
|------|---------------|---------|----------|
| Polling | `CONFIG_SPI_NEORV32_INTERRUPT=n` | `prj.conf` | Simulation — simpler, no IRQ timing dependency |
| Interrupt-driven | `CONFIG_SPI_NEORV32_INTERRUPT=y` | `prj_fpga.conf` | Production FPGA — yields CPU between bytes |

Polling mode spins on `SPI_CTRL_BUSY`/`TWI_CTRL_RX_AVAIL`, blocking the Zephyr
scheduler for the duration of the transfer (~200 cycles/byte at 1 MHz SPI,
~10 000 cycles/byte at 100 kHz I2C on a 100 MHz CPU).

Interrupt-driven mode (enabled by `prj_fpga.conf`) uses:
- **SPI**: `SPI_CTRL_IRQ_RX_AVAIL` (CTRL bit 20, FIRQ 6) — fires once per received byte.
- **I2C**: TWI FIRQ 7 — fires unconditionally whenever `TWI_CTRL_RX_AVAIL` is set (once per RTX command completion).

Both paths are exercised in simulation when `prj_fpga.conf` is applied.

### JTAG debug

After the bitstream is loaded and firmware is running, attach GDB via the NEORV32
on-chip debugger (OCD) on Pmod JC:

```bash
# Terminal 1 — OpenOCD server
openocd -f fpga/arty_a7/openocd.cfg \
        -f neorv32/sw/openocd/openocd_neorv32.cfg

# Terminal 2 — GDB client
riscv32-unknown-elf-gdb build_zephyr_fpga/zephyr/zephyr.elf \
    -ex "target extended-remote localhost:3333" \
    -ex "monitor reset halt"
```

### Hardware test setup

`make test-hw` builds a dedicated test image (verbose ztest output, per-subsystem
logging, 115200 baud) and uploads it via the UART bootloader.  The full test suite
covers SPI, I2C, and GPIO.

#### 1. SPI loopback jumper

Fit a jumper between **Pmod JA pin 2** (MOSI, FPGA net `B11`) and **pin 3** (MISO,
`A11`).  This is the same loopback used for production SPI bringup.

```
Pmod JA header (looking at the board)
 pin 1  pin 2  pin 3  pin 4
  VCC   MOSI   MISO   SCK   ...
          └──── jumper ───┘
```

Without the jumper the SPI loopback tests fail with mismatched RX data.

#### 2. I2C slave (optional)

No external device is needed for the baseline I2C tests — NACK detection and the
bus scan run on bare hardware.  To enable the slave write/read tests, set
`CONFIG_TEST_I2C_SLAVE_ADDR` to the 7-bit address of your device:

```bash
# example: device at 0x48 (e.g. TMP102 temperature sensor)
make test-hw EXTRA_CONF="CONFIG_TEST_I2C_SLAVE_ADDR=72"
```

Or create a one-off fragment and add it to the `OVERLAY_CONFIG` list in the
`test-hw` Makefile target.

#### 3. Run the hardware tests

```bash
# Prerequisites: bitstream programmed (make fpga-program), board reset
make test-hw UART_DEVICE=/dev/ttyUSB1
```

This:
1. Builds `build_zephyr_hw_test/` from `prj.conf + prj_fpga.conf + prj_hw_test.conf`
2. Uploads the binary via the NEORV32 UART bootloader at 19200 baud
3. The application starts and runs all ztest suites at 115200 baud

#### 4. Reading test output

```bash
minicom -D /dev/ttyUSB1 -b 115200 --noinit
# or
screen /dev/ttyUSB1 115200
```

Expected output (all tests passing):

```
Running TESTSUITE ostomachion_spi
===================================================================
START - test_device_ready
 PASS - test_device_ready in 0 ms
START - test_loopback_boundary
 PASS - test_loopback_boundary in 1 ms
...
TESTSUITE ostomachion_spi succeeded

Running TESTSUITE ostomachion_i2c
...
START - test_nack_nonexistent
 PASS - test_nack_nonexistent in 2 ms
START - test_bus_scan
[I2C scan] complete: 0 device(s) found
 PASS - test_bus_scan in 45 ms
...
TESTSUITE ostomachion_i2c succeeded

Running TESTSUITE ostomachion_gpio
...
TESTSUITE ostomachion_gpio succeeded
```

### FFT accelerator test

The FFT accelerator requires the full block-design bitstream (`make fpga-synth` +
`make fpga-program`).  Build and upload the FFT ztest image:

```bash
make test-accel-hw UART_DEVICE=/dev/ttyUSB1
```

Expected output:

```
Running TESTSUITE ostomachion_fft
===================================================================
START - test_dc_response
 PASS - test_dc_response in 1 ms
START - test_single_tone
 PASS - test_single_tone in 1 ms
START - test_roundtrip_latency
[test_fft_accel] FFT latency: N cycles (87 us)
 PASS - test_roundtrip_latency in 1 ms
START - test_invalid_n
 PASS - test_invalid_n in 0 ms
START - test_sequential
 PASS - test_sequential in 2 ms
TESTSUITE ostomachion_fft succeeded

PROJECT EXECUTION SUCCESSFUL
```

For interactive FFT exploration, use the shell image:

```bash
make shell-hw UART_DEVICE=/dev/ttyUSB1
# connect at 115200 baud, then:
uart:~$ fft dc
[FFT] Input: DC (all 0.5 + 0j, 64 points)
[FFT] Done in 87 us.  Bin 0: 16320  max_other: 12  PASS
uart:~$ fft sine 8
[FFT] Input: sine wave at bin 8
[FFT] Done in 89 us.  Peak bin: 8  magnitude: 15960  PASS
```

