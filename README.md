# NEORV32 GHDL Simulation MVP

Cycle-accurate GHDL simulation of the [NEORV32](https://github.com/stnolting/neorv32)
RISC-V soft-core processor, running both bare-metal firmware and a full
Zephyr RTOS application with C++20.

## Repository layout

```
.
├── Makefile                 # Top-level build orchestration
├── neorv32_wrapper.vhd      # Thin wrapper around neorv32_top
├── neorv32_tb.vhd           # GHDL testbench (clock, reset, monitors)
├── neorv32/                 # NEORV32 RTL submodule (v1.11.6)
├── sw/test_gpio_uart/       # Bare-metal test firmware (C)
│   ├── main.c
│   ├── makefile
│   └── neorv32_newlib.c     # Empty stub to shadow HAL's newlib shim
├── zephyr_app/              # Zephyr RTOS application (C++20)
│   ├── CMakeLists.txt
│   ├── prj.conf
│   ├── app.overlay
│   └── src/main.cpp
└── bin2vhd.py               # Utility: raw binary → VHDL IMEM image
```

## Architecture

The hardware wrapper (`neorv32_wrapper.vhd`) instantiates `neorv32_top` with:

| Generic             | Value       | Purpose                          |
|----------------------|-------------|----------------------------------|
| `CLOCK_FREQUENCY`    | 100 MHz     | Matches testbench clock          |
| `BOOT_MODE_SELECT`   | 2           | Boot directly from IMEM (no bootloader) |
| `IMEM_SIZE`          | 64 KB       | Instruction memory               |
| `DMEM_SIZE`          | 64 KB       | Data memory                      |
| `IO_CLINT_EN`        | true        | Machine timer (required by Zephyr) |
| `IO_GPIO_NUM`        | 8           | 8-bit GPIO output                |
| `IO_UART0_EN`        | true        | UART0 serial console             |
| `RISCV_ISA_C`        | true        | Compressed instructions          |
| `RISCV_ISA_M`        | true        | Hardware multiply/divide         |

The testbench (`neorv32_tb.vhd`) provides:
- 100 MHz clock generator
- Reset release after 100 ns
- **UART RX monitor** — decodes serial output at 19200 baud and prints
  each character to the console
- **GPIO change monitor** — reports every GPIO transition with timestamp

Simulation duration is controlled entirely by GHDL's `--stop-time` flag,
passed through the Makefile's `SIM_TIME` variable.

## Prerequisites

### System packages

```bash
sudo apt install ghdl gtkwave gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf \
                 ninja-build device-tree-compiler cmake python3-venv
```

### Zephyr SDK (only needed for `test-zephyr`)

```bash
cd ~
wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.0/zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
tar xf zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
cd zephyr-sdk-1.0.0 && ./setup.sh
```

### Zephyr workspace (only needed for `test-zephyr`)

```bash
python3 -m venv ~/.zephyr-venv
source ~/.zephyr-venv/bin/activate
pip install west
west init -m https://github.com/zephyrproject-rtos/zephyr --mr main ~/src/zephyrproject
cd ~/src/zephyrproject && west update
pip install -r zephyr/scripts/requirements.txt
```

## Running the testbenches

### Bare-metal test

Builds a minimal C firmware that toggles GPIO pin 0 in a tight loop and
prints `"NEORV32 bare-metal test OK"` over UART0 (sim-mode — output goes
directly to the GHDL console, bypassing the baud-rate generator).

```bash
make test-baremetal
```

Expected output:

```
[TB] Reset released.
NEORV32 bare-metal test OK
[TB] GPIO changed: 0x01 at ...
[TB] GPIO changed: 0x00 at ...
[TB] GPIO changed: 0x01 at ...
...
```

### Zephyr RTOS test

Builds a Zephyr application with C++20, boots the full kernel, prints a
banner over UART0 (real 19200-baud serial), and toggles an LED via the
GPIO driver.

```bash
source ~/.zephyr-venv/bin/activate
export ZEPHYR_BASE=~/src/zephyrproject/zephyr
make test-zephyr
```

This takes approximately 15 minutes of wall time for the 80 ms simulation.
Expected output (one character per line from the UART monitor):

```
[TB] Reset released.
UART0.rx: *
UART0.rx: *
UART0.rx: *
UART0.rx:
UART0.rx: B
...                        ← "*** Booting Zephyr OS build v4.3.0-... ***"
UART0.rx: N
UART0.rx: E
UART0.rx: O
...                        ← "NEORV32 + Zephyr + C++20 Booted!"
[TB] GPIO changed: 0x01   ← LED configured
[TB] GPIO changed: 0x00   ← first toggle()
```

### Default image test

Runs the simulation with whatever application image is baked into the
NEORV32 RTL (useful for sanity-checking the VHDL without any software
build):

```bash
make test-default
```

## Debugging with waveforms

Every simulation produces `output.ghw` (GHDL's native waveform format).
Open it in GTKWave:

```bash
gtkwave output.ghw
```

Useful signals to inspect:

| Signal path                                | What it shows                |
|--------------------------------------------|------------------------------|
| `neorv32_tb.dut.neorv32_inst.clk_i`       | System clock                 |
| `neorv32_tb.dut.neorv32_inst.rstn_i`      | Reset                        |
| `neorv32_tb.gpio`                          | GPIO output (8 bits)         |
| `neorv32_tb.uart_tx`                       | UART TX serial line          |
| `neorv32_tb.dut.neorv32_inst.*.bus_req_*`  | Internal bus transactions    |

### Adjusting simulation time

Override `SIM_TIME` on the command line to run shorter or longer
simulations:

```bash
# Quick 1 ms check
make IMEM_IMAGE=zephyr_imem_image.vhd SIM_TIME=1ms clean-ghdl all

# Long 200 ms run to capture multiple LED toggles
make IMEM_IMAGE=zephyr_imem_image.vhd SIM_TIME=200ms clean-ghdl all
```

### UART log file

The UART monitor writes decoded characters to `UART0.log` (in addition to
the console). You can concatenate the characters after a run:

```bash
cat neorv32_tb.UART0_rx.out
```

## How it works

### Build pipeline

```
 ┌─────────────┐     ┌───────────┐     ┌──────────────┐     ┌────────────┐
 │  C/C++ src  │────▶│ Compiler  │────▶│  image_gen   │────▶│  VHDL pkg  │
 │  (sw/ or    │     │ (GCC or   │     │  (ELF→VHD)   │     │ (IMEM      │
 │  zephyr_app)│     │  west)    │     │              │     │  init data)│
 └─────────────┘     └───────────┘     └──────────────┘     └─────┬──────┘
                                                                   │
                     ┌───────────┐     ┌──────────────┐           │
                     │  NEORV32  │     │   GHDL       │◀──────────┘
                     │  RTL core │────▶│  simulation  │───▶ output.ghw
                     │  (VHDL)   │     │              │───▶ console logs
                     └───────────┘     └──────────────┘
```

1. **Bare-metal path**: GCC cross-compiles `sw/test_gpio_uart/main.c`,
   the NEORV32 `image_gen` tool converts the ELF to a VHDL package
   (`neorv32_application_image`), and GHDL uses it to initialize the
   IMEM ROM.

2. **Zephyr path**: `west build` compiles the full Zephyr kernel +
   application, then `image_gen` (found via `CMAKE_PROGRAM_PATH`)
   produces the VHDL package as a post-build step.  The Makefile copies
   this to `zephyr_imem_image.vhd` and passes it to GHDL.

### IMEM image override

When `IMEM_IMAGE` is set, the Makefile excludes the default
`neorv32_application_image.vhd` from the core sources and substitutes the
custom one.  This ensures GHDL uses the correct firmware image.

## NEORV32 version

This project uses **NEORV32 v1.11.6**, which matches the UART register
layout expected by the Zephyr `uart_neorv32` driver. Newer NEORV32
versions (v1.12+) reorganized the UART control register bits and are not
compatible with the current Zephyr board support.

## Makefile targets

| Target           | Description                                        |
|------------------|----------------------------------------------------|
| `make all`       | Analyze + simulate with default image              |
| `make test-default` | Clean + simulate with the built-in NEORV32 demo |
| `make test-baremetal` | Build bare-metal firmware + simulate           |
| `make test-zephyr` | Build Zephyr app + simulate (needs venv active)  |
| `make zephyr`    | Build Zephyr app only (no simulation)              |
| `make sw`        | Build bare-metal firmware only                     |
| `make clean-ghdl`| Remove GHDL artifacts (keeps firmware)             |
| `make clean`     | Full clean (GHDL + firmware + Zephyr build)        |

## Troubleshooting

**`image_gen` not found during `make test-zephyr`**
: Ensure the venv is activated and `ZEPHYR_BASE` is set before running.

**Simulation takes very long**
: GHDL interprets the RTL cycle-by-cycle. 80 ms at 100 MHz = 8 million
  clock cycles. Reduce `SIM_TIME` for faster iteration.

**No UART output in simulation**
: The bare-metal test uses UART sim-mode (characters printed directly to
  stdout). The Zephyr test uses real 19200-baud serial — look for
  `UART0.rx:` lines in the output. Ensure the testbench `BAUD` generic
  (19200) matches the firmware's configured baud rate.

**`CONFIG_UART_INTERRUPT_DRIVEN` causes hangs**
: The Zephyr app uses polling mode (`CONFIG_UART_INTERRUPT_DRIVEN=n`).
  Interrupt-driven TX can hang in simulation if the FIRQ routing isn't
  fully exercised.
