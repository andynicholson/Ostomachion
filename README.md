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
  │  (tests/test_spi.cpp, tests/test_i2c.cpp)                        │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  ostomachion::hal::SpiDevice
                           │  ostomachion::hal::I2cBus
                           │  ostomachion::hal::GpioOutput
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  C++20 HAL  (zephyr_app/include/ostomachion/hal/)                │
  │  Zero-overhead wrappers — std::span, [[nodiscard]], noexcept     │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  spi_transceive(), i2c_write_read(), …
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Zephyr BSP Layer                                                │
  │  • Out-of-tree drivers  (drivers/spi/, drivers/i2c/)             │
  │  • Device Tree overlay  (app.overlay)                            │
  │  • DTS bindings         (dts/bindings/)                          │
  │  • Kconfig              (prj.conf)                               │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  MMIO reads/writes via sys_read32/write32
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  FPGA RTL (NEORV32 v1.11.6 + neorv32_wrapper.vhd)               │
  │  RISC-V RV32IMAC soft-core, SPI master, TWI master, GPIO, UART  │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  (physical I/O pins on FPGA target)
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Hardware  /  GHDL Simulation  (sim/neorv32_tb.vhd)              │
  │  SPI loopback, I2C slave model, UART monitor, watchdog           │
  └──────────────────────────────────────────────────────────────────┘
```

---

## Repository layout

```
.
├── Makefile                          # Top-level build orchestration
├── rtl/
│   └── neorv32_wrapper.vhd           # Thin wrapper around neorv32_top
├── sim/
│   ├── neorv32_tb.vhd                # GHDL testbench (clock, reset, bus monitors)
│   └── sim_uart_rx.vhd               # UART character decoder
├── neorv32/                          # NEORV32 RTL submodule (v1.11.6)
├── sw/test_gpio_uart/                # Bare-metal smoke-test firmware (C)
├── zephyr_app/
│   ├── CMakeLists.txt                # Zephyr app build (project: ostomachion)
│   ├── prj.conf                      # Kconfig — peripherals, C++20, ztest
│   ├── app.overlay                   # Device Tree — spi0, i2c0 nodes
│   ├── zephyr/module.yml             # Out-of-tree module descriptor
│   ├── include/
│   │   └── ostomachion/hal/
│   │       ├── gpio.hpp              # GpioOutput
│   │       ├── spi.hpp               # SpiDevice (std::span API)
│   │       └── i2c.hpp               # I2cBus   (std::span API)
│   ├── src/
│   │   └── main.cpp                  # LED heartbeat thread (K_THREAD_DEFINE)
│   ├── tests/
│   │   ├── test_spi.cpp              # ZTEST_SUITE ostomachion_spi (4 tests)
│   │   └── test_i2c.cpp              # ZTEST_SUITE ostomachion_i2c (3 tests)
│   └── drivers/
│       ├── neorv32_regs.h            # Shared poll budget + soc.h re-export
│       ├── spi/spi_neorv32.c         # Polling SPI master driver
│       ├── spi/Kconfig
│       ├── i2c/i2c_neorv32.c         # Polling TWI/I2C master driver
│       ├── i2c/Kconfig
│       ├── Kconfig
│       └── CMakeLists.txt
├── dts/bindings/
│   ├── spi/neorv32,spi.yaml
│   └── i2c/neorv32,twi.yaml
└── bin2vhd.py                        # ELF binary → VHDL IMEM image
```

---

## Peripheral map

| NEORV32 Generic    | Value | MMIO Base    | FIRQ | Zephyr compatible  | DT node |
|--------------------|-------|--------------|------|--------------------|---------|
| `IO_GPIO_NUM`      | 8     | `0xFFFFFFC0` | —    | `neorv32,gpio`     | (board) |
| `IO_UART0_EN`      | true  | `0xFFFFFFE0` | 2    | `neorv32,uart`     | (board) |
| `IO_SPI_EN`        | true  | `0xFFF80000` | 6    | `neorv32,spi`      | `spi0`  |
| `IO_TWI_EN`        | true  | `0xFFF90000` | 7    | `neorv32,twi`      | `i2c0`  |
| `IO_CLINT_EN`      | true  | `0xF0000000` | —    | `neorv32,clint`    | (board) |
| `BOOT_MODE_SELECT` | 2     | —            | —    | Boot from IMEM     | —       |
| `IMEM_SIZE`        | 64 KB | —            | —    | Instruction memory | —       |
| `DMEM_SIZE`        | 64 KB | —            | —    | Data memory        | —       |

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

| Target              | Description                                         |
|---------------------|-----------------------------------------------------|
| `make all`          | Analyze + simulate with default IMEM image          |
| `make test-default` | Clean + simulate with the built-in NEORV32 demo     |
| `make test-baremetal` | Build bare-metal firmware + simulate              |
| `make test-zephyr`  | Build Zephyr app + simulate (needs venv active)     |
| `make zephyr`       | Build Zephyr app only (no simulation)               |
| `make sw`           | Build bare-metal firmware only                      |
| `make clean-ghdl`   | Remove GHDL artifacts (keeps firmware)              |
| `make clean`        | Full clean (GHDL + firmware + Zephyr build)         |

Override `SIM_TIME` to control simulation duration:

```bash
make test-zephyr SIM_TIME=100ms   # faster iteration
make test-zephyr SIM_TIME=300ms   # more LED blink cycles for watchdog
```

---

## Design decisions

**Polling drivers, not interrupt-driven.**
Simulation is the primary target.  Polling keeps the driver logic simple and
avoids the need to verify FIRQ routing in the testbench.  The poll retry
budget (`NEORV32_POLL_RETRIES = 1 000 000`) is shared via
`drivers/neorv32_regs.h` and sized for 100 MHz operation with a 10 ms
worst-case timeout.  Interrupt-driven drivers are the natural next step for
physical FPGA targets.

**19200 baud UART.**
At 100 MHz simulation speed, GHDL evaluates the RTL cycle-by-cycle.  19200
baud requires ~5200 clock cycles per character — fast enough to avoid
truncating test output during a 200 ms simulation, yet low enough that the
baud rate generator rounds cleanly.  Change `CONFIG_UART_BAUDRATE` and
`BAUD` generic together if you need a different rate.

**`BOOT_MODE_SELECT = 2` (boot from IMEM).**
The NEORV32 bootloader negotiates over UART, which adds seconds to every
simulation run.  Setting mode 2 skips the bootloader and jumps directly to
the IMEM image.  In a physical design, set this to 1 (flash) or 0 (OCD) as
appropriate.

**No PLL, no I/O buffer primitives.**
The VHDL is intentionally technology-neutral.  Adding a PLL or `IBUFDS`
primitive would tie the project to a specific FPGA vendor.  Route these
through VHDL generics or separate wrapper layers when targeting a real part.

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
| Interrupt-driven SPI/I2C drivers | Roadmap — requires FIRQ handler wiring in testbench |
| Physical FPGA target (e.g. Arty A7) | Roadmap — needs PLL, constraint file, I/O buffers |
| `GpioInput` HAL class | Roadmap — trivial to add alongside `GpioOutput` |
| DMA support | Not planned — NEORV32 v1.11.6 has no DMA engine |
| 10-bit I2C addressing | Not supported — NEORV32 TWI is 7-bit only |
| `twister` integration | Roadmap — add `testcase.yaml` and board YAML |

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
: The application uses polling mode (`CONFIG_UART_INTERRUPT_DRIVEN=n`).
  Interrupt-driven TX can hang in simulation if the FIRQ routing is not
  fully exercised.

**ztest reports `PROJECT EXECUTION FAILED`**
: Check the `FAIL -` lines in the UART log for the specific assertion that
  fired.  The most common cause is the testbench I2C slave timing out if
  `SIM_TIME` is too short — try `SIM_TIME=300ms`.
