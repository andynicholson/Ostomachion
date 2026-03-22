// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// SPI loopback test suite for Ostomachion.
//
// Hardware setup (Arty A7): fit a jumper between Pmod JA pin 2 (MOSI, B11)
// and pin 3 (MISO, A11).  This is the same physical test used for production
// SPI bringup.
//
// Simulation: the GHDL testbench wires MOSI directly to MISO, so all
// loopback assertions hold without any jumper.
//
// The suite-level setup asserts device readiness once; if spi0 is absent or
// misconfigured the entire suite is aborted cleanly rather than panicking
// mid-test.

#include <zephyr/ztest.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/spi.h>

#include <array>
#include <cstddef>

#include "ostomachion/hal/spi.hpp"

// Default config: 1 MHz, 8-bit, MSB-first, CS active-low.
static const spi_config k_spi_cfg = {
    .frequency = 1'000'000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
    .slave     = 0,
};

// 500 kHz variant: verifies CDIV computation for lower speeds.
static const spi_config k_spi_cfg_500k = {
    .frequency = 500'000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
    .slave     = 0,
};

// 4 MHz variant: highest practical speed at 100 MHz NEORV32 clock.
static const spi_config k_spi_cfg_4m = {
    .frequency = 4'000'000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
    .slave     = 0,
};

// CS-hold variant: CS stays asserted between calls until spi_release().
static const spi_config k_spi_cfg_hold = {
    .frequency = 1'000'000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB |
                 SPI_HOLD_ON_CS,
    .slave     = 0,
};

// --- Fixture ---------------------------------------------------------------

struct ostomachion_spi_fixture {
    const struct device *dev;
};

static void *spi_setup(void)
{
    static struct ostomachion_spi_fixture f;
    f.dev = DEVICE_DT_GET(DT_NODELABEL(spi0));
    // Hard-fail the entire suite if the device is missing; prevents
    // individual tests from crashing with an uninitialised device.
    zassert_true(device_is_ready(f.dev),
                 "spi0 not ready — check DTS bindings and driver config");
    return &f;
}

// Best-effort CS release between tests to recover from a test that exits
// with SPI_HOLD_ON_CS still asserted (e.g. after a zassert failure).
static void spi_after(void *f_)
{
    const struct ostomachion_spi_fixture *f =
        static_cast<const struct ostomachion_spi_fixture *>(f_);
    (void)spi_release(f->dev, &k_spi_cfg_hold);
}

ZTEST_SUITE(ostomachion_spi, NULL, spi_setup, NULL, spi_after, NULL);

// --- Tests -----------------------------------------------------------------

ZTEST_F(ostomachion_spi, test_device_ready)
{
    zassert_true(device_is_ready(fixture->dev), "spi0 not ready");
}

// Four boundary patterns covering all-zero, all-one, and alternating bits.
// Exercises single-bit miscount and bit-order bugs simultaneously.
ZTEST_F(ostomachion_spi, test_loopback_boundary)
{
    static const uint8_t patterns[] = {0x00, 0xFF, 0xA5, 0x5A};

    for (std::size_t i = 0; i < ARRAY_SIZE(patterns); i++) {
        ostomachion::hal::SpiDevice spi{fixture->dev, k_spi_cfg};
        std::array<std::byte, 1> tx{static_cast<std::byte>(patterns[i])};
        // Pre-fill RX with the bitwise inverse to catch "no write" bugs.
        std::array<std::byte, 1> rx{static_cast<std::byte>(~patterns[i])};

        zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
                   "SPI transfer failed for pattern 0x%02x", patterns[i]);
        zassert_equal(rx[0], tx[0],
                      "SPI boundary 0x%02x: got 0x%02x",
                      patterns[i], static_cast<unsigned>(rx[0]));
    }
}

// 8-byte buffer: exercises the full spi_context buffer-update loop and any
// off-by-one in the byte-count tracking.
ZTEST_F(ostomachion_spi, test_multibyte_loopback)
{
    ostomachion::hal::SpiDevice spi{fixture->dev, k_spi_cfg};
    std::array<std::byte, 8> tx{
        std::byte{0x11}, std::byte{0x22}, std::byte{0x33}, std::byte{0x44},
        std::byte{0x55}, std::byte{0x66}, std::byte{0x77}, std::byte{0x88},
    };
    std::array<std::byte, 8> rx{};

    zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
               "SPI 8-byte transfer failed");
    for (std::size_t i = 0; i < tx.size(); i++) {
        zassert_equal(rx[i], tx[i],
                      "SPI 8-byte [%zu]: expected 0x%02x, got 0x%02x",
                      i, static_cast<unsigned>(tx[i]),
                      static_cast<unsigned>(rx[i]));
    }
}

// 64 back-to-back single-byte transfers.  Detects state corruption in the
// interrupt-driven path (e.g. ISR clears TX before the next byte is loaded,
// losing a byte).  The counter value is also the TX byte, so stuck-at-N
// errors are immediately visible.
//
// Iteration count is Kconfig-controlled: 16 (default) fits in the GHDL
// simulation window at ~1 ms/transfer; set CONFIG_TEST_SPI_STRESS_COUNT=64
// in prj_hw_test.conf for the full hardware stress test.
ZTEST_F(ostomachion_spi, test_stress_loopback)
{
    ostomachion::hal::SpiDevice spi{fixture->dev, k_spi_cfg};

    for (unsigned i = 0; i < static_cast<unsigned>(CONFIG_TEST_SPI_STRESS_COUNT); i++) {
        const auto pattern = static_cast<std::byte>(i & 0xFFU);
        std::array<std::byte, 1> tx{pattern};
        std::array<std::byte, 1> rx{~pattern};

        zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
                   "SPI stress transfer %u failed", i);
        zassert_equal(rx[0], pattern,
                      "SPI stress[%u]: expected 0x%02x, got 0x%02x",
                      i, static_cast<unsigned>(pattern),
                      static_cast<unsigned>(rx[0]));
    }
}

// HOLD_ON_CS: verify CS stays asserted across two consecutive transfers and
// is de-asserted only after an explicit spi_release() call.  Tests the CS
// state machine in the driver.  Uses the raw Zephyr SPI API directly to
// exercise the SPI_HOLD_ON_CS flag.
ZTEST_F(ostomachion_spi, test_hold_on_cs)
{
    uint8_t tx1_buf = 0xAAU;
    uint8_t rx1_buf = 0x00U;
    uint8_t tx2_buf = 0xBBU;
    uint8_t rx2_buf = 0x00U;

    spi_buf tx_b1 = {.buf = &tx1_buf, .len = 1U};
    spi_buf rx_b1 = {.buf = &rx1_buf, .len = 1U};
    spi_buf tx_b2 = {.buf = &tx2_buf, .len = 1U};
    spi_buf rx_b2 = {.buf = &rx2_buf, .len = 1U};

    const spi_buf_set tx_s1 = {.buffers = &tx_b1, .count = 1U};
    const spi_buf_set rx_s1 = {.buffers = &rx_b1, .count = 1U};
    const spi_buf_set tx_s2 = {.buffers = &tx_b2, .count = 1U};
    const spi_buf_set rx_s2 = {.buffers = &rx_b2, .count = 1U};

    zassert_ok(spi_transceive(fixture->dev, &k_spi_cfg_hold, &tx_s1, &rx_s1),
               "SPI HOLD_ON_CS first transfer failed");
    zassert_equal(rx1_buf, tx1_buf,
                  "SPI HOLD_ON_CS [1]: expected 0xAA, got 0x%02x", rx1_buf);

    zassert_ok(spi_transceive(fixture->dev, &k_spi_cfg_hold, &tx_s2, &rx_s2),
               "SPI HOLD_ON_CS second transfer failed");
    zassert_equal(rx2_buf, tx2_buf,
                  "SPI HOLD_ON_CS [2]: expected 0xBB, got 0x%02x", rx2_buf);

    zassert_ok(spi_release(fixture->dev, &k_spi_cfg_hold),
               "spi_release failed");
}

// 500 kHz transfer: verifies the CDIV prescaler computation for lower speeds.
ZTEST_F(ostomachion_spi, test_frequency_500k)
{
    ostomachion::hal::SpiDevice spi{fixture->dev, k_spi_cfg_500k};
    std::array<std::byte, 2> tx{std::byte{0xC3}, std::byte{0x3C}};
    std::array<std::byte, 2> rx{};

    zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
               "SPI 500 kHz transfer failed");
    zassert_equal(rx[0], tx[0],
                  "SPI 500kHz [0]: expected 0xC3, got 0x%02x",
                  static_cast<unsigned>(rx[0]));
    zassert_equal(rx[1], tx[1],
                  "SPI 500kHz [1]: expected 0x3C, got 0x%02x",
                  static_cast<unsigned>(rx[1]));
}

// 4 MHz transfer: highest practical speed at 100 MHz NEORV32 clock.
ZTEST_F(ostomachion_spi, test_frequency_4m)
{
    ostomachion::hal::SpiDevice spi{fixture->dev, k_spi_cfg_4m};
    std::array<std::byte, 2> tx{std::byte{0xF0}, std::byte{0x0F}};
    std::array<std::byte, 2> rx{};

    zassert_ok(spi.transfer(std::span{tx}, std::span{rx}),
               "SPI 4 MHz transfer failed");
    zassert_equal(rx[0], tx[0],
                  "SPI 4MHz [0]: expected 0xF0, got 0x%02x",
                  static_cast<unsigned>(rx[0]));
    zassert_equal(rx[1], tx[1],
                  "SPI 4MHz [1]: expected 0x0F, got 0x%02x",
                  static_cast<unsigned>(rx[1]));
}
