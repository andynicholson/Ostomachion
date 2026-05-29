/*
 * test_runner.c — Zephyr shell "test" command
 * Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
 *
 * Interactive test runner for the development / shell firmware image
 * (prj_shell.conf).  Tests are standalone functions — no ZTEST macros —
 * so they can be invoked individually from the shell prompt.
 *
 * Shell session examples:
 *   uart:~$ test run spi
 *   [TEST] loopback_boundary ... PASS
 *   [TEST] multibyte_loopback ... PASS
 *   [TEST] stress_16           ... PASS
 *   [TEST] spi: 3 passed, 0 failed
 *
 *   uart:~$ test run all
 *   [TEST] spi: 3/3  i2c: 2/2  gpio: 2/2  fft: 2/2
 */

#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/sys_io.h>
#if defined(CONFIG_FFT_ACCEL)
#include <zephyr/drivers/misc/fft_accel.h>
#endif

#include <string.h>
#include <stdint.h>
#include <math.h>

/* ── Result tracking helpers ─────────────────────────────────────────────── */

struct test_result {
	int passed;
	int failed;
};

#define TEST_RUN(sh, res, name, fn)                                \
	do {                                                           \
		int _rc = (fn);                                            \
		if (_rc == 0) {                                            \
			(res)->passed++;                                       \
			shell_print(sh, "[TEST] %-28s PASS", (name));         \
		} else {                                                   \
			(res)->failed++;                                       \
			shell_print(sh, "[TEST] %-28s FAIL (err %d)",         \
				    (name), _rc);                                  \
		}                                                          \
	} while (0)

/* ── SPI tests ───────────────────────────────────────────────────────────── */

static int spi_test_loopback_boundary(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(spi0));
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}

	static const struct spi_config cfg = {
		.frequency = 1000000,
		.operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) |
			     SPI_TRANSFER_MSB,
	};

	uint8_t tx_buf[2] = {0x00, 0xFF};
	uint8_t rx_buf[2] = {0x55, 0x55};
	struct spi_buf tx = {.buf = tx_buf, .len = 2};
	struct spi_buf rx = {.buf = rx_buf, .len = 2};
	struct spi_buf_set txs = {.buffers = &tx, .count = 1};
	struct spi_buf_set rxs = {.buffers = &rx, .count = 1};

	int rc = spi_transceive(dev, &cfg, &txs, &rxs);
	if (rc != 0) {
		return rc;
	}
	/* In loopback: rx should mirror tx */
	return (rx_buf[0] == 0x00 && rx_buf[1] == 0xFF) ? 0 : -EIO;
}

static int spi_test_multibyte(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(spi0));
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}

	static const struct spi_config cfg = {
		.frequency = 1000000,
		.operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) |
			     SPI_TRANSFER_MSB,
	};

	uint8_t tx_buf[8] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08};
	uint8_t rx_buf[8];
	struct spi_buf tx = {.buf = tx_buf, .len = 8};
	struct spi_buf rx = {.buf = rx_buf, .len = 8};
	struct spi_buf_set txs = {.buffers = &tx, .count = 1};
	struct spi_buf_set rxs = {.buffers = &rx, .count = 1};

	int rc = spi_transceive(dev, &cfg, &txs, &rxs);
	if (rc != 0) {
		return rc;
	}
	return (memcmp(tx_buf, rx_buf, 8) == 0) ? 0 : -EIO;
}

static int spi_test_stress(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(spi0));
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}

	static const struct spi_config cfg = {
		.frequency = 1000000,
		.operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) |
			     SPI_TRANSFER_MSB,
	};

	for (int i = 0; i < 16; i++) {
		uint8_t tx_buf = (uint8_t)i;
		uint8_t rx_buf = 0x55;
		struct spi_buf tx = {.buf = &tx_buf, .len = 1};
		struct spi_buf rx = {.buf = &rx_buf, .len = 1};
		struct spi_buf_set txs = {.buffers = &tx, .count = 1};
		struct spi_buf_set rxs = {.buffers = &rx, .count = 1};

		int rc = spi_transceive(dev, &cfg, &txs, &rxs);
		if (rc != 0 || rx_buf != tx_buf) {
			return -EIO;
		}
	}
	return 0;
}

/* ── I2C tests ───────────────────────────────────────────────────────────── */

static int i2c_test_no_ack(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(i2c0));
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}
	/* Address 0x7F is reserved / typically unpopulated — expect slave NACK.
	 * The driver reports -ENXIO on address-phase NACK (aligned with ZTEST
	 * test_nack_nonexistent which asserts exactly -ENXIO). */
	uint8_t buf = 0;
	int rc = i2c_write(dev, &buf, 1, 0x7F);
	return (rc == -ENXIO) ? 0 : -EBADE;
}

static int i2c_test_nack_recovery(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(i2c0));
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}
	uint8_t buf = 0;
	/* Five consecutive NACKs — matches ZTEST test_nack_repeated coverage.
	 * Each attempt must return -ENXIO; the driver must not corrupt state. */
	for (int i = 0; i < 5; i++) {
		int rc = i2c_write(dev, &buf, 1, 0x7F);
		if (rc != -ENXIO) {
			return -EBADE;
		}
	}
	return 0;
}

/* ── GPIO / LED tests ─────────────────────────────────────────────────────── */

static const struct gpio_dt_spec k_leds[] = {
	GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios),
	GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios),
	GPIO_DT_SPEC_GET(DT_ALIAS(led2), gpios),
	GPIO_DT_SPEC_GET(DT_ALIAS(led3), gpios),
};

static int gpio_test_configure(void)
{
	for (int i = 0; i < ARRAY_SIZE(k_leds); i++) {
		if (!gpio_is_ready_dt(&k_leds[i])) {
			return -ENODEV;
		}
		int rc = gpio_pin_configure_dt(&k_leds[i], GPIO_OUTPUT_INACTIVE);
		if (rc != 0) {
			return rc;
		}
	}
	return 0;
}

static int gpio_test_set_clear(void)
{
	for (int i = 0; i < ARRAY_SIZE(k_leds); i++) {
		int rc = gpio_pin_set_dt(&k_leds[i], 1);
		if (rc != 0) {
			return rc;
		}
	}
	for (int i = 0; i < ARRAY_SIZE(k_leds); i++) {
		int rc = gpio_pin_set_dt(&k_leds[i], 0);
		if (rc != 0) {
			return rc;
		}
	}
	return 0;
}

/* ── FFT tests (shell path) ──────────────────────────────────────────────── */

#if defined(CONFIG_FFT_ACCEL)

/* int64_t avoids overflow when re = im = INT16_MIN: (int32_t)(-32768)^2 * 2
 * would overflow int32_t. */
static int64_t _mag_sq(int16_t re, int16_t im)
{
	return (int64_t)re * re + (int64_t)im * im;
}

#define FFT_N 4096

/* Reuse the buffers already allocated in fft_shell.c to avoid a second
 * 32 KB BSS footprint for the same shell firmware image. */
extern struct fft_sample_t g_fft_in[FFT_N];
extern struct fft_sample_t g_fft_out[FFT_N];

static int fft_test_dc_response(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}

	for (int i = 0; i < FFT_N; i++) {
		g_fft_in[i].re = 16384;
		g_fft_in[i].im = 0;
	}

	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, FFT_N);
	if (rc != 0) {
		return rc;
	}

	int64_t bin0 = _mag_sq(g_fft_out[0].re, g_fft_out[0].im);
	for (int k = 1; k < FFT_N; k++) {
		if (_mag_sq(g_fft_out[k].re, g_fft_out[k].im) >= bin0) {
			return -EIO;
		}
	}
	return 0;
}

static int fft_test_single_tone(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}

	/* Real cosine at bin 8: x[k] = 0.5 * cos(2π·8·k/4096), im = 0.
	 * A real cosine produces symmetric peaks at bin 8 AND its mirror
	 * bin 4088 (= 4096 - 8); the peak detector must accept either. */
	const int target = 8;
	for (int k = 0; k < FFT_N; k++) {
		float angle = 2.0f * 3.14159265f * (float)target * k / (float)FFT_N;
		g_fft_in[k].re = (int16_t)(16384.0f * cosf(angle));
		g_fft_in[k].im = 0;
	}

	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, FFT_N);
	if (rc != 0) {
		return rc;
	}

	int peak_bin = 0;
	int64_t peak = 0;
	for (int k = 0; k < FFT_N; k++) {
		int64_t m = _mag_sq(g_fft_out[k].re, g_fft_out[k].im);
		if (m > peak) {
			peak = m;
			peak_bin = k;
		}
	}
	/* Accept bin 8 (±1) or its mirror bin 4088 (±1) */
	bool ok = ((peak_bin >= 7 && peak_bin <= 9) ||
		   (peak_bin >= 4087 && peak_bin <= 4089));
	return ok ? 0 : -EIO;
}

#endif /* CONFIG_FFT_ACCEL */

/* ── Suite runners ───────────────────────────────────────────────────────── */

static void run_spi(const struct shell *sh, struct test_result *r)
{
	TEST_RUN(sh, r, "spi_loopback_boundary", spi_test_loopback_boundary());
	TEST_RUN(sh, r, "spi_multibyte_loopback", spi_test_multibyte());
	TEST_RUN(sh, r, "spi_stress_16",          spi_test_stress());
	shell_print(sh, "[TEST] spi: %d passed, %d failed", r->passed, r->failed);
}

static void run_i2c(const struct shell *sh, struct test_result *r)
{
	TEST_RUN(sh, r, "i2c_no_ack",            i2c_test_no_ack());
	TEST_RUN(sh, r, "i2c_nack_recovery",     i2c_test_nack_recovery());
	shell_print(sh, "[TEST] i2c: %d passed, %d failed", r->passed, r->failed);
}

static void run_gpio(const struct shell *sh, struct test_result *r)
{
	TEST_RUN(sh, r, "gpio_configure",  gpio_test_configure());
	TEST_RUN(sh, r, "gpio_set_clear",  gpio_test_set_clear());
	shell_print(sh, "[TEST] gpio: %d passed, %d failed", r->passed, r->failed);
}

#if defined(CONFIG_FFT_ACCEL)
static void run_fft(const struct shell *sh, struct test_result *r)
{
	TEST_RUN(sh, r, "fft_dc_response",   fft_test_dc_response());
	TEST_RUN(sh, r, "fft_single_tone",   fft_test_single_tone());
	shell_print(sh, "[TEST] fft: %d passed, %d failed", r->passed, r->failed);
}
#endif /* CONFIG_FFT_ACCEL */

/* ── Shell command handlers ──────────────────────────────────────────────── */

static int cmd_test_run(const struct shell *sh, size_t argc, char **argv)
{
	if (argc < 2) {
#if defined(CONFIG_FFT_ACCEL)
		shell_print(sh, "Usage: test run [spi|i2c|gpio|fft|all]");
#else
		shell_print(sh, "Usage: test run [spi|i2c|gpio|all]");
#endif
		return -EINVAL;
	}

	struct test_result r = {0, 0};
	const char *suite = argv[1];

	if (strcmp(suite, "spi") == 0) {
		run_spi(sh, &r);
	} else if (strcmp(suite, "i2c") == 0) {
		run_i2c(sh, &r);
	} else if (strcmp(suite, "gpio") == 0) {
		run_gpio(sh, &r);
#if defined(CONFIG_FFT_ACCEL)
	} else if (strcmp(suite, "fft") == 0) {
		run_fft(sh, &r);
#endif
	} else if (strcmp(suite, "all") == 0) {
		struct test_result rs = {0, 0}, ri = {0, 0}, rg = {0, 0};
		run_spi(sh, &rs);
		run_i2c(sh, &ri);
		run_gpio(sh, &rg);
#if defined(CONFIG_FFT_ACCEL)
		struct test_result rf = {0, 0};
		run_fft(sh, &rf);
		shell_print(sh,
			    "[TEST] spi: %d/%d  i2c: %d/%d  "
			    "gpio: %d/%d  fft: %d/%d",
			    rs.passed, rs.passed + rs.failed,
			    ri.passed, ri.passed + ri.failed,
			    rg.passed, rg.passed + rg.failed,
			    rf.passed, rf.passed + rf.failed);
#else
		shell_print(sh,
			    "[TEST] spi: %d/%d  i2c: %d/%d  gpio: %d/%d",
			    rs.passed, rs.passed + rs.failed,
			    ri.passed, ri.passed + ri.failed,
			    rg.passed, rg.passed + rg.failed);
#endif
	} else {
		shell_error(sh, "Unknown suite '%s'", suite);
		return -EINVAL;
	}
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(test_sub,
	SHELL_CMD_ARG(run, NULL,
		      "run [spi|i2c|gpio|fft|all]  — run peripheral tests",
		      cmd_test_run, 2, 0),
	SHELL_SUBCMD_SET_END);

SHELL_CMD_REGISTER(test, &test_sub, "Peripheral test runner", NULL);
