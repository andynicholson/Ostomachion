/*
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/kernel.h>

#include <cstdint>

namespace {

class LedController {
public:
	explicit LedController(const gpio_dt_spec &spec) : spec_(spec)
	{
		int ret = gpio_pin_configure_dt(&spec_, GPIO_OUTPUT_ACTIVE);

		if (ret < 0) {
			printk("[FAIL] LED GPIO configure error: %d\n", ret);
			k_panic();
		}
	}

	void toggle() { gpio_pin_toggle_dt(&spec_); }

private:
	gpio_dt_spec spec_;
};

/*
 * SPI loopback test suite.
 *
 * The testbench wires MOSI directly to MISO, so every transmitted byte should
 * be received back unchanged.  Tests cover:
 *   1. Single byte – all-zeros edge case (0x00)
 *   2. Single byte – all-ones edge case  (0xFF)
 *   3. Single byte – mid-range pattern   (0xA5)
 *   4. Multi-byte  – 4-byte buffer to exercise the spi_context update loop
 *
 * Returns the number of sub-tests that passed.
 */
int run_spi_loopback_test()
{
	const struct device *spi = DEVICE_DT_GET(DT_NODELABEL(spi0));

	if (!device_is_ready(spi)) {
		printk("[FAIL] SPI device not ready\n");
		return 0;
	}

	struct spi_config spi_cfg = {
		.frequency = 1'000'000,
		.operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
		.slave = 0,
	};

	int passed = 0;

	/* --- Sub-test: single-byte transfers --- */
	static const uint8_t single_bytes[] = {0x00U, 0xFFU, 0xA5U};

	for (uint8_t tx : single_bytes) {
		uint8_t rx = ~tx; /* pre-fill with inverse to detect non-writes */

		struct spi_buf tx_buf = {.buf = const_cast<uint8_t *>(&tx), .len = 1U};
		struct spi_buf rx_buf = {.buf = &rx, .len = 1U};
		const struct spi_buf_set tx_set = {.buffers = &tx_buf, .count = 1U};
		const struct spi_buf_set rx_set = {.buffers = &rx_buf, .count = 1U};

		int ret = spi_transceive(spi, &spi_cfg, &tx_set, &rx_set);

		if (ret != 0) {
			printk("[FAIL] SPI transceive(0x%02x): err=%d\n", tx, ret);
		} else if (rx == tx) {
			printk("[PASS] SPI loopback byte 0x%02x\n", tx);
			passed++;
		} else {
			printk("[FAIL] SPI loopback byte: sent 0x%02x, got 0x%02x\n", tx, rx);
		}
	}

	/* --- Sub-test: 4-byte multi-byte transfer --- */
	{
		static const uint8_t tx4[] = {0x11U, 0x22U, 0x33U, 0x44U};
		uint8_t rx4[sizeof(tx4)] = {};

		struct spi_buf tx_buf = {.buf = const_cast<uint8_t *>(tx4), .len = sizeof(tx4)};
		struct spi_buf rx_buf = {.buf = rx4, .len = sizeof(rx4)};
		const struct spi_buf_set tx_set = {.buffers = &tx_buf, .count = 1U};
		const struct spi_buf_set rx_set = {.buffers = &rx_buf, .count = 1U};

		int ret = spi_transceive(spi, &spi_cfg, &tx_set, &rx_set);
		bool ok = (ret == 0);

		for (size_t i = 0U; ok && i < sizeof(tx4); i++) {
			ok = (rx4[i] == tx4[i]);
		}

		if (ret != 0) {
			printk("[FAIL] SPI multi-byte transceive: err=%d\n", ret);
		} else if (ok) {
			printk("[PASS] SPI multi-byte loopback (4 bytes)\n");
			passed++;
		} else {
			printk("[FAIL] SPI multi-byte loopback mismatch\n");
			for (size_t i = 0U; i < sizeof(tx4); i++) {
				printk("  [%u] tx=0x%02x rx=0x%02x\n",
				       (unsigned)i, tx4[i], rx4[i]);
			}
		}
	}

	return passed;
}

/*
 * I2C test suite against the GHDL testbench slave at address 0x50.
 *
 * The testbench slave:
 *   - ACKs address 0x50 for both reads and writes.
 *   - Write: ACKs every data byte and logs it.
 *   - Read:  returns I2C_RD_BYTE (0x5A) per byte; continues as long as the
 *            master sends ACK, stops on master NACK.
 *
 * Tests cover:
 *   1. Write-read: write 1 byte (0x42), read 1 byte → expect 0x5A
 *   2. Multi-byte write: write 3 bytes to exercise the write-data loop
 *   3. Multi-byte read:  read 2 bytes to exercise the MACK path (first byte
 *      gets master ACK, second gets master NACK) → expect both 0x5A
 *
 * Returns the number of sub-tests that passed.
 */
int run_i2c_loopback_test()
{
	const struct device *i2c = DEVICE_DT_GET(DT_NODELABEL(i2c0));

	if (!device_is_ready(i2c)) {
		printk("[FAIL] I2C device not ready\n");
		return 0;
	}

	static const uint16_t slave_addr = 0x50U;
	int passed = 0;

	/* --- Sub-test 1: single write-read (i2c_write_read) --- */
	{
		uint8_t tx = 0x42U;
		uint8_t rx = 0x00U;

		int ret = i2c_write_read(i2c, slave_addr, &tx, sizeof(tx), &rx, sizeof(rx));

		if (ret != 0) {
			printk("[FAIL] I2C write_read: err=%d\n", ret);
		} else if (rx == 0x5AU) {
			printk("[PASS] I2C write-read: wrote 0x%02x, received 0x%02x\n", tx, rx);
			passed++;
		} else {
			printk("[FAIL] I2C write-read: wrote 0x%02x, got 0x%02x (want 0x5a)\n",
			       tx, rx);
		}
	}

	/* --- Sub-test 2: multi-byte write (3 bytes) --- */
	{
		static const uint8_t tx3[] = {0x01U, 0x02U, 0x03U};
		int ret = i2c_write(i2c, tx3, sizeof(tx3), slave_addr);

		if (ret != 0) {
			printk("[FAIL] I2C 3-byte write: err=%d\n", ret);
		} else {
			printk("[PASS] I2C 3-byte write acknowledged\n");
			passed++;
		}
	}

	/* --- Sub-test 3: multi-byte read (2 bytes, exercises MACK path) --- */
	{
		uint8_t rx2[2] = {0x00U, 0x00U};
		int ret = i2c_read(i2c, rx2, sizeof(rx2), slave_addr);

		if (ret != 0) {
			printk("[FAIL] I2C 2-byte read: err=%d\n", ret);
		} else if (rx2[0] == 0x5AU && rx2[1] == 0x5AU) {
			printk("[PASS] I2C 2-byte read: 0x%02x 0x%02x\n", rx2[0], rx2[1]);
			passed++;
		} else {
			printk("[FAIL] I2C 2-byte read: got 0x%02x 0x%02x (want 0x5a 0x5a)\n",
			       rx2[0], rx2[1]);
		}
	}

	return passed;
}

} // namespace

int main()
{
	static const gpio_dt_spec led0 = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

	LedController led(led0);

	int spi_passed = run_spi_loopback_test();
	int i2c_passed = run_i2c_loopback_test();

	int total_passed = spi_passed + i2c_passed;
	/* 4 SPI sub-tests + 3 I2C sub-tests */
	static constexpr int total_tests = 7;
	int total_failed = total_tests - total_passed;

	if (total_failed == 0) {
		printk("[SUMMARY] ALL %d TESTS PASSED\n", total_tests);
	} else {
		printk("[SUMMARY] %d/%d TESTS FAILED\n", total_failed, total_tests);
	}

	printk("NEORV32 + Zephyr + C++20 Booted!\n");

	while (true) {
		led.toggle();
		k_msleep(500);
	}
}
