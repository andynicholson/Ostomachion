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
		gpio_pin_configure_dt(&spec_, GPIO_OUTPUT_ACTIVE);
	}

	void toggle() { gpio_pin_toggle_dt(&spec_); }

private:
	gpio_dt_spec spec_;
};

int run_spi_loopback_test()
{
	const struct device *spi = DEVICE_DT_GET(DT_NODELABEL(spi0));

	if (!device_is_ready(spi)) {
		printk("[FAIL] SPI device not ready\n");
		return -1;
	}

	struct spi_config spi_cfg = {
		.frequency = 1'000'000,
		.operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
		.slave = 0,
	};

	uint8_t tx = 0xA5;
	uint8_t rx = 0;

	struct spi_buf tx_buf = {.buf = &tx, .len = sizeof(tx)};
	struct spi_buf rx_buf = {.buf = &rx, .len = sizeof(rx)};

	const struct spi_buf_set tx_bufs = {.buffers = &tx_buf, .count = 1};
	const struct spi_buf_set rx_bufs = {.buffers = &rx_buf, .count = 1};

	int ret = spi_transceive(spi, &spi_cfg, &tx_bufs, &rx_bufs);

	if (ret != 0) {
		printk("[FAIL] SPI transceive: err=%d\n", ret);
		return ret;
	}

	if (rx == tx) {
		printk("[PASS] SPI loopback: sent 0x%02x, received 0x%02x\n", tx, rx);
		return 0;
	}

	printk("[FAIL] SPI loopback: sent 0x%02x, received 0x%02x\n", tx, rx);
	return -1;
}

/*
 * I2C write-read test against the GHDL testbench slave at address 0x50.
 * Write 1 byte (0x42), then read 1 byte and expect 0x5A (I2C_RD_BYTE in TB).
 */
int run_i2c_loopback_test()
{
	const struct device *i2c = DEVICE_DT_GET(DT_NODELABEL(i2c0));

	if (!device_is_ready(i2c)) {
		printk("[FAIL] I2C device not ready\n");
		return -1;
	}

	static const uint16_t slave_addr = 0x50U;

	uint8_t tx_data = 0x42U;
	uint8_t rx_data = 0x00U;

	int ret = i2c_write_read(i2c, slave_addr, &tx_data, sizeof(tx_data), &rx_data,
				 sizeof(rx_data));

	if (ret != 0) {
		printk("[FAIL] I2C write_read: err=%d\n", ret);
		return ret;
	}

	if (rx_data == 0x5AU) {
		printk("[PASS] I2C loopback: wrote 0x%02x, received 0x%02x\n", tx_data, rx_data);
		return 0;
	}

	printk("[FAIL] I2C loopback: wrote 0x%02x, received 0x%02x (want 0x5a)\n", tx_data,
	       rx_data);
	return -1;
}

} // namespace

int main()
{
	static const gpio_dt_spec led0 = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

	LedController led(led0);

	(void)run_spi_loopback_test();
	(void)run_i2c_loopback_test();

	printk("NEORV32 + Zephyr + C++20 Booted!\n");

	while (true) {
		led.toggle();
		k_msleep(500);
	}
}
