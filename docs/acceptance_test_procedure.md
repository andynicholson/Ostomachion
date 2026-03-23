# Ostomachion — Acceptance Test Procedure

**Document:** ATP-OST-001  
**Platform:** Ostomachion Accelerator Platform v1.0  
**Target Hardware:** Digilent Arty A7-100T (xc7a100tcsg324-1)  
**NEORV32:** v1.11.6  
**Date:** 2026-03  

---

## Prerequisites

| Item | Requirement |
|------|------------|
| Host OS | Ubuntu 22.04 or later (or Windows with WSL2) |
| Vivado | 2024.1+ with Artix-7 device support |
| OpenOCD | ≥ 0.12 with Xilinx FTDI support |
| RISCV toolchain | `riscv64-unknown-elf-gcc` (Zephyr SDK 1.0.0+) |
| Python | ≥ 3.10 |
| UART terminal | `minicom` or similar, 115200 8N1 |
| SPI loopback | Jumper wire: Pmod JA pin 2 (MOSI, B11) → pin 3 (MISO, A11) |
| Power supply | Arty A7 USB-powered (5 V micro-USB) |

Clone the repository with submodules:

```bash
git clone --recurse-submodules <repo-url>
cd neorv32_ghdl_mvp
west init -l .
west update --narrow -o=--depth=1
```

---

## Test Suite Overview

| # | Test ID | Description | Pass Criterion |
|---|---------|-------------|----------------|
| 1 | ATP-01 | Bitstream load + build-ID readback | Build ID matches `build_id.txt` |
| 2 | ATP-02 | UART bootloader handshake (19200 baud) | Bootloader banner visible |
| 3 | ATP-03 | Firmware upload and boot verification | `Ostomachion v1.0` banner at 115200 baud |
| 4 | ATP-04 | SPI loopback ZTEST | PASS on all SPI ZTEST cases |
| 5 | ATP-05 | I2C bus scan + device response | Bus scan completes, no AXI errors |
| 6 | ATP-06 | GPIO output (LED blink) | LED0..3 visibly blink at ~1 Hz |
| 7 | ATP-07 | FFT DC response test | Bin 0 = 16384 ± 1%, all others = 0 |
| 8 | ATP-08 | FFT single-tone test | Peak at expected bin, no overflow |
| 9 | ATP-09 | WDT keep-alive verification | System runs > 10 s without reset |
| 10 | ATP-10 | Power-cycle persistent boot (SPI flash) | Design boots without JTAG after power cycle |

---

## ATP-01: Bitstream Load + Build-ID Readback

**Objective:** Confirm the correct bitstream is programmed and the embedded
build ID matches the released `build_id.txt`.

**Procedure:**

1. Program the bitstream via JTAG:
   ```bash
   make fpga-synth
   make fpga-program
   ```
2. After programming, read the USERID via Vivado JTAG:
   ```tcl
   # In Vivado Tcl console with hw_server connected:
   open_hw_manager
   connect_hw_server
   open_hw_target
   refresh_hw_device [lindex [get_hw_devices] 0]
   get_property CONFIG.USERID [current_hw_device]
   ```
3. Compare the 8-digit hex value against the first 8 characters of the hash
   in `build/arty_a7/build_id.txt`.

**Pass Criterion:** USERID hex matches `build_id.txt` hash prefix. ✓

---

## ATP-02: UART Bootloader Handshake (19200 baud)

**Objective:** Confirm the NEORV32 BROM bootloader is responding over UART.

**Procedure:**

1. Reset the Arty A7 (press BTN RESET or power-cycle).
2. Open a UART terminal at **19200 baud, 8N1** on the USB-UART port:
   ```bash
   minicom -D /dev/ttyUSB1 -b 19200
   ```
3. Observe the bootloader banner within 2 seconds of reset.

**Expected output:**
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

**Pass Criterion:** Bootloader banner visible within 2 s of reset. ✓

---

## ATP-03: Firmware Upload and Boot Verification

**Objective:** Confirm Zephyr firmware can be uploaded via the UART bootloader
and boots correctly.

**Procedure:**

1. Build the FPGA firmware:
   ```bash
   make zephyr-fpga
   ```
2. Reset the board and upload within the bootloader's auto-boot window:
   ```bash
   make fpga-fw UART_DEVICE=/dev/ttyUSB1
   ```
3. Switch the terminal to **115200 baud**:
   ```bash
   minicom -D /dev/ttyUSB1 -b 115200
   ```
4. Observe the Zephyr boot banner.

**Expected output (partial):**
```
*** Booting Zephyr OS build v3.x.x ***
Ostomachion platform — build: v1.0.0 (git: abc1234e, ...)
[00:00:00.001,000] <inf> fft_accel: FFT accelerator (xfft) initialised, ...
```

**Pass Criterion:** Zephyr boot banner visible, no panic/assertion. ✓

---

## ATP-04: SPI Loopback ZTEST

**Objective:** Verify the SPI master driver, interrupt path, and HAL wrapper.

**Setup:**
- Install jumper: Pmod JA pin 2 (MOSI) → pin 3 (MISO).

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

## ATP-05: I2C Bus Scan

**Objective:** Verify the I2C master driver and open-drain pad logic.

**Note:** External 4.7 kΩ pull-ups to 3.3 V are required on SDA (Pmod JB pin 1)
and SCL (Pmod JB pin 2). With no slave device, the bus scan should complete
without bus errors (slaves may NACK — that is expected).

**Procedure:**

1. Using the same hardware test firmware from ATP-04, observe the I2C output.

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

## ATP-06: GPIO Output Verification

**Objective:** Verify LED outputs and GPIO HAL.

**Procedure:**

1. After firmware boots (ATP-03), observe the Arty A7 LEDs.
2. LED0 (LD0, green) should blink at approximately **1 Hz** (500 ms on/off)
   driven by the `led_blink_thread`.

**Expected output (UART):**
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
- GPIO ZTEST suite passes.
- LED0 visible blink at ~1 Hz during normal operation. ✓

---

## ATP-07: FFT DC Response Test

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

## ATP-08: FFT Single-Tone Test

**Objective:** Verify frequency localization for a single-frequency input.

**Procedure:**

1. Using accelerator test firmware (ATP-07 binary), observe:

**Expected output:**
```
Running test test_fft_single_tone...PASSED
```

**Pass Criterion:**
- Peak magnitude appears at the expected bin.
- `fft_accel_get_last_overflow()` returns false.
- No DMA timeout or error. ✓

---

## ATP-09: WDT Keep-Alive Verification

**Objective:** Confirm the hardware watchdog is armed and fed correctly so the
system does not reset unexpectedly.

**Procedure:**

1. Flash the FPGA firmware (ATP-03), which enables `CONFIG_WDT_NEORV32=y`.
2. Let the system run for **≥ 10 seconds** while monitoring UART output.
3. Verify no unexpected reset occurs (no re-appearance of the bootloader
   banner at 19200 baud).

**Pass Criterion:**
- System runs continuously for ≥ 10 s without a WDT reset.
- The 5 s WDT window is fed every 500 ms by the LED blink thread. ✓

---

## ATP-10: Power-Cycle Persistent Boot (SPI Flash)

**Objective:** Confirm the FPGA bitstream survives a power cycle by loading
from the on-board Quad-SPI flash.

**Procedure:**

1. Program the Quad-SPI flash (one-time, after `make fpga-synth`):
   ```bash
   make fpga-flash
   ```
2. Disconnect and reconnect power (or toggle the power switch on the Arty A7).
3. Observe the Arty A7: within ~2 seconds of power-up the LED configuration
   bitstream should load automatically (LEDs or logic initialise without any
   JTAG action from the host).
4. Open a UART terminal at 19200 baud and confirm the bootloader banner appears
   (no JTAG needed).

**Pass Criterion:**
- FPGA loads from flash on power-up (no JTAG required).
- NEORV32 bootloader banner visible at 19200 baud within 5 s of power-up.
- After firmware upload (ATP-03), full system boots normally. ✓

---

## Sign-Off

| Test | Result | Tester | Date | Notes |
|------|--------|--------|------|-------|
| ATP-01 Bitstream ID | | | | |
| ATP-02 UART bootloader | | | | |
| ATP-03 Firmware boot | | | | |
| ATP-04 SPI loopback | | | | |
| ATP-05 I2C bus scan | | | | |
| ATP-06 GPIO blink | | | | |
| ATP-07 FFT DC | | | | |
| ATP-08 FFT single-tone | | | | |
| ATP-09 WDT keep-alive | | | | |
| ATP-10 Flash persistent boot | | | | |

**Overall Result:** ☐ PASS  ☐ FAIL

Signed: ____________________________  Date: ________________

---

## Appendix A: Hardware Connection Reference

| Signal | Arty A7 Pin | Pmod | Function |
|--------|------------|------|---------|
| SPI SCK | G13 | JA-1 | SPI clock (loopback: not required) |
| SPI MOSI | B11 | JA-2 | SPI data out ← jumper to MISO |
| SPI MISO | A11 | JA-3 | SPI data in ← jumper from MOSI |
| SPI CS0 | D12 | JA-4 | SPI chip select |
| I2C SDA | E15 | JB-1 | I2C data (4.7 kΩ pull-up to 3V3) |
| I2C SCL | E16 | JB-2 | I2C clock (4.7 kΩ pull-up to 3V3) |
| JTAG TCK | K17 | JC-1 | JTAG clock |
| JTAG TDI | M18 | JC-2 | JTAG data in |
| JTAG TDO | N17 | JC-3 | JTAG data out |
| JTAG TMS | P18 | JC-4 | JTAG mode select |
| UART TX | D10 | — | USB-UART (FTDI) |
| UART RX | A9 | — | USB-UART (FTDI) |

## Appendix B: Self-Hosted Runner Configuration (HIL CI)

To enable the Hardware-in-the-Loop CI jobs (`ostomachion.hw.*` in
`zephyr_app/tests/testcase.yaml`), register a self-hosted GitHub Actions runner
on the repository with the label **`arty_a7`**:

1. Go to **Repository → Settings → Actions → Runners → New self-hosted runner**.
2. Follow the installation instructions for Linux.
3. After `./config.sh`, add the custom label:
   ```bash
   ./config.sh --labels arty_a7
   ```
4. Connect the Arty A7 via USB-JTAG to the runner host.
5. Set `UART_DEVICE` environment variable on the runner to the correct `/dev/ttyUSBx` path.

The HIL CI jobs are automatically excluded from `ubuntu-latest` runners
(`platform_allow: arty_a7`). To run only HIL tests locally:
```bash
west twister -T zephyr_app/tests --filter-tags hw -p arty_a7
```
