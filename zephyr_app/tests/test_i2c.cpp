// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// I2C test suite for Ostomachion.
//
// The GHDL testbench provides an I2C slave at 7-bit address 0x50 that:
//   - ACKs address 0x50 for both reads and writes
//   - Write: ACKs every data byte (logging each to the console)
//   - Read:  returns 0x5A per byte; continues while master ACKs, stops on NACK
//
// Tests cover:
//   1. write_then_read: write 0x42, read 1 byte -> expect 0x5A
//   2. multibyte_write: 3-byte write -> exercises the write-data loop
//   3. multibyte_read:  2-byte read  -> exercises the MACK path (ACK + NACK)

#include <zephyr/ztest.h>
#include <zephyr/devicetree.h>

#include <array>
#include <cstddef>

#include "ostomachion/hal/i2c.hpp"

static constexpr uint16_t  k_slave_addr = 0x50U;
static constexpr std::byte k_rd_byte{0x5A};

ZTEST_SUITE(ostomachion_i2c, NULL, NULL, NULL, NULL, NULL);

ZTEST(ostomachion_i2c, test_write_read)
{
    ostomachion::hal::I2cBus i2c{DEVICE_DT_GET(DT_NODELABEL(i2c0))};

    std::array<std::byte, 1> tx{std::byte{0x42}};
    std::array<std::byte, 1> rx{std::byte{0x00}};

    zassert_ok(i2c.write_then_read(k_slave_addr, tx, rx),
               "I2C write_then_read failed");
    zassert_equal(rx[0], k_rd_byte,
                  "I2C read: expected 0x5A, got 0x%02x",
                  static_cast<unsigned>(rx[0]));
}

ZTEST(ostomachion_i2c, test_multibyte_write)
{
    ostomachion::hal::I2cBus i2c{DEVICE_DT_GET(DT_NODELABEL(i2c0))};

    const std::array<std::byte, 3> tx{
        std::byte{0x01}, std::byte{0x02}, std::byte{0x03}};

    zassert_ok(i2c.write(k_slave_addr, tx),
               "I2C 3-byte write failed");
}

ZTEST(ostomachion_i2c, test_multibyte_read)
{
    ostomachion::hal::I2cBus i2c{DEVICE_DT_GET(DT_NODELABEL(i2c0))};

    std::array<std::byte, 2> rx{std::byte{0x00}, std::byte{0x00}};

    zassert_ok(i2c.read(k_slave_addr, rx),
               "I2C 2-byte read failed");
    zassert_equal(rx[0], k_rd_byte,
                  "I2C read byte[0]: expected 0x5A, got 0x%02x",
                  static_cast<unsigned>(rx[0]));
    zassert_equal(rx[1], k_rd_byte,
                  "I2C read byte[1]: expected 0x5A, got 0x%02x",
                  static_cast<unsigned>(rx[1]));
}
