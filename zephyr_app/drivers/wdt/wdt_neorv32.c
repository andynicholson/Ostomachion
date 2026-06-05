/*
 * wdt_neorv32.c — Zephyr watchdog driver for the NEORV32 WDT peripheral
 * Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
 *
 * Device tree compatible: "neorv32,wdt"
 *
 * Hardware overview (NEORV32 v1.11.6):
 *   Base address: 0xFFFB0000
 *   CTRL  (offset 0x00): EN[0], LOCK[1], STRICT[2], RCAUSE[4:3], TIMEOUT[31:8]
 *   RESET (offset 0x04): write WDT_PASSWORD (0x709D1AB3) to feed/reset counter
 *
 * The 24-bit timeout counter increments every CLK/4096 cycles.
 *   Timeout(s) = TIMEOUT_TICKS × 4096 / clock_frequency
 *
 * At 100 MHz:
 *   Minimum: 1 tick × 40.96 µs ≈ 41 µs
 *   Maximum: 0xFFFFFF (16,777,215) × 40.96 µs ≈ 687 seconds
 *
 * This driver supports:
 *   - One channel (channel 0)
 *   - Reset-only mode (WDT has no FIRQ; it always triggers a system reset)
 *   - Optional STRICT mode (hardware reset on wrong password or locked write)
 *
 * The Zephyr WDT callback mechanism is NOT supported because the NEORV32
 * WDT generates a direct hardware reset with no pre-reset IRQ.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(wdt_neorv32, CONFIG_WDT_LOG_LEVEL);

#define DT_DRV_COMPAT neorv32_wdt

/* ── Register offsets ────────────────────────────────────────────────────── */
#define WDT_CTRL  0x00U
#define WDT_RESET 0x04U

/* CTRL register bits */
#define WDT_CTRL_EN           BIT(0)
#define WDT_CTRL_LOCK         BIT(1)
#define WDT_CTRL_STRICT       BIT(2)
#define WDT_CTRL_TIMEOUT_LSB  8U    /* TIMEOUT field: bits [31:8] */

/* Password required in the RESET register to feed the watchdog */
#define WDT_PASSWORD 0x709D1AB3U

/* Maximum 24-bit timeout value */
#define WDT_TIMEOUT_MAX 0x00FFFFFFU

/* Clock prescaler: WDT counter increments at CLK / 4096 */
#define WDT_CLK_PRESCALER 4096U

/* ── Driver config / data ─────────────────────────────────────────────────── */

struct wdt_neorv32_config {
	uintptr_t base;
	uint32_t  clock_frequency;
};

struct wdt_neorv32_data {
	bool     installed;       /* wdt_install_timeout() called */
	uint32_t timeout_ticks;   /* computed 24-bit counter value */
};

/* ── Register accessors ───────────────────────────────────────────────────── */

static inline void wdt_wr(const struct wdt_neorv32_config *cfg,
			   uint32_t off, uint32_t val)
{
	sys_write32(val, cfg->base + off);
}

static inline uint32_t wdt_rd(const struct wdt_neorv32_config *cfg,
			       uint32_t off)
{
	return sys_read32(cfg->base + off);
}

/* ── Zephyr WDT API ───────────────────────────────────────────────────────── */

/**
 * wdt_neorv32_install_timeout() — configure the watchdog timeout.
 *
 * @param dev  WDT device
 * @param cfg  Timeout configuration (only window.max is used; window.min is
 *             ignored because the NEORV32 WDT is an open-window watchdog).
 *             callback must be NULL — the WDT generates a system reset only.
 * @return 0 on success, -ENOTSUP for unsupported modes, -EINVAL for out-of-range
 */
static int wdt_neorv32_install_timeout(const struct device *dev,
				       const struct wdt_timeout_cfg *timeout_cfg)
{
	const struct wdt_neorv32_config *config = dev->config;
	struct wdt_neorv32_data *data = dev->data;

	if (timeout_cfg->callback != NULL) {
		LOG_ERR("WDT callbacks not supported — NEORV32 WDT generates "
			"hardware reset only (no pre-reset IRQ)");
		return -ENOTSUP;
	}

	if (timeout_cfg->window.max == 0U) {
		return -EINVAL;
	}

	/* Convert window.max (ms) → 24-bit counter ticks
	 * ticks = max_ms × clock_frequency / (4096 × 1000)  */
	uint64_t ticks = (uint64_t)timeout_cfg->window.max *
			 (uint64_t)config->clock_frequency /
			 ((uint64_t)WDT_CLK_PRESCALER * 1000U);

	if (ticks == 0) {
		LOG_ERR("Timeout %u ms too short for clock %u Hz",
			timeout_cfg->window.max, config->clock_frequency);
		return -EINVAL;
	}

	if (ticks > WDT_TIMEOUT_MAX) {
		LOG_ERR("Timeout %u ms exceeds maximum %u ms at %u Hz",
			timeout_cfg->window.max,
			(uint32_t)((uint64_t)WDT_TIMEOUT_MAX *
				   WDT_CLK_PRESCALER * 1000U /
				   config->clock_frequency),
			config->clock_frequency);
		return -EINVAL;
	}

	data->timeout_ticks = (uint32_t)ticks;
	data->installed = true;

	LOG_DBG("WDT timeout: %u ms → %u ticks (CLK/4096)",
		timeout_cfg->window.max, data->timeout_ticks);

	return 0;
}

/**
 * wdt_neorv32_setup() — enable the watchdog with the installed timeout.
 *
 * Calling wdt_setup() without a prior wdt_install_timeout() is an error.
 * The STRICT bit is always set so that an incorrect feed password or write
 * to a locked CTRL register triggers an immediate hardware reset.
 *
 * When CONFIG_WDT_NEORV32_LOCK=y the LOCK bit is also set, making the CTRL
 * register immutable until the next hardware reset; wdt_disable() then returns
 * -EPERM.  This is what actually delivers tamper resistance — STRICT alone does
 * not prevent a plain CTRL write of 0 (see wdt_neorv32_disable()).
 *
 * @param dev      WDT device
 * @param options  Pause options (WDT_OPT_PAUSE_* are not supported — ignored)
 * @return 0 on success, -EINVAL if no timeout has been installed
 */
static int wdt_neorv32_setup(const struct device *dev, uint8_t options)
{
	const struct wdt_neorv32_config *config = dev->config;
	struct wdt_neorv32_data *data = dev->data;

	if (!data->installed) {
		LOG_ERR("wdt_install_timeout() must be called before wdt_setup()");
		return -EINVAL;
	}

	/* Build the CTRL word: EN=1, STRICT=1 (reject wrong password / locked
	 * writes), TIMEOUT=data->timeout_ticks.  LOCK is applied separately below. */
	uint32_t ctrl = WDT_CTRL_EN | WDT_CTRL_STRICT |
			(data->timeout_ticks << WDT_CTRL_TIMEOUT_LSB);
	wdt_wr(config, WDT_CTRL, ctrl);

	/* Feed immediately to start the counter from the fresh timeout value */
	wdt_wr(config, WDT_RESET, WDT_PASSWORD);

#ifdef CONFIG_WDT_NEORV32_LOCK
	/* Engage the LOCK bit in a SECOND CTRL write.
	 *
	 * The NEORV32 WDT latches LOCK only if EN is ALREADY set from a prior
	 * write — neorv32_wdt.vhd qualifies it as
	 *   ctrl.lock <= data(lock) and ctrl.enable;  -- "lock only if already enabled"
	 * so writing EN and LOCK in the same word (as an earlier version did) leaves
	 * LOCK=0 because ctrl.enable is still 0 at that edge.  The first write above
	 * sets EN; this write re-sends the full config with LOCK added, and because
	 * EN is now already 1 the hardware latches LOCK.  After this, CTRL is
	 * immutable until the next hardware reset and wdt_disable() returns -EPERM.
	 * The write targets CTRL while still unlocked, so STRICT does not trip a
	 * reset on it. */
	wdt_wr(config, WDT_CTRL, ctrl | WDT_CTRL_LOCK);
#endif

	LOG_INF("WDT enabled: timeout_ticks=%u (%.1f s at %u Hz)",
		data->timeout_ticks,
		(double)data->timeout_ticks * WDT_CLK_PRESCALER /
			(double)config->clock_frequency,
		config->clock_frequency);
	return 0;
}

/**
 * wdt_neorv32_disable() — disable the watchdog.
 *
 * If the WDT CTRL register has been locked (via the LOCK bit), this function
 * will fail and the WDT cannot be disabled until the next hardware reset.
 * In that case STRICT mode triggers an immediate reset on any lock violation.
 *
 * @return 0 on success, -EPERM if the WDT is locked
 */
static int wdt_neorv32_disable(const struct device *dev)
{
	const struct wdt_neorv32_config *config = dev->config;
	struct wdt_neorv32_data *data = dev->data;

	uint32_t ctrl = wdt_rd(config, WDT_CTRL);
	if (ctrl & WDT_CTRL_LOCK) {
		LOG_ERR("WDT CTRL is locked — cannot disable until hardware reset");
		return -EPERM;
	}

	/* Clear EN to stop the watchdog counter */
	wdt_wr(config, WDT_CTRL, 0U);
	data->installed = false;

	/* Verify that the WDT is actually disabled */
	if (wdt_rd(config, WDT_CTRL) & WDT_CTRL_EN) {
		LOG_ERR("WDT disable failed — EN bit still set");
		return -EIO;
	}

	LOG_INF("WDT disabled");
	return 0;
}

/**
 * wdt_neorv32_feed() — reset the watchdog counter.
 *
 * @param dev        WDT device
 * @param channel_id Must be 0 (only one channel is supported)
 * @return 0 on success, -EINVAL for invalid channel
 */
static int wdt_neorv32_feed(const struct device *dev, int channel_id)
{
	const struct wdt_neorv32_config *config = dev->config;

	if (channel_id != 0) {
		return -EINVAL;
	}

	wdt_wr(config, WDT_RESET, WDT_PASSWORD);
	return 0;
}

/* ── Device instantiation ─────────────────────────────────────────────────── */

static const struct wdt_driver_api wdt_neorv32_api = {
	.setup            = wdt_neorv32_setup,
	.disable          = wdt_neorv32_disable,
	.install_timeout  = wdt_neorv32_install_timeout,
	.feed             = wdt_neorv32_feed,
};

static int wdt_neorv32_init(const struct device *dev)
{
	const struct wdt_neorv32_config *config = dev->config;
	struct wdt_neorv32_data *data = dev->data;

	data->installed = false;
	data->timeout_ticks = 0;

	/* Ensure the WDT starts disabled; it will be enabled via wdt_setup(). */
	wdt_wr(config, WDT_CTRL, 0U);

	LOG_DBG("WDT initialised at 0x%08x, clock %u Hz",
		(unsigned)config->base, config->clock_frequency);
	return 0;
}

#define WDT_NEORV32_DEFINE(inst)					\
	static struct wdt_neorv32_data wdt_neorv32_data_##inst;		\
									\
	static const struct wdt_neorv32_config wdt_neorv32_cfg_##inst = {	\
		.base             = DT_INST_REG_ADDR(inst),		\
		.clock_frequency  = DT_INST_PROP(inst, clock_frequency),	\
	};								\
									\
	DEVICE_DT_INST_DEFINE(inst,					\
			      wdt_neorv32_init,				\
			      NULL,					\
			      &wdt_neorv32_data_##inst,			\
			      &wdt_neorv32_cfg_##inst,			\
			      PRE_KERNEL_1,				\
			      CONFIG_KERNEL_INIT_PRIORITY_DEVICE,	\
			      &wdt_neorv32_api);

DT_INST_FOREACH_STATUS_OKAY(WDT_NEORV32_DEFINE)
