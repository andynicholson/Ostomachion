# Getting Started

This guide covers everything needed to go from a fresh clone to a running
simulation and a programmed XEM7310-A200.

---

## Prerequisites

### System packages

```bash
sudo apt install ghdl ghdl-llvm gtkwave gcc-riscv64-unknown-elf \
                 ninja-build device-tree-compiler cmake python3-venv
```

### Zephyr SDK

```bash
cd ~
wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.0/zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
tar xf zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
cd zephyr-sdk-1.0.0 && ./setup.sh
```

### Zephyr workspace (recommended)

```bash
python3 -m venv ~/.zephyr-venv
source ~/.zephyr-venv/bin/activate
pip install west
west init -m <this-repo-url> --mr main ~/ostomachion_ws
cd ~/ostomachion_ws && west update
pip install -r zephyr/scripts/requirements-base.txt
```

This clones Zephyr at the pinned SHA and all required modules (cmsis,
hal_riscv, picolibc, tinycrypt), matching the environment used by CI and
hardware validation.

### Opal Kelly FrontPanel SDK

Required only for FPGA bitstream builds and the UART bridge.  Download from
[opalkelly.com](https://www.opalkelly.com) and install to `~/OpalKelly/`.
`scripts/init_dev_env.sh` auto-detects the SDK from `~/OpalKelly/FrontPanel-*`
or you can set `FRONTPANEL_DIR` manually before sourcing it.

### Vivado

Required only for `make fpga-synth`.  Tested on 2025.1; any edition ≥ 2024.1
works.  Install and note the path to `settings64.sh`.

---

## Environment setup

Source the helper script once per shell session from the repo root:

```bash
cd /path/to/ostomachion
source scripts/init_dev_env.sh
```

This sets `ZEPHYR_BASE`, activates the Python venv, exports `FRONTPANEL_DIR`
(auto-detected or pre-set), and sources the Vivado `settings64.sh` if found.

**Override any default before sourcing:**

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTOMACHION_ZEPHYR_VENV` | `~/.zephyr-venv` | Python venv path |
| `OSTOMACHION_ZEPHYR_WORKSPACE` | `~/src/zephyrproject` | West workspace root |
| `ZEPHYR_SDK_INSTALL_DIR` | `~/zephyr-sdk-1.0.0` | Zephyr SDK root |
| `OSTOMACHION_VIVADO_SETTINGS` | `/tools/Xilinx/2025.1/Vivado/settings64.sh` | Vivado env script |
| `FRONTPANEL_DIR` | auto-detected from `~/OpalKelly/FrontPanel-*` | FrontPanel SDK root |

---

## Simulation quickstart

```bash
make test-zephyr          # build Zephyr (sim config) + run GHDL testbench
make test-baremetal       # build bare-metal firmware + simulate
```

The testbench connects SPI MOSI→MISO (loopback), runs an I2C slave at address
`0x50`, and monitors UART0 at 115200 baud.  Decoded output appears on the
console and in `UART0.log`.

**Control simulation length:**

```bash
make test-zephyr SIM_TIME=100ms   # faster iteration
make test-zephyr SIM_TIME=300ms   # more time for watchdog test
```

**Capture waveforms:**

```bash
make test-zephyr WAVE=1
gtkwave output.ghw
```

---

## Deploying to XEM7310-A200

### 1 — Build the bitstream

```bash
make fpga-synth
```

Outputs:
- `build/xem7310/ostomachion_xem7310.bit` — FPGA bitstream
- `build/xem7310/ostomachion_xem7310.mcs` — SPI flash image
- `build/xem7310/build_id.txt` — semver + git hash + timestamp

Build time is typically 10–20 minutes.

### 2 — Program the FPGA (volatile — erased on power-cycle)

```bash
make fpga-program
```

Loads the bitstream via the FrontPanel USB interface.  On success LED D1
blinks at ~1 Hz once the firmware's heartbeat thread starts.

### 3 — Program the SPI flash (persistent — survives power-cycle)

```bash
make fpga-flash
```

The board auto-configures from flash on every power-up after this.

### 4 — Upload firmware

After the bitstream is loaded, the NEORV32 BROM bootloader waits at **19200
baud** for a firmware image.

**Via FrontPanel UART bridge (USB-C only):**

```bash
# Terminal 1 — start bridge (19200 baud for bootloader; auto-switches to 115200 after upload)
make uart-bridge
# note the PTY path printed, e.g. /dev/pts/3

# Terminal 2 — upload firmware; bridge switches baud automatically when done
make fpga-fw UART_DEVICE=/dev/pts/3

# Terminal 2 — connect a terminal (bridge is already at 115200, PTY path unchanged)
minicom -D /dev/pts/3 -b 115200
```

The bridge is started with `--baud-after 115200`.  When `make fpga-fw` finishes
uploading it sends `SIGUSR1` to the bridge (via `/tmp/uart_bridge.pid`), which
switches the FPGA's baud divisor register to 115200 in-place.  The PTY path
does not change — minicom can connect to the same device without restarting
the bridge.

**Via external USB-UART adapter on MC1:**

```bash
make fpga-fw UART_DEVICE=/dev/ttyUSB1
minicom -D /dev/ttyUSB1 -b 115200
```

Subsequent firmware iterations only require `make fpga-fw` — no Vivado run.

### Hardware test suites

```bash
make test-hw         # SPI / I2C / GPIO / WDT ZTEST suite
make test-accel-hw   # FFT accelerator ZTEST suite
make shell-hw        # Interactive shell (fft dc, fft sine 8, test run …)
```

### Baud rate reference

| Context | Baud | Set by |
|---------|------|--------|
| Simulation | 115200 | `app.overlay` |
| NEORV32 bootloader | 19200 | BROM — fixed |
| Application (FPGA) | 115200 | `app_fpga.overlay` |

---

## Pin map (XEM7310-A200)

| Signal | Pin | Notes |
|--------|-----|-------|
| `sys_clk_p/n` | W11/W12 | 200 MHz LVDS, on-board, Bank 13 |
| `led[0]`–`led[7]` | A13–B17 | On-board LEDs D1–D8, LVCMOS15, active-low |
| `ext_rstn` | AB7 | MC1-37 — active-low reset |
| `uart_txd_out` / `uart_rxd_in` | W9/Y9 | MC1-15/17 — UART (use bridge or FTDI) |
| `spi_clk_o`, `spi_dat_o`, `spi_dat_i`, `spi_csn_o` | T5/W6/U5/W5 | MC1 SPI |
| `twi_sda` / `twi_scl` | AA5/AB5 | MC1 I2C — **4.7 kΩ pull-ups to 3V3 required** |
| `jtag_tck/tdi/tdo/tms` | P5/P4/N4/P6 | MC2 — NEORV32 OCD JTAG |

---

## Troubleshooting

**`image_gen` not found during `make test-zephyr`**
: Ensure the venv is activated and `ZEPHYR_BASE` is set — run `source scripts/init_dev_env.sh` first.

**Simulation takes a long time**
: GHDL is cycle-accurate.  200 ms at 100 MHz = 20 million cycles.  Use a
shorter `SIM_TIME`; all peripheral tests complete within ~120 ms simulated.

**No UART output in simulation**
: The Zephyr build uses real 115200-baud serial — look for `UART0:` lines in
the GHDL console.  The bare-metal test uses UART sim-mode and writes directly
to stdout.

**ZTEST reports `PROJECT EXECUTION FAILED`**
: Check the `FAIL -` lines in the UART log.  The most common cause is the
I2C slave timing out — try `SIM_TIME=300ms`.

**`fft_accel_transform()` returns `-ETIMEDOUT`**
: Verify the bitstream is loaded and the AXI DMA / xfft IP are clocked.
Persistent timeouts indicate a hardware fault or a DMA start-order issue.

**`fft_accel.last_overflow()` returns `true`**
: Reduce input amplitude before calling `transform()`.  The FFT output is
returned but may be clipped for the overflowed bins.

**`FRONTPANEL_DIR` not found after sourcing init_dev_env.sh**
: Download the FrontPanel SDK from opalkelly.com, install it, then either
let auto-detection find `~/OpalKelly/FrontPanel-*` or set `FRONTPANEL_DIR`
explicitly before sourcing the script.
