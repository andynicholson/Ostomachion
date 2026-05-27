# NEORV32 Upgrade Assessment

**Document:** UPG-OST-001  
**Current version locked:** v1.11.6 (hw_version_c = 0x01110600)  
**Assessment:** Upgrade path from v1.11.6 to v1.12.x  
**Date:** 2026-03  

---

## Executive Summary

The Ostomachion platform pins NEORV32 to v1.11.6 for production stability.
This document assesses the effort required to upgrade to v1.12.x when it
becomes available, identifies current risk areas based on NEORV32's development
history, and provides a **go / no-go recommendation** for the client's
roadmap planning.

**Recommendation: NO-GO for v1.0.0 delivery. Plan upgrade as a separate tracked work item after client acceptance.**

---

## Why v1.11.6 is Locked

| Reason | Details |
|--------|---------|
| Timing closure verified | Build verified at +0.292 ns WNS / +0.019 ns WHS on xc7a200tfbg484-1 |
| Zephyr driver compatibility | **Upstream (Zephyr tree):** `uart_neorv32`, `gpio_neorv32` (NEORV32 board BSP). **This repo (out-of-tree):** `spi_neorv32`, `i2c_neorv32`, `wdt_neorv32`, FFT accel — all verified / maintained against v1.11.6 |
| FrontPanel UART bridge | `fp_uart_bridge.vhd` intercepts NEORV32 UART0 signals — verify UART port names after upgrade |
| Submodule hash | Pinned in `.gitmodules`; deterministic builds guaranteed |
| No known regressions | CI and hardware acceptance tests have passed on this version |

---

## Key Changes Between v1.11.6 and Prior Versions Affecting This Platform

The following `:warning:` changelog entries since v1.11.1 were evaluated for
impact on the Ostomachion codebase. They are already incorporated in v1.11.6
and represent the "delta absorbed" when v1.11.6 was adopted.

| Version | Change | Impact on Ostomachion |
|---------|--------|-----------------------|
| v1.11.5.8 | `IMEM_EN`/`IMEM_SIZE`/`DMEM_EN`/`DMEM_SIZE` generics renamed | **Already handled** in v1.11.6; `xem7310_top.vhd` uses current names |
| v1.11.3.7 | Internal bus protocol reworked | XBUS remains stable at `neorv32_top` boundary; bridge is unaffected |
| v1.11.4.8 | Hardware spinlocks removed | Not used by this platform |
| v1.11.4.7 | `mcause` CSR now read-only | Not written by application code |
| v1.11.1.8 | NEORV32 internal DMA auto mode removed | Ostomachion uses AXI DMA (Xilinx), not NEORV32 internal DMA |
| v1.11.2.1 | Clock gating option removed | Not used by this platform |

---

## Risks for a Hypothetical v1.12.x Upgrade

Based on the NEORV32 development trajectory and the structure of this platform,
the following risk areas have been identified for any future major version upgrade.

### Risk 1 (HIGH): Zephyr `uart_neorv32` Driver Register Compatibility

**Current state:**  
The Zephyr upstream `uart_neorv32.c` driver (used by this project) was verified
against NEORV32 v1.11.6 register layout:

| Field | Bits | v1.11.6 Definition | Zephyr Driver Macro |
|-------|------|--------------------|---------------------|
| EN | [0] | `UART_CTRL_EN` | `NEORV32_UART_CTRL_EN = BIT(0)` ✓ |
| SIM_MODE | [1] | `UART_CTRL_SIM_MODE` | `NEORV32_UART_CTRL_SIM_MODE = BIT(1)` ✓ |
| HWFC_EN | [2] | `UART_CTRL_HWFC_EN` | `NEORV32_UART_CTRL_HWFC_EN = BIT(2)` ✓ |
| PRSC | [5:3] | `UART_CTRL_PRSC0..2` | `NEORV32_UART_CTRL_PRSC = GENMASK(5,3)` ✓ |
| BAUD | [15:6] | `UART_CTRL_BAUD0..9` | `NEORV32_UART_CTRL_BAUD = GENMASK(15,6)` ✓ |
| TX_BUSY | [31] | `UART_CTRL_TX_BUSY` | `NEORV32_UART_CTRL_TX_BUSY = BIT(31)` ✓ |

**Upgrade action required:**  
Before any NEORV32 upgrade, verify that the UART CTRL register layout has not
changed in the target version. Check `neorv32_uart.h` in the new submodule
against the Zephyr `uart_neorv32.c` driver macros. If bit positions differ,
the Zephyr driver must be patched before synthesis.

**Verification method:**
```bash
# After updating submodule to new version:
diff <(grep "UART_CTRL" neorv32/sw/lib/include/neorv32_uart.h) \
     <(grep "NEORV32_UART_CTRL" $(find $ZEPHYR_BASE -name uart_neorv32.c))
```

### Risk 2 (MEDIUM): XBUS Protocol Changes

**Current state:**  
The XBUS bridge now uses the upstream `xbus2axi4_bridge` from
`neorv32/rtl/system_integration/`.  Since it ships with the submodule,
protocol changes in future NEORV32 versions will be handled automatically.
The bridge is instantiated with `BURST_EN => false` (BD is AXI4-Lite)
and `XBUS_REGSTAGE_EN => true` is set on the NEORV32 top for timing closure.

**Upgrade action required:**  
After upgrading the submodule, re-run GHDL synthesis over the top-level VHDL:
```bash
make fpga-synth 2>&1 | grep "ERROR\|WARNING"
```
And run the VHDL lint CI job (`vhdl-lint` in `.github/workflows/ci.yml`) to
catch any XBUS port signature changes before committing to re-synthesis.

### Risk 3 (MEDIUM): `neorv32_top` Generic Names

**Current state (v1.11.6):**

| Generic | Type | Value in xem7310_top.vhd |
|---------|------|--------------------------|
| `CLOCK_FREQUENCY` | natural | 100_000_000 |
| `BOOT_MODE_SELECT` | natural range 0..2 | 0 |
| `IMEM_EN` | boolean | true |
| `IMEM_SIZE` | natural | 128 × 1024 |
| `DMEM_EN` | boolean | true |
| `DMEM_SIZE` | natural | 64 × 1024 |
| `XBUS_EN` | boolean | true |
| `OCD_EN` | boolean | true |
| `IO_CLINT_EN` | boolean | true |
| `IO_UART0_EN` | boolean | true |
| `IO_UART0_TX_FIFO` | natural | 32 |
| `IO_SPI_EN` | boolean | true |
| `IO_SPI_FIFO` | natural | 32 |
| `IO_TWI_EN` | boolean | true |
| `IO_TWI_FIFO` | natural | 32 |
| `IO_GPIO_NUM` | natural | 8 |
| `IO_WDT_EN` | boolean | true |

**Upgrade action required:**  
After updating the submodule, compare this table against the new
`neorv32_top.vhd` generic map. NEORV32 has historically renamed generics
in minor versions (e.g. v1.11.5.8 renamed IMEM/DMEM generics). Any mismatch
will cause a GHDL or Vivado elaboration error — easily caught by the
`vhdl-lint` CI job.

### Risk 4 (LOW): Mixed Upstream vs Out-of-Tree NEORV32 Drivers

**Current state:**  
Ostomachion uses a **split** model:

| Driver | Location | Notes |
|--------|----------|--------|
| UART | Zephyr upstream (`drivers/serial/uart_neorv32.c`) | Tied to the Zephyr SDK / board revision in `west.yml` |
| GPIO | Zephyr upstream (`drivers/gpio/gpio_neorv32.c`) | Same — comes with `boards/riscv/neorv32/` |
| SPI | **This repository** — `zephyr_app/drivers/spi/spi_neorv32.c` | Out-of-tree; must be diffed against NEORV32 `neorv32_spi.h` on upgrade |
| I2C (TWI) | **This repository** — `zephyr_app/drivers/i2c/i2c_neorv32.c` | Out-of-tree; check `neorv32_twi.h` |
| WDT | **This repository** — `zephyr_app/drivers/wdt/wdt_neorv32.c` | Out-of-tree; check `neorv32_wdt.h` |
| FFT accel | **This repository** — `zephyr_app/drivers/accel/fft_accel.c` | Custom MMIO; not NEORV32 core IP |

Upgrading the NEORV32 submodule therefore requires **both** (a) reconciling
Zephyr upstream drivers with the new silicon headers *and* (b) updating any
register macros or FIFO behaviour in the local `zephyr_app/drivers/` copies.

**Upgrade action required:**  
- **Upstream:** Compare Zephyr’s `uart_neorv32.c` and `gpio_neorv32.c` (and DTS
  under `boards/riscv/neorv32/`) with the new `neorv32_uart.h` / `neorv32_gpio.h`
  in the updated submodule.  
- **Out-of-tree:** Review `zephyr_app/drivers/spi/spi_neorv32.c`,
  `zephyr_app/drivers/i2c/i2c_neorv32.c`, and `zephyr_app/drivers/wdt/wdt_neorv32.c`
  against the matching NEORV32 C headers; run peripheral ZTEST / HIL after any change.

---

## Upgrade Effort Estimate

| Task | Est. Hours | Risk |
|------|-----------|------|
| Update submodule to target version | 0.5 | Low |
| Run `vhdl-lint` CI + fix generic renames | 1–4 | Medium |
| Verify UART register map vs. Zephyr driver | 1–2 | High |
| Full Vivado re-synthesis (inc. AXI INTC) | 2–4 | Medium |
| GHDL regression + Twister re-run | 1 | Low |
| Hardware acceptance test re-run | 2 | Low |
| **Total** | **7.5–13.5** | — |

---

## Go / No-Go Recommendation

| Criterion | Status |
|-----------|--------|
| v1.12.x released and stable | Not yet (as of 2026-03) |
| All v1.0.0 ATP tests pass on v1.11.6 | Required before any upgrade |
| UART register map unchanged | Verify before upgrade |
| Client-approved change window | Required (upgrade = re-synthesis + new ATP run) |

**Recommendation:** **NO-GO** for the v1.0.0 delivery.

Upgrade NEORV32 only after:
1. v1.0.0 client acceptance is signed off.
2. A v1.12.x stable release is available with a published CHANGELOG.
3. The UART register layout is confirmed unchanged (or the Zephyr driver is patched).
4. A dedicated change order is agreed with the client covering ~2 days of integration work and a full re-acceptance test.

---

## Upgrade Procedure (When Approved)

```bash
# 1. Create upgrade branch
git checkout -b upgrade/neorv32-v1.12.x

# 2. Update submodule
cd neorv32
git fetch --tags
git checkout v1.12.x   # replace with actual tag
cd ..
git add neorv32
git commit -m "chore: bump neorv32 submodule to v1.12.x"

# 3. Verify VHDL lint (fast feedback, no Vivado needed)
# (CI vhdl-lint job will catch generic name changes)
ghdl -i --std=08 --work=neorv32 neorv32/rtl/core/*.vhd
ghdl -i --std=08 --work=work neorv32/rtl/system_integration/xbus2axi4_bridge.vhd rtl/neorv32_wrapper.vhd
ghdl -i --std=08 --work=work fpga/xem7310/fp_uart_bridge.vhd fpga/xem7310/xem7310_top.vhd
ghdl -m --std=08 --work=work xem7310_top

# 4. Verify UART driver register compatibility
diff <(grep "UART_CTRL" neorv32/sw/lib/include/neorv32_uart.h | sort) \
     <(grep "NEORV32_UART_CTRL" $(find $ZEPHYR_BASE -name uart_neorv32.c) | sort)

# 5. Re-synthesise (requires Vivado)
make fpga-synth

# 6. Run full regression
make SIM_TIME=400ms test-zephyr
west twister -T zephyr_app/tests --integration

# 7. Hardware acceptance test (ATP-01 through ATP-10)
# See docs/acceptance_test_procedure.md
```
