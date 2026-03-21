/*
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * neorv32_regs.h — Common definitions shared across all NEORV32 out-of-tree
 * Zephyr drivers.  Including this header makes cross-driver dependencies
 * explicit rather than relying on implicit symbols pulled in by <soc.h>.
 */

#pragma once

#include <soc.h> /* NEORV32_SYSINFO_CLK, NEORV32_SYSINFO_SOC, NEORV32_SYSINFO_SOC_IO_* */

/*
 * Polling retry budget for all NEORV32 peripheral drivers.
 *
 * At 100 MHz each loop iteration takes ~10 ns; 1 M retries give a ~10 ms
 * worst-case timeout — comfortably above any single peripheral transaction at
 * minimum supported clock rates (SPI: lowest PRSC, I2C: 100 kHz standard).
 * If a peripheral genuinely needs more than 10 ms to complete a transaction,
 * increase this constant and document the reason.
 */
#define NEORV32_POLL_RETRIES 1000000U
