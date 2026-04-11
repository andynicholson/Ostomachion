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

## 🧩 What is Ostomachion?

Ostomachion is Archimedes' dissection puzzle — a grid of fourteen geometric
pieces that fit together in hundreds of distinct ways.  The name captures the
project's design philosophy: a small set of composable interlocking pieces
(NEORV32 RTL, Zephyr RTOS, out-of-tree C drivers, C++20 HAL) that assemble
into a complete, verified FPGA RTOS platform.

The goal is not a finished product but a **professional starting point**.
Every architectural decision is documented, every layer is independently
testable, and every peripheral follows the same pattern — making it
straightforward to add new hardware accelerators and software components
without disturbing what already works.

---

## 🏗️ Architecture

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  Application / ZTEST Suites                                      │
  │  (tests/test_spi.cpp, tests/test_i2c.cpp,                        │
  │   tests/test_gpio.cpp, tests/test_fft_accel.cpp,                 │
  │   tests/test_wdt.cpp)                                            │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  ostomachion::hal::SpiDevice
                           │  ostomachion::hal::I2cBus
                           │  ostomachion::hal::GpioOutput / GpioInput
                           │  ostomachion::FftAccel   (: Accel)
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  C++20 HAL  (zephyr_app/include/ostomachion/)                    │
  │  • hal/gpio.hpp, hal/spi.hpp, hal/i2c.hpp, hal/fft_accel.hpp    │
  │  • accel.hpp — generic Accel / AccelOpDesc base (RTTI-free)      │
  │  • Zero-overhead wrappers — std::span, [[nodiscard]], noexcept   │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  spi_transceive(), i2c_write_read(),
                           │  fft_accel_transform(), …
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Zephyr BSP Layer                                                │
  │  • Out-of-tree drivers  (drivers/spi/, drivers/i2c/,            │
  │                          drivers/accel/)                         │
  │  • Device Tree overlays (app.overlay, app_fpga.overlay,         │
  │                          app_accel.overlay)                      │
  │  • DTS bindings         (dts/bindings/)                          │
  │  • Kconfig              (prj.conf, prj_fpga.conf,               │
  │                          prj_accel.conf, prj_shell.conf)         │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  MMIO reads/writes via sys_read32/write32
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  FPGA RTL  (NEORV32 v1.11.6  +  upstream XBUS→AXI4 bridge)       │
  │  RISC-V RV32IMAC soft-core, SPI master, TWI master, GPIO, UART  │
  │  Bridge: neorv32/rtl/system_integration/xbus2axi4_bridge.vhd    │
  │  Top:    fpga/xem7310/xem7310_top.vhd  (IBUFDS, IOBUF, OCD)    │
  │  FrontPanel UART bridge: fp_uart_bridge.vhd  (Pipe ↔ UART CDC)  │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  AXI4-Lite
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Xilinx IP Subsystem  (fpga/xem7310/ostomachion_bd.tcl)          │
  │  • AXI SmartConnect (axi_smc) + AXI DMA (axi_dma_0)             │
  │  • TX BRAM (0x41000000) ── xfft IP (4096-pt, 16-bit) ── RX BRAM │
  │  • RX BRAM controller (0x41004000)                               │
  │  • AXI INTC (0x40010000): ch0=MM2S, ch1=S2MM, ch2=ovflo → MEI  │
  │  • MMCM clocking (200 MHz LVDS → 100 MHz), proc_sys_reset       │
  └────────────────────────┬─────────────────────────────────────────┘
                           │  (physical I/O pins / GHDL stimulus)
  ┌────────────────────────▼─────────────────────────────────────────┐
  │  Hardware (XEM7310-A200) / GHDL Simulation  (sim/neorv32_tb.vhd) │
  │  SPI loopback, I2C slave model, UART monitor, watchdog           │
  └──────────────────────────────────────────────────────────────────┘
```

---

## 📂 Repository layout

```
.
├── Makefile                          # Top-level build orchestration
├── west.yml                          # West manifest — pins Zephyr SHA + SDK version
├── .github/
│   └── workflows/ci.yml             # GitHub Actions CI (sim, twister, vivado-synth)
├── scripts/
│   ├── bin2vhd.py                   # ELF binary → VHDL IMEM image
│   ├── gen_release_artifacts.sh     # Stage release/<VERSION>/ certification artifacts
│   ├── init_dev_env.sh              # Source to set ZEPHYR_BASE, venv, Vivado PATH
│   └── uart_bridge.py              # FrontPanel UART-over-USB bridge (PTY ↔ Pipes)
├── rtl/
│   └── neorv32_wrapper.vhd           # Simulation wrapper around neorv32_top
├── fpga/
│   └── xem7310/
│       ├── xem7310_top.vhd           # XEM7310-A200 board top (IBUFDS, NEORV32 + bridge + BD + FP)
│       ├── fp_uart_bridge.vhd        # FrontPanel UART bridge (UART TX/RX + async FIFOs + Pipes)
│       ├── xem7310.xdc               # Vivado pin + timing constraints (XC7A200T)
│       ├── build.tcl                 # Non-interactive Vivado batch script (loads FP SDK)
│       │                             #   production: make fpga-synth
│       │                             #   debug ILA:  vivado … -tclargs debug
│       ├── ostomachion_bd.tcl        # IP Integrator block design (AXI DMA, xfft, BRAMs)
│       ├── check_build.tcl           # Post-build quality gates (timing, utilisation, DRC)
│       ├── program_jtag.tcl          # JTAG bitstream programming (fallback, requires MC2 cable)
│       ├── program_flash.tcl         # SPI flash programming (persistent boot)
│       └── openocd.cfg               # NEORV32 OCD debug (external JTAG adapter)
├── sim/
│   ├── neorv32_tb.vhd                # GHDL testbench (clock, reset, bus monitors)
│   └── sim_uart_rx.vhd               # UART character decoder
├── neorv32/                          # NEORV32 RTL submodule (v1.11.6)
├── sw/test_gpio_uart/                # Bare-metal smoke-test firmware (C)
└── zephyr_app/
    ├── CMakeLists.txt                # Zephyr app build (project: ostomachion)
    ├── prj.conf                      # Base Kconfig — ZTEST, SPI, I2C, GPIO, C++20
    ├── prj_fpga.conf                 # Overlay — FPGA target (IRQ drivers, larger stacks)
    ├── prj_accel.conf                # Overlay — FFT accelerator (CONFIG_FFT_ACCEL=y)
    ├── prj_shell.conf                # Overlay — interactive shell image (no ZTEST)
    ├── prj_hw_test.conf              # Overlay — verbose hardware test (logging, no I2C slave)
    ├── app.overlay                   # Device Tree — spi0, i2c0 nodes (sim + FPGA base)
    ├── app_fpga.overlay              # Device Tree overlay — 115200 baud, FPGA clocks
    ├── app_accel.overlay             # Device Tree overlay — fft_accel node + IRQ
    ├── zephyr/module.yml             # Out-of-tree module descriptor
    ├── include/
    │   ├── ostomachion/
    │   │   ├── accel.hpp             # Generic Accel / AccelOpDesc base (RTTI-free)
    │   │   └── hal/
    │   │       ├── gpio.hpp          # GpioOutput + GpioInput
    │   │       ├── spi.hpp           # SpiDevice (std::span API)
    │   │       ├── i2c.hpp           # I2cBus   (std::span API)
    │   │       └── fft_accel.hpp     # FftAccel (: Accel, C++20 RAII wrapper)
    │   └── zephyr/drivers/misc/
    │       └── fft_accel.h           # Public C API: fft_accel_transform(), _get_last_overflow()
    ├── src/
    │   ├── main.cpp                  # LED heartbeat thread (K_THREAD_DEFINE)
    │   ├── fft_shell.c               # "fft" shell commands (CONFIG_FFT_ACCEL + CONFIG_SHELL)
    │   └── test_runner.c             # "test run" shell command (peripheral test suites)
    ├── tests/
    │   ├── testcase.yaml             # West Twister test definitions
    │   ├── test_spi.cpp              # ZTEST_SUITE ostomachion_spi
    │   ├── test_i2c.cpp              # ZTEST_SUITE ostomachion_i2c
    │   ├── test_gpio.cpp             # ZTEST_SUITE ostomachion_gpio
    │   └── test_fft_accel.cpp        # ZTEST_SUITE ostomachion_fft (CONFIG_FFT_ACCEL)
    ├── dts/bindings/
    │   ├── vendor-prefixes.txt       # "ostomachion" vendor prefix
    │   ├── misc/ostomachion,fft-accel.yaml  # AXI DMA + xfft binding (IRQ topology docs)
    │   ├── spi/neorv32,spi.yaml
    │   ├── i2c/neorv32,twi.yaml
    │   └── wdt/neorv32,wdt.yaml
    └── drivers/
        ├── Kconfig                   # CONFIG_OSTOMACHION_HW_BUILD_ID (version manifest)
        ├── CMakeLists.txt
        ├── neorv32_regs.h            # Shared poll budget + soc.h re-export
        ├── spi/spi_neorv32.c         # SPI driver (polling + IRQ paths, Kconfig-gated)
        ├── spi/Kconfig               # CONFIG_SPI_NEORV32 / CONFIG_SPI_NEORV32_INTERRUPT
        ├── i2c/i2c_neorv32.c         # I2C driver (polling + IRQ paths, Kconfig-gated)
        ├── i2c/Kconfig               # CONFIG_I2C_NEORV32 / CONFIG_I2C_NEORV32_INTERRUPT
        ├── accel/fft_accel.c         # FFT accelerator driver (DMA, semaphore, overflow ISR)
        ├── accel/Kconfig             # CONFIG_FFT_ACCEL, CONFIG_FFT_ACCEL_TIMEOUT_MS
        ├── wdt/wdt_neorv32.c         # Watchdog timer driver (NEORV32 WDT)
        ├── wdt/Kconfig               # CONFIG_WDT_NEORV32
        └── wdt/CMakeLists.txt
```

---

## 🗺️ Peripheral map

| NEORV32 Generic    | Simulation | XEM7310-A200 | MMIO Base    | IRQ             | Zephyr driver            | DT node      |
|--------------------|------------|--------------|--------------|-----------------|--------------------------|--------------|
| `IO_GPIO_NUM`      | 8          | 8            | `0xFFFFFFC0` | —               | `neorv32,gpio`           | (board)      |
| `IO_UART0_EN`      | true       | true         | `0xFFFFFFE0` | FIRQ 2          | `neorv32,uart`           | (board)      |
| `IO_SPI_EN`        | true       | true         | `0xFFF80000` | FIRQ 6          | `neorv32,spi`            | `spi0`       |
| `IO_TWI_EN`        | true       | true         | `0xFFF90000` | FIRQ 7          | `neorv32,twi`            | `i2c0`       |
| `IO_CLINT_EN`      | true       | true         | `0xF0000000` | —               | `neorv32,clint`          | (board)      |
| `IO_SPI_FIFO`      | 4          | 32           | —            | —               | FIFO depth               | —            |
| `IO_TWI_FIFO`      | 4          | 32           | —            | —               | FIFO depth               | —            |
| `IO_UART0_TX_FIFO` | 1          | 32           | —            | —               | TX FIFO depth            | —            |
| `BOOT_MODE_SELECT` | 2 (IMEM)   | 0 (bootloader)| —           | —               | Boot mode                | —            |
| `OCD_EN`           | false      | true         | —            | —               | On-chip debugger         | —            |
| `IO_WDT_EN`        | false      | true         | —            | —               | Watchdog timer           | —            |
| `IMEM_SIZE`        | 64 KB      | 128 KB       | —            | —               | Instruction memory       | —            |
| `DMEM_SIZE`        | 64 KB      | 64 KB        | —            | —               | Data memory              | —            |
| AXI DMA ctrl       | —          | FPGA only    | `0x40000000` | MEI (IRQ 11)\*  | `ostomachion,fft-accel`  | `fft_accel`  |
| TX BRAM            | —          | FPGA only    | `0x41000000` | —               | (part of fft_accel)      | `fft_accel`  |
| RX BRAM ctrl       | —          | FPGA only    | `0x41004000` | —               | (part of fft_accel)      | `fft_accel`  |

\* **Interrupt topology**: three sources are aggregated into the single NEORV32 MEI line via
the AXI INTC (0x40010000): channel 0 = AXI DMA MM2S complete, channel 1 = AXI DMA S2MM
complete, channel 2 = xfft overflow.  The driver ISR reads the INTC ISR register to
identify pending sources and acknowledges via INTC IAR.
See [Interrupt architecture](#interrupt-architecture) for the multi-accelerator scalability plan.

---

## 🔌 HAL API overview

All HAL classes live in `namespace ostomachion` and are header-only.  They are
zero-overhead wrappers: the compiler sees through them as easily as the
underlying C calls.

### `GpioOutput` / `GpioInput`  (`include/ostomachion/hal/gpio.hpp`)

```cpp
ostomachion::hal::GpioOutput led{GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios)};
led.set(true);   // drive high
led.toggle();    // toggle

ostomachion::hal::GpioInput btn{GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios)};
bool level  = btn.get();        // raw logical pin level
bool active = btn.is_active();  // true when pin is in its DTS-defined active state
```

Both classes panic at construction if `gpio_pin_configure_dt` fails — a
misconfigured pin is an unrecoverable hardware error.  `GpioInput` is
non-copyable to prevent aliasing of the underlying `gpio_dt_spec`.

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

`FftAccel` inherits from the generic `ostomachion::Accel` base class (see
[Accelerator abstraction](#accelerator-abstraction)) and exposes two usage
patterns:

**Typed interface (direct):**

```cpp
#include <ostomachion/hal/fft_accel.hpp>

const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
ostomachion::FftAccel accel{dev};

if (!accel.ready()) { /* handle missing / unloaded bitstream */ }

static fft_sample_t in[4096]{};
static fft_sample_t out[4096]{};
// Fill in[] with Q1.15 complex samples (re = int16_t, im = int16_t)
in[0].re = 16384; // 0.5 in Q1.15

[[nodiscard]] int err = accel.transform(in, out, 4096);
// out[] now contains the 4096-point forward FFT result
// Frequency bin k occupies out[k].re + j·out[k].im (Q1.15, scaled)

if (accel.last_overflow()) {
    // Reduce input amplitude — the xfft IP detected Q1.15 overflow
}
```

**Generic platform interface (via `Accel::submit`):**

```cpp
ostomachion::FftOpDesc op{in, out, 4096};
int err = accel.submit(op);  // type-safe, no RTTI
```

**Error codes returned by `transform()` / `submit()`:**

| Return | Meaning |
|--------|---------|
| `0` | Success |
| `-ENODEV` | Device not ready (bitstream not loaded or DTS mismatch) |
| `-EINVAL` | Invalid parameters (e.g. `n != 4096`) |
| `-ETIMEDOUT` | DMA did not complete within `CONFIG_FFT_ACCEL_TIMEOUT_MS` |
| `-EIO` | Hardware error (DMA bus fault, unexpected state) |

**Driver Kconfig options:**

| Symbol | Default | Range | Description |
|--------|---------|-------|-------------|
| `CONFIG_FFT_ACCEL` | n | — | Enable the FFT accelerator driver |
| `CONFIG_FFT_ACCEL_TIMEOUT_MS` | 100 | 10–10000 | DMA completion timeout (ms) |

`FftAccel` is non-copyable and non-movable by design; the underlying
driver serialises concurrent callers via a mutex.

---

## ⚡ Accelerator abstraction

`include/ostomachion/accel.hpp` defines the generic platform interface that
every hardware accelerator exposes:

```cpp
namespace ostomachion {

struct AccelOpDesc {
    enum class Type : unsigned { Unknown = 0, Fft = 1, /* … */ };
    const Type type_id;
protected:
    explicit AccelOpDesc(Type t = Type::Unknown) : type_id{t} {}
};

class Accel {
public:
    [[nodiscard]] virtual bool ready()                          const noexcept = 0;
    [[nodiscard]] virtual int  submit(const AccelOpDesc &op)         noexcept = 0;
    [[nodiscard]] virtual bool last_overflow()                  const noexcept { return false; }
};
```

**Design rationale:**
- `AccelOpDesc::type_id` enables safe downcasting with `static_cast` in
  concrete `submit()` implementations — no `dynamic_cast` or RTTI needed.
  Zephyr builds use `-fno-rtti`, so RTTI is unavailable.
- `Accel` is non-copyable and non-movable to prevent aliasing; always stored
  by reference or as a static/stack object.
- `last_overflow()` has a default `return false` implementation; accelerators
  without overflow detection need not override it.

Adding a new accelerator type (e.g. matrix multiply):
1. Add `MatMul = 2` to `AccelOpDesc::Type`.
2. Create `MatMulOpDesc : AccelOpDesc` with the operation parameters.
3. Create `MatMulAccel : Accel` that implements `submit()`.
4. Write the Zephyr C driver and DTS binding following the `fft_accel` pattern.

---

## 🧠 Memory model

**There is no heap.**  `CONFIG_HEAP_MEM_POOL_SIZE = 0`.  Any call to `malloc()`
or `operator new` returns `NULL` / fails immediately.  This is intentional.

All memory is **statically allocated at compile time**:

| What | Mechanism |
|------|-----------|
| FFT sample buffers | `static fft_sample_t g_fft_in[4096]` (BSS/data section) |
| Driver state structs | Zephyr `DEVICE_DEFINE` macro (linker section) |
| Thread stacks | `CONFIG_MAIN_STACK_SIZE`, `CONFIG_SHELL_STACK_SIZE` (link time) |
| Semaphores, mutexes | `K_SEM_DEFINE`, `K_MUTEX_DEFINE` (static kernel objects) |
| ZTEST structures | Static allocation by test framework macros |
| `FftAccel` objects | Stack or file-scope static at call site |

**Why this matters for production:**
- **Deterministic**: no fragmentation, no allocation failure at runtime.
- **Auditable**: `riscv64-zephyr-elf-nm --size-sort zephyr.elf` shows every
  allocation at link time.
- **Standards-compliant**: dynamic allocation is banned by MISRA C++ and
  IEC 61508 for safety-critical firmware.
- The shell build (ROM: 88%, RAM: 26%) leaves no room for a heap anyway.

---

## 🛠️ C++20 in an embedded context

The Zephyr build compiles with `-nostdinc++` — the compiler does **not** search
GCC's standard C++ headers (`libstdc++`, `libc++`).  Zephyr instead provides a
minimal C++ layer (`lib/cpp/minimal/include/`) containing only:

| Header | Provides |
|--------|----------|
| `<cstddef>` | `size_t`, `nullptr_t`, `offsetof` |
| `<cstdint>` | `uint32_t`, `int16_t`, … |
| `<new>` | placement `new` / `delete` |

This is **not** a restriction on the C++20 language — only on the hosted
standard library.  Every language feature used in this project is available:

| Feature | Available | Notes |
|---------|-----------|-------|
| `constexpr`, `consteval` | ✅ | Compiler intrinsic |
| `[[nodiscard]]`, `[[likely]]` | ✅ | Compiler intrinsic |
| Concepts, `requires` | ✅ | Compiler intrinsic |
| `virtual`, vtables | ✅ | RTTI not needed for vtables |
| Lambdas, structured bindings | ✅ | Compiler intrinsic |
| `std::span`, `std::array` | ✅ | Available via Zephyr |
| `std::string`, `std::vector` | ❌ | Heap-dependent — not appropriate |
| `<stdexcept>`, `<iostream>` | ❌ | Hosted environment only |
| `dynamic_cast`, `typeid` | ❌ | `-fno-rtti` — use type-tag enum instead |
| Exceptions | ❌ | `-fno-exceptions` — use return codes |

The code deliberately uses `static_cast` with a `Type` enum discriminator
(in `AccelOpDesc`) in place of `dynamic_cast`, making it safe for Zephyr's
`-fno-rtti` ABI.  C errno codes (`ENODEV`, `ETIMEDOUT`, …) arrive through the
Zephyr include chain via `<zephyr/device.h>` rather than `<cerrno>`.

---

## 🔄 Continuous integration

`.github/workflows/ci.yml` defines five jobs, all triggered on pull requests
and pushes to `main` / `develop`:

| Job | Runner | What it does |
|-----|--------|-------------|
| `sim` | `ubuntu-latest` | Builds Zephyr (sim config), runs `make test-zephyr`, asserts `PROJECT EXECUTION SUCCESSFUL` |
| `twister` | `ubuntu-latest` | Runs `west twister -T zephyr_app/tests` (all configs, `neorv32` sim board) — needs `sim` to pass |
| `vivado-synth` | `self-hosted [vivado]` | Runs `make fpga-synth && make fpga-check`, uploads `.bit`, `.rpt`, `build_id.txt` — skipped on forks |
| `vhdl-lint` | `ubuntu-latest` | GHDL analysis of RTL (NEORV32 core + upstream bridge + FPGA top) — catches VHDL-2008 type errors in ~30 s |
| `firmware-analysis` | `ubuntu-latest` | clang-tidy on app sources, `nm --size-sort` memory map, thread analyzer — needs `twister` to pass |

In-progress runs are cancelled when a new commit arrives on the same branch.

The `west.yml` manifest pins the exact Zephyr Git SHA
(`d465eac074fa` — v4.3.0-dev) and Zephyr SDK 1.0.0, ensuring reproducible
builds across all developer machines and CI agents.

---

## 🧪 Testing

### 🏃 Running the Zephyr ZTEST suite (simulation)

```bash
source ~/.zephyr-venv/bin/activate
export ZEPHYR_BASE=~/src/zephyrproject/zephyr
make test-zephyr
```

The Zephyr application embeds the
[ztest](https://docs.zephyrproject.org/latest/develop/test/ztest.html)
framework.  Test suites register automatically; the framework discovers and
runs them before the LED thread takes over.  The CI-parseable output (via
UART0) looks like:

```
Running TESTSUITE ostomachion_spi
===================================================================
START - test_loopback_zero
 PASS - test_loopback_zero in 0.XXX seconds
...
TESTSUITE ostomachion_spi succeeded

Running TESTSUITE ostomachion_i2c
===================================================================
...
TESTSUITE ostomachion_i2c succeeded

PROJECT EXECUTION SUCCESSFUL
```

The `PROJECT EXECUTION SUCCESSFUL` / `FAILED` line is what CI tools
(including Zephyr's `twister` runner) parse to determine pass/fail.

### 🔍 How the GHDL testbench validates each suite

**SPI** (`sim/neorv32_tb.vhd`): MOSI is wired directly to MISO.  Every
transmitted byte is echoed back unchanged.  The SPI bus monitor logs each
byte and reports partial transfers as warnings.

**I2C** (`sim/neorv32_tb.vhd`): A synthesized I2C slave state machine
responds at 7-bit address **0x50**.  It ACKs every write byte (logging
each to the console) and returns `0x5A` per read byte.  The open-drain bus
is modelled with resolved `std_logic` (`'0'` wins; released lines are `'1'`).

**Watchdog**: A separate testbench process asserts a fatal failure if the
GPIO toggle count is below a threshold at 390 ms of simulated time.  This
catches hangs where the system boots but never reaches the LED blink loop.

### 💨 Bare-metal smoke test

```bash
make test-baremetal
```

Builds a minimal C firmware that toggles GPIO pin 0 and prints a banner
over UART0 in sim-mode (characters go directly to the GHDL console,
bypassing the baud-rate generator).

### 🌀 West Twister

`zephyr_app/tests/testcase.yaml` defines the full test matrix for
`west twister`:

```bash
west twister -T zephyr_app/tests --integration -v
```

Five CI configurations and two hardware-in-the-loop (HIL) entries are defined:

| Test ID | Config | Board | Type |
|---------|--------|-------|------|
| `ostomachion.peripherals.baseline` | `prj.conf` | neorv32 sim | build + run |
| `ostomachion.fft.compile` | `prj.conf` + FFT extras | neorv32 sim | build only |
| `ostomachion.shell.compile` | `prj.conf` + shell/FFT extras | neorv32 sim | build only |
| `ostomachion.wdt.compile` | `prj.conf` + WDT extras | neorv32 sim | build + run |
| `ostomachion.hw.peripherals` | `prj.conf` + FPGA + hw_test | xem7310 | HIL (fixture: `xem7310_hw`) |
| `ostomachion.hw.fft` | `prj.conf` + FPGA + accel + hw_test | xem7310 | HIL (fixture: `xem7310_hw_fft`) |

HIL tests require a self-hosted runner with the `xem7310` label and a programmed
bitstream.  They are excluded from `ubuntu-latest` runs via `platform_allow`.

---

## 🚀 Getting started

### 📦 System packages

```bash
sudo apt install ghdl ghdl-llvm gtkwave gcc-riscv64-unknown-elf \
                 ninja-build device-tree-compiler cmake python3-venv
```

### ⚙️ Zephyr SDK

```bash
cd ~
wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.0/zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
tar xf zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
cd zephyr-sdk-1.0.0 && ./setup.sh
```

### 🌐 Zephyr workspace (recommended — uses `west.yml` manifest)

```bash
python3 -m venv ~/.zephyr-venv
source ~/.zephyr-venv/bin/activate
pip install west
west init -m <this-repo-url> --mr main ~/ostomachion_ws
cd ~/ostomachion_ws && west update
pip install -r zephyr/scripts/requirements-base.txt
```

This clones Zephyr at the pinned SHA (`d465eac074fa`) and the four required
modules (cmsis, hal_riscv, picolibc, tinycrypt), matching the environment
used for CI and hardware validation.

### 💻 One-shot shell setup (local Zephyr tree + venv)

If you already keep Zephyr under `~/src/zephyrproject/zephyr` and use
`~/.zephyr-venv` (as in the simulation example above), source the helper
script from the Ostomachion repo root:

```bash
cd /path/to/ostomachion
source scripts/init_dev_env.sh
make zephyr-fpga
```

Defaults: `OSTOMACHION_ZEPHYR_VENV=~/.zephyr-venv`,
`OSTOMACHION_ZEPHYR_WORKSPACE=~/src/zephyrproject`,
`ZEPHYR_SDK_INSTALL_DIR=~/zephyr-sdk-1.0.0`,
and (if present) `source /tools/Xilinx/2025.1/Vivado/settings64.sh` via
`OSTOMACHION_VIVADO_SETTINGS` so `vivado` is on `PATH` for `make fpga-synth`.
Override any of these in the environment before sourcing if your layout differs.

---

## 🔧 Extending the platform

### 🔩 Adding a new NEORV32 peripheral (SPI, I2C, TRNG, PWM, …)

1. **Enable in RTL** — set the corresponding `IO_*_EN` generic in
   `rtl/neorv32_wrapper.vhd`.  Expose the I/O ports and connect them.

2. **Add a DTS binding** — create
   `zephyr_app/dts/bindings/<bus>/neorv32,<peripheral>.yaml` following the
   pattern in `neorv32,spi.yaml`.  Declare `reg`, `interrupts` (optional),
   and `syscon`.

3. **Write a Zephyr driver** — create `drivers/<bus>/<peripheral>_neorv32.c`.
   Follow the `spi_neorv32.c` / `i2c_neorv32.c` pattern:
   - Include `../neorv32_regs.h` for `NEORV32_POLL_RETRIES`.
   - Use `dev->config` inside `reg_read`/`reg_write` helpers.
   - Add Kconfig and CMakeLists entries.

4. **Add a HAL class** — create
   `zephyr_app/include/ostomachion/hal/<peripheral>.hpp` in
   `namespace ostomachion::hal`.  Use `std::span<std::byte>` for buffers,
   `[[nodiscard]]` on error-returning methods, and `noexcept` throughout.

5. **Write a ZTEST suite** — create `zephyr_app/tests/test_<peripheral>.cpp`,
   register it with `ZTEST_SUITE(ostomachion_<peripheral>, ...)`, add it
   to `CMakeLists.txt` inside `if(CONFIG_ZTEST)`, and add a Twister entry
   to `testcase.yaml`.

### ➕ Adding a new hardware accelerator

1. **RTL / IP** — add the IP to `ostomachion_bd.tcl`.  Connect AXI4-Lite
   control, AXI4-Stream data, and IRQ lines.  Update `xem7310_top.vhd` if
   the `mext_irq` bus needs widening.

2. **IRQ wiring** — see [Interrupt architecture](#interrupt-architecture)
   for the current AXI INTC setup and how to add further interrupt channels
   for additional accelerators.

3. **DTS binding + overlay** — follow `ostomachion,fft-accel.yaml` and
   `app_accel.overlay`.

4. **C driver** — follow `fft_accel.c`.  Use `k_sem_reset` before each
   DMA transfer, guard with `device_is_ready`, add
   `CONFIG_<ACCEL>_TIMEOUT_MS` to Kconfig.

5. **C++ HAL** — add `Type::<NewAccel>` to `AccelOpDesc::Type`, create a
   `NewAccelOpDesc : AccelOpDesc`, and `NewAccel : Accel` with a
   `static_cast` dispatch in `submit()`.

---

## 🎯 Makefile targets

| Target                | Description                                                       |
|-----------------------|-------------------------------------------------------------------|
| `make all`            | Analyze + simulate with default IMEM image                        |
| `make test-default`   | Clean + simulate with the built-in NEORV32 demo                   |
| `make test-baremetal` | Build bare-metal firmware + simulate                              |
| `make test-zephyr`    | Build Zephyr app (sim config) + simulate                          |
| `make zephyr`         | Build Zephyr app only (simulation target)                         |
| `make zephyr-fpga`    | Build Zephyr firmware for FPGA (115200 baud, IRQ drivers)         |
| `make sw`             | Build bare-metal firmware only                                    |
| `make clean-ghdl`     | Remove GHDL artifacts (keeps firmware)                            |
| `make clean`          | Full clean (GHDL + firmware + all Zephyr build dirs)              |
| `make fpga-synth`         | Vivado: synthesise + implement + bitstream + MCS flash image      |
| `make fpga-program`       | Load bitstream onto XEM7310-A200 via FrontPanel USB — volatile    |
| `make fpga-flash`         | Program on-board SPI flash via FrontPanel — persistent            |
| `make uart-bridge`        | Start FrontPanel UART-over-USB bridge (PTY for minicom/upload)    |
| `make fpga-fw`            | Build + upload FPGA Zephyr firmware via UART bootloader           |
| `make fpga-check`         | Post-build quality gates (timing, utilisation, DRC)               |
| `make fpga-release VERSION=v1.0.0` | Stage certification artifacts in `release/v1.0.0/`     |
| `make test-hw`            | Build + upload SPI/I2C/GPIO/WDT ZTEST firmware                    |
| `make test-accel-hw`      | Build + upload FFT accelerator ZTEST firmware                     |
| `make shell-hw`           | Build + upload interactive shell firmware (`fft`, `test` commands)|

Override `SIM_TIME` to control simulation duration:

```bash
make test-zephyr SIM_TIME=100ms   # faster iteration
make test-zephyr SIM_TIME=300ms   # more LED blink cycles for watchdog
```

For a **debug ILA bitstream** (Integrated Logic Analyser probes on
AXI-Stream DMA↔xfft and interrupt nets), invoke Vivado directly:

```bash
mkdir -p build/xem7310
vivado -mode batch -source fpga/xem7310/build.tcl -tclargs debug \
    | tee build/xem7310/build_debug.log
# outputs: build/xem7310/ostomachion_xem7310_debug.bit
#          build/xem7310/debug_probes.ltx
```

Load the `.bit` via JTAG and open the `.ltx` in Vivado Hardware Manager.

---

## 📐 Design decisions

**Two build targets, one codebase.**
The project is designed for deployment on real FPGA hardware (XEM7310-A200) with
GHDL simulation as a fast development and regression tool.  The same Zephyr
firmware, out-of-tree drivers, and C++20 HAL compile for both targets.
Target-specific differences are isolated to a VHDL top-level file, a DTS
overlay, and a Kconfig fragment — nothing in the shared application layer
knows which environment it is running in.

**Interrupt-driven drivers on hardware, polling available for simulation.**
The production driver path (`CONFIG_SPI_NEORV32_INTERRUPT=y`,
`CONFIG_I2C_NEORV32_INTERRUPT=y`, enabled by `prj_fpga.conf`) uses FIRQ 6
and 7 to yield the Zephyr thread between bytes.  The polling fallback
(default in `prj.conf`) is retained for simulation convenience — it avoids
FIRQ timing dependencies in the testbench.  Both paths are compiled from
the same source files, gated by `#ifdef`.

**115200 baud for both simulation and FPGA application.**
Both `app.overlay` (simulation base) and `app_fpga.overlay` (FPGA target)
configure UART0 at 115200 baud; the testbench `sim_uart_rx` monitors at the
same rate.  The bare-metal smoke test (`sw/test_gpio_uart/`) uses UART
sim-mode (`UART0_SIM_MODE`), which bypasses the baud-rate generator entirely
and writes characters directly to the GHDL console.  The NEORV32 BROM
bootloader always runs at 19200 baud and cannot be changed without
recompiling the bootloader image.

**`BOOT_MODE_SELECT = 2` for simulation, `0` for FPGA.**
Mode 2 (boot from pre-initialised IMEM) skips the UART bootloader entirely,
avoiding a multi-second UART negotiation on every GHDL run.  On the XEM7310-A200,
mode 0 (internal BROM bootloader) allows firmware to be uploaded over UART
without re-synthesising — only `make fpga-fw` is needed for each firmware
iteration after the initial `make fpga-synth` + `make fpga-program`.

**IOBUF and IBUFDS in the FPGA top, not the simulation wrapper.**
`fpga/xem7310/xem7310_top.vhd` instantiates Xilinx `IBUFDS` (200 MHz LVDS
clock) and `IOBUF` (open-drain I2C) primitives directly; the MMCM in the
block design converts 200 MHz to the 100 MHz system clock.
`rtl/neorv32_wrapper.vhd` remains technology-neutral for simulation.

**`std::span` + `std::byte` in the HAL.**
`std::byte` (C++17) is the standard type for uninterpreted binary data.
`std::span` (C++20) provides a zero-overhead, bounds-safe view of contiguous
buffers, replacing `void * + size_t` pairs without any runtime cost.

**ZTEST sources guarded by `if(CONFIG_ZTEST)` in CMakeLists.**
The shell firmware (`prj_shell.conf`) disables ZTEST and uses the UART
for the interactive shell.  ZTEST headers (`<zephyr/ztest.h>`) are
unavailable when `CONFIG_ZTEST` is off, so test source files are only
added to the build target when `CONFIG_ZTEST=y`.

**No dynamic memory allocation.**
`CONFIG_HEAP_MEM_POOL_SIZE = 0`.  See [Memory model](#memory-model) for
a full discussion.  The C++ HAL uses `virtual` dispatch (vtable) but never
`dynamic_cast` or `typeid`, keeping the `-fno-rtti` build clean.

**XBUS bus-access timeout.**
NEORV32's built-in `XBUS_TIMEOUT` generic (default 255 cycles) auto-terminates
pending bus accesses that receive no ACK, raising a bus fault exception.  This
prevents indefinite CPU hangs from misconfigured AXI peripherals.  The upstream
`xbus2axi4_bridge` relies on this mechanism rather than a bridge-side watchdog.

### ⚡ Interrupt architecture

The current design uses a **single NEORV32 Machine External Interrupt (MEI)**
line for all AXI fabric interrupts, aggregated via the AXI INTC (at 0x40010000):

```
INTC channel 0 — AXI DMA MM2S complete / error
INTC channel 1 — AXI DMA S2MM complete / error
INTC channel 2 — xfft overflow (m_axis_status_tvalid)
         OR ────────────────────────────────────────→  NEORV32 mext_irq_i
```

The driver ISR reads the AXI INTC Interrupt Status Register (ISR) to
identify which channel(s) fired, handles each pending source, and
acknowledges via the INTC Interrupt Acknowledge Register (IAR).

**Scalability for multi-accelerator platforms**: add further accelerators
by wiring their IRQs to additional AXI INTC channels.  The NEORV32 MEI
line remains a single "any pending" signal from the INTC; the driver
reads the INTC ISR to disambiguate sources without heuristics.  This
change is isolated to `ostomachion_bd.tcl` (adding channels to the
`irq_concat_intc` and INTC) and the Zephyr driver ISR.

---

## 🗺️ Known limitations and roadmap

| Item | Status |
|------|--------|
| FFT driver thread safety | **Design constraint** — callers serialised by mutex; single `FftAccel` instance per system recommended |
| FFT GHDL simulation | **Not supported** — Xilinx encrypted IP is not simulatable in GHDL |
| 10-bit I2C addressing | **Not supported** — NEORV32 TWI is 7-bit only |
| Additional FPGA board targets | **Roadmap** — parameterised `fpga/` layout supports additional boards |

---

## 🔒 NEORV32 version lock

This project uses **NEORV32 v1.11.6**, pinned by submodule hash.  Before
upgrading to any newer version, read the detailed compatibility analysis:
[`docs/neorv32_upgrade_notes.md`](docs/neorv32_upgrade_notes.md).

Key upgrade concerns:
- Verify `uart_neorv32.c` register bit positions against new `neorv32_uart.h`
- Check for any `neorv32_top` generic renames (run `vhdl-lint` CI first)
- Allow for a full re-synthesis and re-acceptance test (est. ~2 engineer-days)

**Recommendation:** do not upgrade for the v1.0.0 client delivery.  Plan as a
separate tracked work item post-acceptance.

---

## 📊 Debugging with waveforms

Every simulation produces `output.ghw` in GHDL's native format:

```bash
make test-zephyr WAVE=1   # adds --wave=output.ghw to the ghdl -r invocation
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

The UART monitor also writes decoded characters to `UART0.log`:

```bash
cat UART0.log
```

---

## 🩺 Troubleshooting

**`image_gen` not found during `make test-zephyr`**
: Ensure the venv is activated and `ZEPHYR_BASE` is set before running.

**Simulation takes very long**
: GHDL interprets the RTL cycle-by-cycle.  200 ms at 100 MHz = 20 million
  clock cycles.  Reduce `SIM_TIME` for faster iteration; all SPI and I2C
  tests complete within the first ~120 ms of simulated time.

**No UART output in simulation**
: The bare-metal test uses UART sim-mode (characters go directly to stdout).
  The Zephyr test uses real 115200-baud serial — look for lines prefixed with
  `UART0:` in the GHDL console output.  Confirm the testbench `BAUD` generic
  (115200) matches the firmware's configured baud rate.

**`CONFIG_UART_INTERRUPT_DRIVEN` causes hangs**
: The application uses polling UART mode (`CONFIG_UART_INTERRUPT_DRIVEN=n`).
  The SPI and I2C drivers have their own independent interrupt paths gated by
  `CONFIG_SPI_NEORV32_INTERRUPT` and `CONFIG_I2C_NEORV32_INTERRUPT`.

**ztest reports `PROJECT EXECUTION FAILED`**
: Check the `FAIL -` lines in the UART log for the specific assertion that
  fired.  The most common cause is the testbench I2C slave timing out if
  `SIM_TIME` is too short — try `SIM_TIME=300ms`.

**`fft_accel_transform()` returns `-ETIMEDOUT`**
: The DMA did not complete within `CONFIG_FFT_ACCEL_TIMEOUT_MS` (default
  100 ms).  Verify the bitstream is loaded and the AXI DMA / xfft IP are
  clocked correctly.  Increase the timeout via Kconfig if the system is
  under heavy load.  Persistent timeouts indicate a hardware fault.

**`fft_accel.last_overflow()` returns `true`**
: The xfft IP detected Q1.15 numerical overflow.  Reduce input amplitude
  (multiply samples by a factor < 1.0 before passing to `transform()`).
  The FFT result is still returned but may be clipped/incorrect for
  the overflowed frequency bins.

---

## 🎛️ Deploying to XEM7310-A200

The FPGA build targets the Opal Kelly **XEM7310-A200** (XC7A200T, FBG484 package).
All required files live in `fpga/xem7310/`.

> **Board note:** The XEM7310-A200 is a USB 3.0 FPGA integration module with
> 134,600 LUTs and 730 Block RAM tiles — significantly larger than the Artix-7
> A100T.  The design's BRAM utilisation is well within the available resources.
> FPGA configuration and communication uses the **Opal Kelly FrontPanel SDK**
> over USB-C (the on-board USB interface is *not* compatible with Vivado JTAG).
> A **FrontPanel UART bridge** (`fp_uart_bridge.vhd`) routes the NEORV32 UART
> through FrontPanel Pipe endpoints so that the bootloader and firmware console
> are accessible over USB-C without needing the MC1 expansion header.  Run
> `make uart-bridge` to create a virtual serial port (PTY) that minicom and
> the bootloader upload script can connect to.
> Eight on-board LEDs (D1–D8, Bank 14, LVCMOS15) are directly wired to the
> FPGA for visual bring-up.  Expansion I/O (UART, SPI, I2C, NEORV32 OCD JTAG)
> is routed through MC1/MC2 connectors and requires a carrier board or
> breakout for access.

### ✅ Prerequisites

| Tool | Minimum version | Notes |
|------|----------------|-------|
| Vivado | 2024.1 | Any edition; tested on 2025.1; add to `PATH` or set `VIVADO=` |
| Opal Kelly FrontPanel SDK | — | Free download from [opalkelly.com](https://www.opalkelly.com); set `FRONTPANEL_DIR` env var to SDK root |
| West / Zephyr SDK | 1.0.0 | Same environment as simulation build |
| Python 3 | 3.8+ | For west, Zephyr build scripts, FrontPanel `ok` module, UART bridge |
| External USB-UART adapter | — | *(optional)* FTDI TTL-232R-3V3 on MC1 — not needed with UART bridge |

### 📌 Pin map

| Signal | FPGA pin | Location / function |
|--------|----------|---------------------|
| `sys_clk_p` | W11 | 200 MHz LVDS oscillator (+), on-board, Bank 13 |
| `sys_clk_n` | W12 | 200 MHz LVDS oscillator (−), on-board, Bank 13 |
| `led[0]`–`led[7]` | A13–B17 | **On-board LEDs D1–D8** (Bank 14, LVCMOS15, active-low HW, inverted in RTL) |
| `ext_rstn` | AB7 | MC1-37 — active-low external reset |
| `uart_txd_out` | W9 | MC1-15 — UART TX (external USB-UART adapter) |
| `uart_rxd_in` | Y9 | MC1-17 — UART RX |
| `spi_clk_o` | T5 | MC1-27 — SPI SCK |
| `spi_dat_o` | W6 | MC1-28 — SPI MOSI |
| `spi_dat_i` | U5 | MC1-29 — SPI MISO |
| `spi_csn_o` | W5 | MC1-30 — SPI CS0 |
| `twi_sda` | AA5 | MC1-31 — I2C SDA — **needs 4.7 kΩ pull-up to 3V3** |
| `twi_scl` | AB5 | MC1-33 — I2C SCL — **needs 4.7 kΩ pull-up to 3V3** |
| `jtag_tck_i` | P5 | MC2-15 — NEORV32 OCD TCK |
| `jtag_tdi_i` | P4 | MC2-17 — NEORV32 OCD TDI |
| `jtag_tdo_o` | N4 | MC2-19 — NEORV32 OCD TDO |
| `jtag_tms_i` | P6 | MC2-16 — NEORV32 OCD TMS |

### 🔨 One-time bitstream build

Synthesise, implement, and generate the bitstream:

```bash
make fpga-synth
# equivalent to: vivado -mode batch -source fpga/xem7310/build.tcl
# output: build/xem7310/ostomachion_xem7310.bit   (FPGA bitstream)
#         build/xem7310/ostomachion_xem7310.mcs   (SPI flash image)
#         build/xem7310/build_id.txt              (semver + git hash + timestamp)
```

Build time is typically 10–20 minutes on a modern workstation.

The build embeds `git describe --tags` and the git hash as the bitstream
`USERID` property and in `build_id.txt`.  The firmware can log this at boot
via `CONFIG_OSTOMACHION_HW_BUILD_ID` for hardware/firmware version verification.

### ⚡ Program the FPGA (volatile — FrontPanel USB)

Load the bitstream into the FPGA's SRAM via the Opal Kelly FrontPanel SDK
over USB-C (erased on power-cycle).  Requires the FrontPanel SDK installed
and the `ok` Python module importable:

```bash
make fpga-program
# uses FrontPanel Python API: ok.FrontPanel().ConfigureFPGA(...)
# board must be connected via USB-C
```

On success the 8 on-board LEDs (D1–D8) should show the NEORV32 GPIO state
immediately — LED D1 blinks at ~1 Hz once the firmware's `led_blink_thread`
starts.

### 💾 Program the SPI flash (persistent — survives power-cycle)

Program the on-board SPI configuration flash so the FPGA auto-configures
itself from flash on every power-up:

```bash
make fpga-flash
# uses FrontPanel FlashLoader utility; board must be connected via USB-C
```

After `make fpga-flash`, the board will boot the Ostomachion design automatically
whenever powered on — no USB connection required.

### 🔁 Iterating on firmware (no re-synthesis)

After the bitstream is loaded, the NEORV32 BROM bootloader runs at **19200 baud**
and waits for an executable image.

**With FrontPanel UART bridge (USB-C only, no MC1 needed):**

```bash
# Terminal 1 — start the bridge at 19200 baud (bootloader speed)
make uart-bridge
# note the PTY path printed, e.g. /dev/pts/3

# Terminal 2 — upload firmware through the bridge
make fpga-fw UART_DEVICE=/dev/pts/3

# After upload, restart the bridge at application speed to see output:
# Terminal 1: Ctrl-C, then:
make uart-bridge BRIDGE_BAUD=115200

# Terminal 2 — connect minicom to the bridge PTY
minicom -D /dev/pts/3 -b 115200
```

**With external USB-UART adapter on MC1:**

```bash
make fpga-fw UART_DEVICE=/dev/ttyUSB1
minicom -D /dev/ttyUSB1 -b 115200
```

Subsequent firmware iterations only require `make fpga-fw` — no Vivado run.

### 📡 Baud rate note

| Context | UART baud | Set by |
|---------|-----------|--------|
| Simulation | 115200 | `app.overlay` (`current-speed = <115200>`) |
| NEORV32 bootloader | 19200 | BROM fixed — cannot be changed without recompiling |
| Application (FPGA) | 115200 | `app_fpga.overlay` (`current-speed = <115200>`) |

The NEORV32 bootloader (BROM) always runs at 19200 baud before handing off
to the application; this is a fixed hardware constraint.  The application
firmware then switches to 115200 baud.

### 🔀 Interrupt vs. polling drivers

| Mode | Kconfig symbol | Default | Used for |
|------|---------------|---------|----------|
| Polling | `CONFIG_SPI_NEORV32_INTERRUPT=n` | `prj.conf` | Simulation — simpler, no IRQ timing dependency |
| Interrupt-driven | `CONFIG_SPI_NEORV32_INTERRUPT=y` | `prj_fpga.conf` | Production FPGA — yields CPU between bytes |

Polling mode spins on `SPI_CTRL_BUSY`/`TWI_CTRL_RX_AVAIL`, blocking the
Zephyr scheduler for the duration of the transfer.  Interrupt-driven mode
uses FIRQ 6 (SPI) and FIRQ 7 (I2C).

### 🐛 JTAG debug

After the bitstream is loaded and firmware is running, attach GDB via the
NEORV32 on-chip debugger (OCD) on MC2 (pins 15–19).  An external JTAG adapter
(e.g. FTDI C232HM) must be connected to these pins:

```bash
# Terminal 1 — OpenOCD server
openocd -f fpga/xem7310/openocd.cfg \
        -f neorv32/sw/openocd/openocd_neorv32.cfg

# Terminal 2 — GDB client
riscv64-zephyr-elf-gdb build_zephyr_fpga/zephyr/zephyr.elf \
    -ex "target extended-remote localhost:3333" \
    -ex "monitor reset halt"
```

### 🔬 Hardware test setup

`make test-hw` builds a dedicated ZTEST image (verbose output, per-subsystem
logging, 115200 baud) and uploads it via the UART bootloader.

> **USB-C only (no MC1)?**  Use the FrontPanel UART bridge for firmware upload
> and test output.  SPI loopback (ATP-04) and I2C tests (ATP-05) will be
> skipped since those pins are on MC1.  GPIO, FFT, WDT, and bootloader tests
> work with the bridge alone.

#### 1. SPI loopback jumper *(requires MC1 access)*

Fit a jumper between **MC1-28** (MOSI, `W6`) and **MC1-29** (MISO, `U5`)
on the carrier board:

```
MC1 connector (SPI pins)
 pin 27  pin 28  pin 29  pin 30
  SCK    MOSI    MISO    CS0
           └──── jumper ───┘
```

#### 2. I2C slave (optional)

No external device is needed for the baseline I2C tests — NACK detection and
the bus scan run on bare hardware.  To enable slave write/read tests:

```bash
make test-hw EXTRA_CONF="CONFIG_TEST_I2C_SLAVE_ADDR=72"
# example: device at 0x48 (TMP102)
```

#### 3. Run the hardware tests

```bash
# With USB-UART on MC1:
make test-hw UART_DEVICE=/dev/ttyUSB1

# With FrontPanel UART bridge (no MC1):
# Terminal 1:  make uart-bridge                     (19200 for upload)
# Terminal 2:  make test-hw UART_DEVICE=/dev/pts/N
# After upload, restart bridge at 115200 for output.
```

#### 4. Reading test output

```bash
# With USB-UART on MC1:
minicom -D /dev/ttyUSB1 -b 115200 --noinit

# With FrontPanel UART bridge:
make uart-bridge BRIDGE_BAUD=115200
# then: minicom -D /dev/pts/N -b 115200
```

Expected output (all tests passing):

```
Running TESTSUITE ostomachion_spi
===================================================================
START - test_device_ready
 PASS - test_device_ready in 0 ms
...
TESTSUITE ostomachion_spi succeeded

Running TESTSUITE ostomachion_i2c
===================================================================
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

### 📈 FFT accelerator test

The FFT accelerator requires the full block-design bitstream (`make fpga-synth`
+ `make fpga-program`).  Build and upload the FFT ZTEST image:

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
[test_fft_accel] FFT latency: N cycles (~87 us)
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
[FFT] Input: DC (all 0.5 + 0j, 4096 points)
[FFT] Done in 245 us.  Bin 0: 16384  max_other: 0  PASS
uart:~$ fft sine 8
[FFT] Input: cosine at bin 8 (4096 points)
[FFT] Done in 250 us.  Peak bin: 8  magnitude: 8192  PASS
uart:~$ help
Available commands:
  fft     - FFT accelerator commands (dc, sine <bin 0..2047>, run <n>)
  test    - Run peripheral test suites
  kernel  - Kernel commands
```
