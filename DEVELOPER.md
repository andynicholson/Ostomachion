# Developer Reference

Detailed reference for contributors and integrators.  For setup and first
run, see [GETTING_STARTED.md](GETTING_STARTED.md).

---

## Repository layout

Fabric hierarchy (**`xem7310_top.vhd`** vs **`ostomachion_bd_wrapper`**) matches the ASCII stack in the root [README.md](README.md) (Architecture / RTL design).

```
.
├── Makefile                          # Build orchestration (GHDL sim, Zephyr, FPGA)
├── west.yml                          # West manifest — pins Zephyr SHA + SDK version
├── .github/workflows/ci.yml          # GitHub Actions CI (sim, twister, vhdl-lint, …)
├── .github/workflows/vivado-synth.yml  # Manual Vivado synthesis (self-hosted runner)
├── docs/
│   ├── acceptance_test_procedure.md  # HIL / self-hosted runner expectations
│   └── neorv32_upgrade_notes.md    # Checklist before bumping the neorv32 submodule
├── scripts/
│   ├── init_dev_env.sh               # Source to set ZEPHYR_BASE, venv, FRONTPANEL_DIR, Vivado PATH
│   ├── uart_bridge.py                # FrontPanel UART-over-USB bridge (PTY ↔ Pipes)
│   ├── uart_upload.py                # NEORV32 bootloader upload (used by make fpga-fw, test-*-hw)
│   ├── fpga_program.py               # FrontPanel USB bitstream load (used by make fpga-program)
│   ├── bin2vhd.py                    # ELF binary → VHDL IMEM image
│   └── gen_release_artifacts.sh      # Stage release/<VERSION>/ certification artifacts
├── rtl/
│   └── neorv32_wrapper.vhd           # Simulation wrapper around neorv32_top
├── fpga/xem7310/
│   ├── xem7310_top.vhd               # Board top: IBUFDS, NEORV32, bridge, BD wrapper, FrontPanel
│   ├── fp_uart_bridge.vhd            # FrontPanel UART bridge (async FIFOs + Pipe endpoints)
│   ├── xem7310.xdc                   # Vivado pin + timing constraints (XC7A200T)
│   ├── build.tcl                     # Non-interactive Vivado batch script
│   ├── ostomachion_bd.tcl            # IP Integrator block design (AXI DMA, xfft, BRAMs, INTC)
│   ├── check_build.tcl               # Post-build quality gates (timing, utilisation, DRC)
│   ├── program_jtag.tcl              # JTAG bitstream programming (fallback)
│   ├── program_flash.tcl             # SPI flash programming (persistent boot)
│   └── openocd.cfg                   # NEORV32 OCD debug (external JTAG adapter)
├── sim/
│   ├── neorv32_tb.vhd                # GHDL testbench (clock, reset, SPI/I2C/UART monitors)
│   └── sim_uart_rx.vhd               # UART character decoder
├── neorv32/                          # NEORV32 RTL submodule (v1.11.6)
│   └── rtl/system_integration/xbus2axi4_bridge.vhd   # XBUS → AXI4-Lite (FPGA fabric; vhdl-lint CI)
├── sw/test_gpio_uart/                # Bare-metal smoke-test firmware (C)
└── zephyr_app/
    ├── CMakeLists.txt
    ├── zephyr/module.yml             # Registers this tree as a Zephyr module (drivers/bindings)
    ├── prj.conf                      # Base Kconfig — ZTEST, SPI, I2C, GPIO, C++20 (sim / CI default)
    ├── prj_fpga.conf                 # Overlay — FPGA (IRQ drivers, larger stacks)
    ├── prj_accel.conf                # Overlay — FFT accelerator
    ├── prj_shell.conf                # Overlay — interactive shell (no ZTEST)
    ├── prj_hw_test.conf              # Overlay — verbose hardware test
    ├── app.overlay                   # DTS — spi0, i2c0 (simulation + FPGA base)
    ├── app_fpga.overlay              # DTS overlay — 115200 baud, FPGA clocks
    ├── app_accel.overlay             # DTS overlay — fft_accel node + IRQ
    ├── include/
    │   ├── ostomachion/
    │   │   ├── accel.hpp             # Generic Accel / AccelOpDesc base (RTTI-free)
    │   │   └── hal/
    │   │       ├── gpio.hpp          # GpioOutput + GpioInput
    │   │       ├── spi.hpp           # SpiDevice (std::span API)
    │   │       ├── i2c.hpp           # I2cBus (std::span API)
    │   │       └── fft_accel.hpp     # FftAccel (: Accel, C++20 RAII wrapper)
    │   └── zephyr/drivers/misc/
    │       └── fft_accel.h           # Public C API: fft_accel_transform(), _get_last_overflow()
    ├── src/
    │   ├── main.cpp                  # LED heartbeat thread (K_THREAD_DEFINE)
    │   ├── fft_shell.c               # "fft" shell commands
    │   └── test_runner.c             # "test run" shell command
    ├── tests/
    │   ├── testcase.yaml             # West Twister test matrix
    │   ├── test_spi.cpp
    │   ├── test_i2c.cpp
    │   ├── test_gpio.cpp
    │   ├── test_fft_accel.cpp
    │   └── test_wdt.cpp
    ├── dts/bindings/
    │   ├── misc/ostomachion,fft-accel.yaml
    │   ├── spi/neorv32,spi.yaml
    │   ├── i2c/neorv32,twi.yaml
    │   └── wdt/neorv32,wdt.yaml
    └── drivers/
        ├── spi/spi_neorv32.c
        ├── i2c/i2c_neorv32.c
        ├── accel/fft_accel.c         # FFT accelerator driver (DMA, semaphore, ISR)
        └── wdt/wdt_neorv32.c
```

---

## Peripheral map

| Peripheral | Sim | XEM7310 | MMIO base | IRQ | Zephyr driver |
|-----------|-----|---------|-----------|-----|---------------|
| GPIO (8 pins) | ✅ | ✅ | `0xFFFFFFC0` | — | `neorv32,gpio` |
| UART0 | ✅ | ✅ | `0xFFFFFFE0` | FIRQ 2 | `neorv32,uart` |
| SPI master | ✅ | ✅ | `0xFFF80000` | FIRQ 6 | `neorv32,spi` |
| I2C master | ✅ | ✅ | `0xFFF90000` | FIRQ 7 | `neorv32,twi` |
| CLINT | ✅ | ✅ | `0xF0000000` | — | `neorv32,clint` |
| Watchdog | — | ✅ | — | — | `neorv32,wdt` |
| AXI DMA ctrl | — | ✅ | `0x40000000` | MEI (IRQ 11) | `ostomachion,fft-accel` |
| TX BRAM | — | ✅ | `0x41000000` (32 KB) | — | (part of fft-accel) |
| RX BRAM | — | ✅ | `0x41008000` (32 KB) | — | (part of fft-accel) |
| AXI INTC | — | ✅ | `0x40010000` | — | (part of fft-accel) |
| AXI GPIO (xfft reset gate) | — | ✅ | `0x40020000` | — | (BD only; fft aresetn) |

IMEM: 128 KB (FPGA), 64 KB (sim).  DMEM: 64 KB both targets.

**GHDL / sim:** Xilinx **xfft** and the block design are not simulated; the default `prj.conf` image runs **SPI, I2C, and GPIO** ZTEST suites only. **WDT** and **FFT** tests are compiled for Twister or FPGA overlays (`prj_fpga.conf`, `prj_accel.conf`, `CONFIG_WDT_NEORV32`, `CONFIG_FFT_ACCEL` — see `CMakeLists.txt`).

**Interrupt topology**: AXI INTC (PG099) aggregates three sources into the
single NEORV32 MEI line: Ch0 = DMA MM2S, Ch1 = DMA S2MM, Ch2 = xfft
frame-complete (`m_axis_status_tvalid`).  The driver ISR reads INTC ISR to
identify pending sources and acknowledges via INTC IAR after clearing DMA
DMASR (W1C) to avoid spurious re-entry on the level-sensitive channels.
Full contract in [ACCEL_ARCH.md](ACCEL_ARCH.md).

---

## HAL API

All HAL classes live in `namespace ostomachion` and are header-only
zero-overhead wrappers around the Zephyr C APIs.

### `GpioOutput` / `GpioInput`

```cpp
ostomachion::hal::GpioOutput led{GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios)};
led.set(true);
led.toggle();

ostomachion::hal::GpioInput btn{GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios)};
bool active = btn.is_active();  // respects DTS active-state polarity
```

### `SpiDevice`

```cpp
static const spi_config cfg = {
    .frequency = 1'000'000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
};
ostomachion::hal::SpiDevice spi{DEVICE_DT_GET(DT_NODELABEL(spi0)), cfg};

std::array<std::byte, 4> tx{std::byte{0x11}, std::byte{0x22},
                             std::byte{0x33}, std::byte{0x44}};
std::array<std::byte, 4> rx{};
int err = spi.transfer(std::span{tx}, std::span{rx});
```

### `I2cBus`

```cpp
ostomachion::hal::I2cBus i2c{DEVICE_DT_GET(DT_NODELABEL(i2c0))};
std::array<std::byte, 1> tx{std::byte{0x42}};
std::array<std::byte, 1> rx{};
int err = i2c.write_then_read(0x50U, tx, rx);  // REPEATED START
```

### `FftAccel`

```cpp
#include <ostomachion/hal/fft_accel.hpp>

const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
ostomachion::FftAccel accel{dev};

static fft_sample_t in[4096]{};   // Q1.15 complex: {int16_t re, int16_t im}
static fft_sample_t out[4096]{};

in[0].re = 16384;  // 0.5 in Q1.15
int err = accel.transform(in, out, 4096);

if (accel.last_overflow()) { /* reduce input amplitude */ }
```

Via the generic platform interface:

```cpp
ostomachion::FftOpDesc op{in, out, 4096};
int err = accel.submit(op);  // type-safe, no RTTI
```

`transform()` / `submit()` return codes:

| Code | Meaning |
|------|---------|
| `0` | Success |
| `-ENODEV` | Device not ready |
| `-EINVAL` | `n != 4096` |
| `-ETIMEDOUT` | DMA did not complete within `CONFIG_FFT_ACCEL_TIMEOUT_MS` |
| `-EIO` | DMA bus fault |

Kconfig: `CONFIG_FFT_ACCEL=y`, `CONFIG_FFT_ACCEL_TIMEOUT_MS` (default 100 ms).

---

## Accelerator abstraction

`include/ostomachion/accel.hpp` defines the generic platform interface:

```cpp
namespace ostomachion {

struct AccelOpDesc {
    enum class Type : unsigned { Unknown = 0, Fft = 1 };
    const Type type_id;
protected:
    explicit AccelOpDesc(Type t = Type::Unknown) : type_id{t} {}
};

class Accel {
public:
    [[nodiscard]] virtual bool ready()                        const noexcept = 0;
    [[nodiscard]] virtual int  submit(const AccelOpDesc &op)       noexcept = 0;
    [[nodiscard]] virtual bool last_overflow()                const noexcept { return false; }
};
```

`AccelOpDesc::type_id` enables safe `static_cast` dispatch in concrete
`submit()` implementations — no `dynamic_cast` needed under `-fno-rtti`.

**Adding a new accelerator:**
1. Add `MatMul = 2` to `AccelOpDesc::Type`.
2. Create `MatMulOpDesc : AccelOpDesc` with operation parameters.
3. Create `MatMulAccel : Accel` implementing `submit()`.
4. Write the C driver and DTS binding following the `fft_accel` pattern.

---

## Memory model

There is no heap.  `CONFIG_HEAP_MEM_POOL_SIZE = 0`.

| What | Mechanism |
|------|-----------|
| FFT sample buffers | `static fft_sample_t g_fft_in[4096]` (BSS) |
| Driver state | Zephyr `DEVICE_DEFINE` macro (linker section) |
| Thread stacks | `CONFIG_MAIN_STACK_SIZE` etc. (link time) |
| Semaphores, mutexes | `K_SEM_DEFINE`, `K_MUTEX_DEFINE` (static) |

Verify at link time: `riscv64-zephyr-elf-nm --size-sort zephyr.elf`.

---

## C++20 in embedded

The build uses `-nostdinc++` (Zephyr's minimal C++ layer, no libstdc++).

| Feature | Available |
|---------|-----------|
| `constexpr`, `[[nodiscard]]`, concepts | ✅ (compiler intrinsic) |
| `std::span`, `std::array` | ✅ (Zephyr provides) |
| `virtual`, vtables | ✅ (RTTI not needed for vtables) |
| `std::string`, `std::vector` | ❌ (heap-dependent) |
| `dynamic_cast`, `typeid` | ❌ (`-fno-rtti`) |
| Exceptions | ❌ (`-fno-exceptions`) |

Use `static_cast` with `AccelOpDesc::type_id` instead of `dynamic_cast`.
Use errno return codes instead of exceptions.

---

## Continuous integration

`.github/workflows/ci.yml` — four jobs on PR and push to `main`/`master`/`develop`:

| Job | Runner | What it does |
|-----|--------|-------------|
| `sim` | ubuntu-latest | `make ZEPHYR_SIM_TIME=800ms test-zephyr`; assert `PROJECT EXECUTION SUCCESSFUL` in the log |
| `twister` | ubuntu-latest | `west twister -T zephyr_app --integration --exclude-tag hw` (after `sim` succeeds) |
| `vhdl-lint` | ubuntu-latest | GHDL `-i`: NEORV32 core lib, `xbus2axi4_bridge.vhd`, `rtl/neorv32_wrapper.vhd` |
| `firmware-analysis` | ubuntu-latest | clang-tidy, `nm --size-sort` memory map, thread analyser (runs after `twister`) |

`.github/workflows/vivado-synth.yml` — **manual only** (`workflow_dispatch`):

| Job | Runner | What it does |
|-----|--------|-------------|
| `vivado-synth` | self-hosted, label `vivado` | `make fpga-synth && make fpga-check`, upload `.bit` + reports — trigger from Actions tab |

In-progress runs are cancelled when a new commit arrives on the same ref (`concurrency`).

**Local vs CI Zephyr board:** the Makefile defaults to `ZEPHYR_BOARD = neorv32/neorv32/minimalboot` for `make zephyr` / `make test-zephyr`. The CI `sim` job uses `-b neorv32` with `-DCONF_FILE=prj.conf`; both paths use the same application `prj.conf` baseline.

---

## Testing

### GHDL simulation

```bash
make test-zephyr      # Zephyr + GHDL: SPI / I2C / GPIO ZTEST (default prj.conf)
make test-baremetal   # bare-metal GPIO + UART smoke test
```

The testbench (`sim/neorv32_tb.vhd`) models:
- **SPI**: MOSI wired to MISO; every byte is echoed back unchanged.
- **I2C**: Synthesised slave at `0x50`; ACKs all writes, returns `0x5A` on reads.
- **Hang detector**: at **390 ms** simulated time, the bench fails if the GPIO heartbeat has not advanced (firmware stuck); this is **not** the NEORV32 watchdog peripheral (WDT tests require `CONFIG_WDT_NEORV32` and FPGA DTS — see Twister / `make test-hw`).

ZTEST output format (parsed by CI and Twister):

```
Running TESTSUITE ostomachion_spi
 PASS - test_loopback_zero
 PASS - test_full_duplex
TESTSUITE ostomachion_spi succeeded
...
PROJECT EXECUTION SUCCESSFUL
```

### West Twister

```bash
west twister -T zephyr_app --integration --exclude-tag hw -v
```

> `testcase.yaml` lives at the `zephyr_app/` root (next to `CMakeLists.txt` /
> `prj.conf`) so Twister has a buildable project; the ZTEST suites under
> `zephyr_app/tests/` are compiled into the build by `CMakeLists.txt` when
> `CONFIG_ZTEST=y`.

| Test ID | Board | Type |
|---------|-------|------|
| `ostomachion.peripherals.baseline` | neorv32 sim | build + run |
| `ostomachion.fft.compile` | neorv32 sim | build only |
| `ostomachion.shell.compile` | neorv32 sim | build only |
| `ostomachion.wdt.compile` | neorv32 sim | build + run |
| `ostomachion.hw.peripherals` | xem7310 | HIL (`xem7310_hw` fixture) |
| `ostomachion.hw.fft` | xem7310 | HIL (`xem7310_hw_fft` fixture) |

HIL tests require a self-hosted runner (label `xem7310`), the XEM7310
connected, a programmed bitstream, and the harness fixtures named above.
See [docs/acceptance_test_procedure.md](docs/acceptance_test_procedure.md)
for runner setup and acceptance flow.

---

## Extending the platform

### Adding a new NEORV32 peripheral

1. Enable the `IO_*_EN` generic in `rtl/neorv32_wrapper.vhd`; wire I/O ports.
2. Create `dts/bindings/<bus>/neorv32,<periph>.yaml`.
3. Write `drivers/<bus>/<periph>_neorv32.c` following `spi_neorv32.c`.
4. Add `include/ostomachion/hal/<periph>.hpp` in `namespace ostomachion::hal`.
5. Write `tests/test_<periph>.cpp` and add a Twister entry to `testcase.yaml`.

### Adding a new hardware accelerator

1. Add the IP to `ostomachion_bd.tcl`; wire AXI4-Lite, AXI4-Stream, and IRQ.
2. Wire the IRQ to the next free `irq_concat_intc` channel; update `C_NUM_INTR_INPUTS`.
3. Create a DTS binding and overlay following `ostomachion,fft-accel.yaml`.
4. Write the C driver following `fft_accel.c` (`k_sem_reset` before each transfer, `device_is_ready` guard).
5. Add `Type::<NewAccel>` to `AccelOpDesc::Type`; create `NewAccelOpDesc` and `NewAccel : Accel`.

---

## Full Makefile target reference

| Target | Description |
|--------|-------------|
| `make test-default` | Clean + simulate with built-in NEORV32 demo |
| `make test-baremetal` | Build bare-metal firmware + simulate |
| `make test-zephyr` | Build Zephyr (sim config) + simulate |
| `make zephyr` | Build Zephyr (simulation target) only |
| `make zephyr-fpga` | Build Zephyr for FPGA (115200 baud, IRQ drivers) |
| `make sw` | Build bare-metal firmware only |
| `make clean-ghdl` | Remove GHDL artifacts |
| `make clean` | Full clean (GHDL + firmware + all Zephyr build dirs) |
| `make fpga-synth` | Vivado: synthesise + implement + bitstream + MCS |
| `make fpga-program` | Load bitstream (volatile, FrontPanel USB) |
| `make fpga-flash` | Program SPI flash (persistent) |
| `make uart-bridge` | Start FrontPanel UART bridge (PTY) |
| `make fpga-fw` | Upload firmware via UART bootloader |
| `make fpga-check` | Post-build quality gates (timing, utilisation, DRC) |
| `make fpga-release VERSION=v1.0.0` | Stage certification artifacts |
| `make test-hw` | Upload + run SPI/I2C/GPIO/WDT ZTEST firmware |
| `make test-accel-hw` | Upload + run FFT accelerator ZTEST firmware |
| `make shell-hw` | Upload interactive shell firmware |

**Debug ILA bitstream** (logic analyser probes on AXI-Stream and IRQ nets):

```bash
vivado -mode batch -source fpga/xem7310/build.tcl -tclargs debug \
    | tee build/xem7310/build_debug.log
# outputs: ostomachion_xem7310_debug.bit + debug_probes.ltx
```

Load the `.bit` via JTAG and open `.ltx` in Vivado Hardware Manager.

---

## Design decisions

**Two targets, one codebase.**  Target-specific differences are isolated to a
VHDL top-level, a DTS overlay, and a Kconfig fragment.  No application code
knows which environment it runs in.

**Interrupt-driven on hardware, polling available for simulation.**
`CONFIG_SPI_NEORV32_INTERRUPT=y` and `CONFIG_I2C_NEORV32_INTERRUPT=y`
(enabled by `prj_fpga.conf`) use FIRQ 6/7 to yield the thread between bytes.
The polling fallback avoids FIRQ timing dependencies in the GHDL testbench.
Both paths compile from the same source, gated by `#ifdef`.

**`BOOT_MODE_SELECT = 2` for simulation, `0` for FPGA.**  Mode 2 skips the
UART bootloader (a multi-second negotiation on every GHDL run).  Mode 0 on
hardware lets `make fpga-fw` upload new firmware without re-synthesising.

**115200 baud everywhere except the bootloader.**  The NEORV32 BROM always
runs at 19200 baud — fixed, cannot change without recompiling the bootloader.
Application firmware switches to 115200 immediately on boot.

**No heap.**  `CONFIG_HEAP_MEM_POOL_SIZE = 0`.  See [Memory model](#memory-model).

**XBUS bus-access timeout.**  NEORV32's `XBUS_TIMEOUT` (default 255 cycles)
auto-terminates accesses that receive no ACK, raising a bus fault exception.
The `xbus2axi4_bridge` relies on this rather than a bridge-side watchdog.

**IOBUF and IBUFDS in the FPGA top.**  `xem7310_top.vhd` instantiates Xilinx
`IBUFDS` and `IOBUF` directly; `neorv32_wrapper.vhd` remains technology-neutral
for simulation.

---

## Interrupt architecture

```
INTC Ch0 — AXI DMA MM2S complete / error
INTC Ch1 — AXI DMA S2MM complete / error      ──OR──→  NEORV32 mext_irq_i
INTC Ch2 — xfft frame complete (m_axis_status_tvalid)
```

- Channels 0 and 1 are **level-sensitive** (`C_KIND_OF_INTR` bits 0–1 = 0):
  `mm2s_introut`/`s2mm_introut` stay asserted until DMASR is W1C-cleared.
- Channel 2 is **edge-sensitive** (`C_KIND_OF_INTR` bit 2 = 1):
  `m_axis_status_tvalid` is a single-cycle pulse.  It marks frame
  completion, not overflow specifically — see [ACCEL_ARCH.md §2.2](ACCEL_ARCH.md#22-axi-intc-channel-wiring).

The ISR clears DMASR (W1C) before writing INTC IAR; acknowledging IAR before
the source de-asserts causes the ISR bit to re-assert immediately (spurious
re-entry) on level-sensitive channels.

To add further accelerators: wire their IRQs to new INTC channels, widen
`irq_concat_intc` and `C_NUM_INTR_INPUTS` in `ostomachion_bd.tcl`, and add
channel handling to the driver ISR.

---

## Debugging with waveforms

```bash
make test-zephyr WAVE=1
gtkwave output.ghw
```

| Signal path | What it shows |
|-------------|---------------|
| `neorv32_tb.dut.neorv32_inst.clk_i` | System clock |
| `neorv32_tb.dut.neorv32_inst.rstn_i` | Active-low reset |
| `neorv32_tb.gpio` | GPIO output (8 bits) |
| `neorv32_tb.uart_tx` | UART TX serial line |
| `neorv32_tb.spi_mosi` | SPI MOSI |
| `neorv32_tb.twi_sda` | I2C SDA (open-drain) |

UART text is also decoded to `UART0.log`:

```bash
cat UART0.log
```

---

## NEORV32 version lock

This project uses **NEORV32 v1.11.6**, pinned by submodule hash.  Before
upgrading, read [`docs/neorv32_upgrade_notes.md`](docs/neorv32_upgrade_notes.md).

Key concerns:
- Verify `uart_neorv32.c` register bit positions against new `neorv32_uart.h`.
- Check for `neorv32_top` generic renames (run `vhdl-lint` CI first).
- Allow for a full re-synthesis and re-acceptance test (~2 engineer-days).

**Do not upgrade for the v1.0.0 client delivery.**  Plan as a separate work
item post-acceptance.
