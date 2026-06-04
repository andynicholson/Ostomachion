# Ostomachion — Acceptance Test Procedure

**Document:** ATP-OST-001  
**Platform:** Ostomachion Accelerator Platform v1.0  
**Target Hardware:** Opal Kelly XEM7310-A200 (xc7a200tfbg484-1)  
**NEORV32:** v1.11.6  
**Date:** 2026-03  

---

## Prerequisites

| Item | Requirement |
|------|------------|
| Host OS | Ubuntu 22.04 or later (or Windows with WSL2) |
| Vivado | 2024.1+ with Artix-7 device support |
| FrontPanel SDK | Opal Kelly FrontPanel SDK installed; `ok` Python module importable; `FRONTPANEL_DIR` env var set |
| RISCV toolchain | `riscv64-unknown-elf-gcc` (Zephyr SDK 1.0.0+) |
| Python | ≥ 3.10 |
| USB-C cable | XEM7310-A200 connected to host via USB-C (FrontPanel interface) |
| UART access | `make uart-bridge` creates a PTY for UART over USB-C (no MC1 needed); or external USB-UART on MC1 |
| UART terminal | `minicom` or similar, 8N1, **hardware flow control on** (see below) — connect to the bridge PTY or MC1 adapter |
| SPI loopback | *(MC1 access required)* Jumper wire: MC1-28 (MOSI, W6) → MC1-29 (MISO, U5) |
| Power supply | XEM7310-A200 USB-powered (5 V USB-C) |

Clone the repository with submodules:

```bash
git clone --recurse-submodules <repo-url>
cd ostomachion
west init -l .
west update --narrow -o=--depth=1
```

---

## Test Suite Overview

| # | Test ID | Description | MC1 needed? | Pass Criterion |
|---|---------|-------------|:-----------:|----------------|
| 1 | ATP-01 | Bitstream load + UART bootloader handshake | No | LED D1 on, bootloader banner at 19200 baud |
| 2 | ATP-02 | Firmware upload and boot verification | No | `Ostomachion v1.0` banner at 115200 baud |
| 3 | ATP-03 | SPI loopback ZTEST | **Yes** | PASS on all SPI ZTEST cases |
| 4 | ATP-04 | I2C bus scan + device response | **Yes** | Bus scan completes, no AXI errors |
| 5 | ATP-05 | GPIO output (LED blink) | No | On-board LEDs D1–D8 blink visually |
| 6 | ATP-06 | FFT DC response test | No | Bin 0 = 16384 ± 1%, all others = 0 |
| 7 | ATP-07 | FFT single-tone test | No | Peak at expected bin, no overflow |
| 8 | ATP-08 | WDT keep-alive verification | No | System runs > 10 s without reset |
| 9 | ATP-09 | Power-cycle persistent boot (SPI flash) | No | Design boots without JTAG after power cycle |

---

## ATP-01: Bitstream Load + UART Bootloader Handshake

**Objective:** Confirm the bitstream programs successfully, the NEORV32
processor boots into its BROM bootloader, and the UART bridge carries the
bootloader's output to the host.

**Procedure:**

1. Build the bitstream:
   ```bash
   make fpga-synth
   ```
2. Program the FPGA and start the UART bridge in one step (Terminal 1):
   ```bash
   make uart-bridge PROGRAM=1
   # Prints the PTY path (e.g. /dev/pts/3), then programs the FPGA,
   # then starts bridging.  The bootloader banner is buffered in the
   # hardware FIFO while the bridge initialises.
   ```
3. Open a serial terminal on the PTY (Terminal 2):
   ```bash
   minicom -D /dev/pts/3 -b 19200
   # Once inside minicom, enable hardware flow control:
   #   Ctrl-A  O  →  Serial port setup  →  F  (toggle to "Yes")  →  Enter  →  Esc
   ```
4. The bootloader banner should appear within 2 seconds:
   ```
   << NEORV32 Bootloader >>
   BLDV: Oct  1 2024
   HWV:  0x01110600
   CLK:  0x05F5E100
   MISA: 0x40101104
   ZEXT: 0x00000005
   SOC:  0x7B803801
   IMEM: 0x00020000 bytes @0x00000000
   DMEM: 0x00010000 bytes @0x80000000
   Autoboot in 8 seconds. Press key to abort.
   ```
5. Verify on-board LED D1 illuminates (the bootloader drives gpio[0] high
   on start-up).
6. Confirm `HWV` matches the expected NEORV32 version (v1.11.6 → `0x01110600`)
   and `CLK` shows `0x05F5E100` (100 MHz).

**Pass Criterion:**
- FPGA configures successfully via FrontPanel (no programming errors). ✓
- On-board LED D1 illuminates after reset. ✓
- Bootloader banner is visible on the UART bridge PTY at 19200 baud within 2 s. ✓
- `HWV` and `CLK` values match the expected hardware configuration. ✓

---

## ATP-02: Firmware Upload and Boot Verification

**Objective:** Confirm Zephyr firmware can be uploaded via the UART bootloader
and boots correctly.

**Procedure:**

1. Start the UART bridge with FPGA programming (Terminal 1).  The bridge
   starts at 19200 baud (bootloader) and automatically switches to 115200
   (firmware) after the upload script signals it:
   ```bash
   make uart-bridge PROGRAM=1
   # Note the PTY path (e.g. /dev/pts/3).
   # The bootloader banner will scroll past in the bridge output.
   # Do NOT open minicom yet — the upload script needs exclusive
   # access to the PTY.
   ```
2. Upload firmware (Terminal 2).  Wait for the bootloader's `CMD:>`
   prompt (visible in the bridge's debug output) before running this:
   ```bash
   make fpga-fw UART_DEVICE=/dev/pts/3
   ```
   When the upload finishes, the bridge automatically switches to 115200.
3. Open minicom at 115200 baud (Terminal 2, after upload completes):
   ```bash
   minicom -D /dev/pts/3 -b 115200
   ```
   The Zephyr boot banner should appear.

   > **Important:** Do not open minicom while the upload is running.
   > Both minicom and `uart_upload.py` read from the same PTY; running
   > them simultaneously causes them to steal bytes from each other.

   > **With MC1 USB-UART:** use
   > `make fpga-fw UART_DEVICE=/dev/ttyUSB1` then
   > `minicom -D /dev/ttyUSB1 -b 115200`.

**Expected output (partial):**
```
*** Booting Zephyr OS build v4.x.x ***
Running TESTSUITE ostomachion_gpio
===================================================================
START - test_gpio_device_ready
 PASS - test_gpio_device_ready in 0.002 seconds
...
```

**Pass Criterion:** Zephyr boot banner visible, ZTEST output appears,
no panic/assertion. ✓

---

## ATP-03: SPI Loopback ZTEST *(requires MC1 access)*

**Objective:** Verify the SPI master driver, interrupt path, and HAL wrapper.

> **Note:** This test requires the SPI pins on the MC1 expansion connector.
> If MC1 is not accessible, this test must be deferred.

**Setup:**
- Install jumper: MC1-28 (MOSI, W6) → MC1-29 (MISO, U5).

**Procedure:**

1. Build and upload the hardware test firmware:
   ```bash
   make test-hw UART_DEVICE=/dev/ttyUSB1
   ```
2. Monitor UART output at 115200 baud.

**Expected output:**
```
Running test suite ostomachion_spi
Running test test_spi_loopback...PASSED
Running test test_spi_stress_loopback...PASSED
...
SUITE PASS - 5/5 tests passed: ostomachion_spi
```

**Pass Criterion:** All SPI ZTEST cases pass (0 failures). ✓

---

## ATP-04: I2C Bus Scan *(requires MC1 access)*

**Objective:** Verify the I2C master driver and open-drain pad logic.

> **Note:** This test requires the I2C pins on the MC1 expansion connector.
> If MC1 is not accessible, this test must be deferred.

**Note:** External 4.7 kΩ pull-ups to 3.3 V are required on SDA (MC1-31, AA5)
and SCL (MC1-33, AB5). With no slave device, the bus scan should complete
without bus errors (slaves may NACK — that is expected).

**Procedure:**

1. Using the same hardware test firmware from ATP-03, observe the I2C output.

**Expected output:**
```
Running test suite ostomachion_i2c
Running test test_i2c_device_ready...PASSED
Running test test_i2c_bus_scan...PASSED
...
SUITE PASS
```

**Pass Criterion:** I2C suite passes (no bus errors / driver panics). ✓

---

## ATP-05: GPIO Output Verification

**Objective:** Verify LED outputs and GPIO HAL.

**Procedure:**

1. Build and upload the hardware test firmware:
   ```bash
   # Terminal 1 (bridge must already be running from ATP-01/02, or restart it):
   make uart-bridge PROGRAM=1
   # Terminal 2:
   make test-hw UART_DEVICE=/dev/pts/3
   ```
2. After upload, the bridge switches to 115200 baud automatically.
   Switch minicom to 115200 (`Ctrl-A P` → 115200) and observe the
   GPIO test suite output.
3. Visually confirm LED D1 (gpio[0]) blinks at approximately **1 Hz**
   (500 ms on/off) on the XEM7310 module.

**Expected output (UART at 115200 baud):**
```
Running test suite ostomachion_gpio
Running test test_gpio_device_ready...PASSED
Running test test_led_configure...PASSED
Running test test_led_set_high...PASSED
Running test test_led_set_low...PASSED
Running test test_led_toggle...PASSED
Running test test_led_individual...PASSED
Running test test_gpio_input_construct...PASSED
...
SUITE PASS
```

**Pass Criterion:**
- GPIO ZTEST suite passes (all tests PASSED in UART output). ✓
- LED D1 visible blink at ~1 Hz on the XEM7310 module. ✓

---

## ATP-06: FFT DC Response Test

**Objective:** Verify the FFT accelerator produces correct output for a DC
(all-zeros imaginary, constant real) input.

**Expected result:**
- Input: 4096 samples with `re = 0x4000` (0.5 in Q1.15), `im = 0`
- Output: bin 0 = `N × re_in / 2` = 4096 × 0.5 / 2 = 1024 (scaled)
  (actual value depends on scale schedule; verify against ZTEST reference)

**Procedure:**

1. Build and upload the accelerator test firmware:
   ```bash
   make test-accel-hw UART_DEVICE=/dev/ttyUSB1
   ```

**Expected output:**
```
Running test suite ostomachion_fft
Running test test_fft_dc_response...PASSED
...
SUITE PASS
```

**Pass Criterion:** `test_fft_dc_response` passes with correct bin 0 value. ✓

---

## ATP-07: FFT Single-Tone Test

**Objective:** Verify frequency localization for a single-frequency input.

**Procedure:**

1. Using accelerator test firmware (ATP-06 binary), observe:

**Expected output:**
```
Running test test_fft_single_tone...PASSED
```

**Pass Criterion:**
- Peak magnitude appears at the expected bin.
- `fft_accel_get_last_overflow()` returns false.
- No DMA timeout or error. ✓

---

## ATP-08: WDT Keep-Alive Verification

**Objective:** Confirm the hardware watchdog is armed and fed correctly so the
system does not reset unexpectedly.

**Procedure:**

1. Flash the FPGA firmware (ATP-02), which enables `CONFIG_WDT_NEORV32=y`.
2. Let the system run for **≥ 10 seconds** while monitoring UART output.
3. Verify no unexpected reset occurs (no re-appearance of the bootloader
   banner at 19200 baud).

**Pass Criterion:**
- System runs continuously for ≥ 10 s without a WDT reset.
- The 5 s WDT window is fed every 500 ms by the LED blink thread. ✓

---

## ATP-09: Power-Cycle Persistent Boot (SPI Flash)

**Objective:** Confirm the FPGA bitstream survives a power cycle by loading
from the on-board Quad-SPI flash.

**Procedure:**

1. Program the SPI flash (one-time, after `make fpga-synth`):
   ```bash
   make fpga-flash
   ```
2. Disconnect and reconnect power to the XEM7310-A200.
3. Observe: within ~2 seconds of power-up the configuration bitstream should
   load automatically from the on-board SPI flash (logic initialises without
   any JTAG action from the host).
4. Start the UART bridge or open a terminal on MC1 at 19200 baud to confirm
   the bootloader banner appears (no JTAG needed):
   ```bash
   make uart-bridge   # or: minicom -D /dev/ttyUSB1 -b 19200
   ```

**Pass Criterion:**
- FPGA loads from flash on power-up (no JTAG required).
- NEORV32 bootloader banner visible at 19200 baud within 5 s of power-up.
- After firmware upload (ATP-02), full system boots normally. ✓

---

## Sign-Off

| Test | Result | Tester | Date | Notes |
|------|--------|--------|------|-------|
| ATP-01 Bitstream + bootloader | | | | |
| ATP-02 Firmware boot | | | | |
| ATP-03 SPI loopback | | | | |
| ATP-04 I2C bus scan | | | | |
| ATP-05 GPIO blink | | | | |
| ATP-06 FFT DC | | | | |
| ATP-07 FFT single-tone | | | | |
| ATP-08 WDT keep-alive | | | | |
| ATP-09 Flash persistent boot | | | | |

**Overall Result:** ☐ PASS  ☐ FAIL

Signed: ____________________________  Date: ________________

---

## Appendix A: Hardware Connection Reference

**On-board (no carrier needed):**

| Signal | FPGA Pin | Location | Function |
|--------|----------|----------|---------|
| LED D1 (led[0]) | A13 | On-board | GPIO[0] — blink heartbeat (Bank 14, LVCMOS15) |
| LED D2 (led[1]) | B13 | On-board | GPIO[1] |
| LED D3 (led[2]) | A14 | On-board | GPIO[2] |
| LED D4 (led[3]) | A15 | On-board | GPIO[3] |
| LED D5 (led[4]) | B15 | On-board | GPIO[4] |
| LED D6 (led[5]) | A16 | On-board | GPIO[5] |
| LED D7 (led[6]) | B16 | On-board | GPIO[6] |
| LED D8 (led[7]) | B17 | On-board | GPIO[7] |

**Expansion connectors (carrier / breakout required):**

| Signal | FPGA Pin | MC Pin | Function |
|--------|----------|--------|---------|
| SPI SCK | T5 | MC1-27 | SPI clock (loopback: not required) |
| SPI MOSI | W6 | MC1-28 | SPI data out -- jumper to MISO |
| SPI MISO | U5 | MC1-29 | SPI data in -- jumper from MOSI |
| SPI CS0 | W5 | MC1-30 | SPI chip select |
| I2C SDA | AA5 | MC1-31 | I2C data (4.7 kOhm pull-up to 3V3) |
| I2C SCL | AB5 | MC1-33 | I2C clock (4.7 kOhm pull-up to 3V3) |
| JTAG TCK | P5 | MC2-15 | NEORV32 OCD clock |
| JTAG TDI | P4 | MC2-17 | NEORV32 OCD data in |
| JTAG TDO | N4 | MC2-19 | NEORV32 OCD data out |
| JTAG TMS | P6 | MC2-16 | NEORV32 OCD mode select |
| UART TX | W9 | MC1-15 | External USB-UART adapter (or use `make uart-bridge` for USB-C) |
| UART RX | Y9 | MC1-17 | External USB-UART adapter (or use `make uart-bridge` for USB-C) |

## Appendix B: Self-Hosted Runner Configuration (HIL CI)

To enable the Hardware-in-the-Loop CI jobs (`ostomachion.hw.*` in
`zephyr_app/testcase.yaml`), register a self-hosted GitHub Actions runner
on the repository with the label **`xem7310`**:

1. Go to **Repository → Settings → Actions → Runners → New self-hosted runner**.
2. Follow the installation instructions for Linux.
3. After `./config.sh`, add the custom label:
   ```bash
   ./config.sh --labels xem7310
   ```
4. Connect a JTAG cable to the XEM7310-A200 FPGA JTAG pins on MC2.
5. Connect a USB-UART adapter to MC1 UART pins (MC1-15 TX, MC1-17 RX).
6. Set `UART_DEVICE` environment variable on the runner to the correct `/dev/ttyUSBx` path.

The HIL CI jobs are automatically excluded from `ubuntu-latest` runners
(`platform_allow: xem7310`). To run only HIL tests locally:
```bash
west twister -T zephyr_app --filter-tags hw -p xem7310
```
