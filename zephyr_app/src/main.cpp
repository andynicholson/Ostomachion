/*
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
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

} // namespace

int main()
{
	static const gpio_dt_spec led0 = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

	LedController led(led0);

	(void)run_spi_loopback_test();

	printk("NEORV32 + Zephyr + C++20 Booted!\n");

	while (true) {
		led.toggle();
		k_msleep(500);
	}
}
