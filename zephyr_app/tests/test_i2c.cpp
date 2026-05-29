// Copyright (c) 2026
// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// I2C test suite for Ostomachion.
//
// Baseline tests (no external hardware required):
//   - Device readiness guard
//   - NACK on non-existent address (bus health check)
//   - Repeated NACK recovery (driver re-entrancy check)
//   - Bus scan (completes without hang across the full valid address range)
//
// Optional slave tests (require CONFIG_TEST_I2C_SLAVE_ADDR != 0):
//   - Write, read, and combined write-then-read to a known slave
//   - Use zassume_true to skip gracefully when no slave is configured
//
// Simulation:
//   The GHDL testbench provides a slave at address 0x50.  Set
//   CONFIG_TEST_I2C_SLAVE_ADDR=80 (0x50) in prj.conf to enable slave tests
//   in simulation.  The baseline tests run in all configurations.

#include <zephyr/ztest.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/i2c.h>

#include <array>
#include <cstddef>

#include "ostomachion/hal/i2c.hpp"

// --- Fixture ---------------------------------------------------------------

struct ostomachion_i2c_fixture {
    const struct device *dev;
};

static void *i2c_setup(void)
{
    static struct ostomachion_i2c_fixture f;
    f.dev = DEVICE_DT_GET(DT_NODELABEL(i2c0));
    zassert_true(device_is_ready(f.dev),
                 "i2c0 not ready — check DTS bindings and driver config");
    return &f;
}

ZTEST_SUITE(ostomachion_i2c, NULL, i2c_setup, NULL, NULL, NULL);

// --- Baseline tests (no external hardware) ---------------------------------

ZTEST_F(ostomachion_i2c, test_device_ready)
{
    zassert_true(device_is_ready(fixture->dev), "i2c0 not ready");
}

// Probe a non-existent address.  A correctly functioning bus returns -ENXIO
// (slave NACK on address).  This test verifies both that the bus is alive and
// that the driver's error path produces the right errno.
ZTEST_F(ostomachion_i2c, test_nack_nonexistent)
{
    ostomachion::hal::I2cBus i2c{fixture->dev};
    std::array<std::byte, 1> rx{std::byte{0x00}};

    // 0x7F is a reserved / typically-unpopulated address.
    int ret = i2c.read(0x7F, std::span{rx});

    zassert_equal(ret, -ENXIO,
                  "expected -ENXIO from absent address 0x7F, got %d", ret);
}

// Five consecutive NACK attempts on a non-existent address.  Each attempt
// must return the same error code, proving the driver recovers correctly
// between transactions and does not corrupt internal state.
ZTEST_F(ostomachion_i2c, test_nack_repeated)
{
    ostomachion::hal::I2cBus i2c{fixture->dev};
    std::array<std::byte, 1> rx{std::byte{0x00}};

    for (int attempt = 0; attempt < 5; attempt++) {
        int ret = i2c.read(0x7F, std::span{rx});
        zassert_equal(ret, -ENXIO,
                      "NACK recovery attempt %d: expected -ENXIO, got %d",
                      attempt, ret);
    }
}

// Scan the full valid 7-bit address range (0x08–0x77).  For each address
// attempt a 1-byte read.  The test asserts only that the scan completes
// without hanging — not which addresses respond.  Addresses that respond are
// logged for informational purposes.
//
// Gated by CONFIG_TEST_I2C_BUS_SCAN (disabled by default) to keep the GHDL
// simulation within its 200 ms window.  Enable in prj_hw_test.conf.
ZTEST_F(ostomachion_i2c, test_bus_scan)
{
    zassume_true(IS_ENABLED(CONFIG_TEST_I2C_BUS_SCAN),
                 "Bus scan disabled — enable CONFIG_TEST_I2C_BUS_SCAN");

    ostomachion::hal::I2cBus i2c{fixture->dev};
    int found = 0;

    for (uint16_t addr = 0x08U; addr <= 0x77U; addr++) {
        std::array<std::byte, 1> rx{std::byte{0x00}};
        int ret = i2c.read(addr, std::span{rx});
        if (ret == 0) {
            printk("[I2C scan] found device at 0x%02x\n",
                   static_cast<unsigned>(addr));
            found++;
        } else if (ret != -ENXIO) {
            // Unexpected error — not a clean NACK.
            printk("[I2C scan] addr 0x%02x returned unexpected error %d\n",
                   static_cast<unsigned>(addr), ret);
        }
    }

    printk("[I2C scan] complete: %d device(s) found\n", found);
    // The scan must not hang; any found count (including zero) is valid.
}

// --- Optional slave tests (require CONFIG_TEST_I2C_SLAVE_ADDR != 0) --------
//
// These tests are skipped gracefully when no slave address is configured,
// making the suite runnable on bare hardware with no external device.

ZTEST_F(ostomachion_i2c, test_slave_write)
{
    zassume_true(CONFIG_TEST_I2C_SLAVE_ADDR != 0,
                 "No slave configured — set CONFIG_TEST_I2C_SLAVE_ADDR");

    ostomachion::hal::I2cBus i2c{fixture->dev};
    const std::array<std::byte, 3> tx{
        std::byte{0x01}, std::byte{0x02}, std::byte{0x03}};

    zassert_ok(i2c.write(CONFIG_TEST_I2C_SLAVE_ADDR, std::span{tx}),
               "I2C write to 0x%02x failed", CONFIG_TEST_I2C_SLAVE_ADDR);
}

ZTEST_F(ostomachion_i2c, test_slave_read)
{
    zassume_true(CONFIG_TEST_I2C_SLAVE_ADDR != 0,
                 "No slave configured — set CONFIG_TEST_I2C_SLAVE_ADDR");

    ostomachion::hal::I2cBus i2c{fixture->dev};
    std::array<std::byte, 2> rx{};

    zassert_ok(i2c.read(CONFIG_TEST_I2C_SLAVE_ADDR, std::span{rx}),
               "I2C read from 0x%02x failed", CONFIG_TEST_I2C_SLAVE_ADDR);

    printk("[I2C slave_read] 0x%02x 0x%02x\n",
           static_cast<unsigned>(rx[0]), static_cast<unsigned>(rx[1]));
}

ZTEST_F(ostomachion_i2c, test_slave_write_read)
{
    zassume_true(CONFIG_TEST_I2C_SLAVE_ADDR != 0,
                 "No slave configured — set CONFIG_TEST_I2C_SLAVE_ADDR");

    ostomachion::hal::I2cBus i2c{fixture->dev};
    const std::array<std::byte, 1> tx{std::byte{0x42}};
    std::array<std::byte, 1> rx{};

    zassert_ok(i2c.write_then_read(CONFIG_TEST_I2C_SLAVE_ADDR,
                                   std::span{tx}, std::span{rx}),
               "I2C write_then_read to 0x%02x failed",
               CONFIG_TEST_I2C_SLAVE_ADDR);

    printk("[I2C slave_write_read] wrote 0x42, read 0x%02x\n",
           static_cast<unsigned>(rx[0]));
}
