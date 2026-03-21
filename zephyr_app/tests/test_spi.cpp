// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// SPI loopback test suite for Ostomachion.
//
// The GHDL testbench wires MOSI directly to MISO, so every transmitted byte
// must be received back unchanged.  Tests exercise:
//   - Boundary values: all-zeros (0x00) and all-ones (0xFF)
//   - Mid-range pattern: 0xA5 (alternating bits)
//   - Multi-byte: 4-byte buffer to exercise the spi_context update loop

#include <zephyr/ztest.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/spi.h>

#include <array>
#include <cstddef>

#include "ostomachion/hal/spi.hpp"

static const spi_config k_spi_cfg = {
    .frequency = 1'000'000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
    .slave     = 0,
};

// Helper: construct a SpiDevice bound to spi0 with the default config.
static ostomachion::hal::SpiDevice make_spi()
{
    return ostomachion::hal::SpiDevice{
        DEVICE_DT_GET(DT_NODELABEL(spi0)), k_spi_cfg};
}

ZTEST_SUITE(ostomachion_spi, NULL, NULL, NULL, NULL, NULL);

ZTEST(ostomachion_spi, test_loopback_zero)
{
    auto spi = make_spi();
    std::array<std::byte, 1> tx{std::byte{0x00}};
    std::array<std::byte, 1> rx{std::byte{0xFF}}; // pre-fill inverse to detect non-writes

    zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
               "SPI transfer failed");
    zassert_equal(rx[0], tx[0],
                  "SPI 0x00 loopback: expected 0x00, got 0x%02x",
                  static_cast<unsigned>(rx[0]));
}

ZTEST(ostomachion_spi, test_loopback_ff)
{
    auto spi = make_spi();
    std::array<std::byte, 1> tx{std::byte{0xFF}};
    std::array<std::byte, 1> rx{std::byte{0x00}};

    zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
               "SPI transfer failed");
    zassert_equal(rx[0], tx[0],
                  "SPI 0xFF loopback: expected 0xFF, got 0x%02x",
                  static_cast<unsigned>(rx[0]));
}

ZTEST(ostomachion_spi, test_loopback_a5)
{
    auto spi = make_spi();
    std::array<std::byte, 1> tx{std::byte{0xA5}};
    std::array<std::byte, 1> rx{std::byte{0x00}};

    zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
               "SPI transfer failed");
    zassert_equal(rx[0], tx[0],
                  "SPI 0xA5 loopback: expected 0xA5, got 0x%02x",
                  static_cast<unsigned>(rx[0]));
}

ZTEST(ostomachion_spi, test_multibyte)
{
    auto spi = make_spi();
    std::array<std::byte, 4> tx{
        std::byte{0x11}, std::byte{0x22}, std::byte{0x33}, std::byte{0x44}};
    std::array<std::byte, 4> rx{};

    zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
               "SPI multi-byte transfer failed");
    for (std::size_t i = 0; i < tx.size(); i++) {
        zassert_equal(rx[i], tx[i],
                      "SPI multi-byte [%zu]: expected 0x%02x, got 0x%02x",
                      i,
                      static_cast<unsigned>(tx[i]),
                      static_cast<unsigned>(rx[i]));
    }
}
