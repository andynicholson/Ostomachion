/*
 * Copyright (c) 2026
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * NEORV32 SPI master driver.
 *
 * Two transfer paths are compiled in, selected by Kconfig:
 *
 *   CONFIG_SPI_NEORV32_INTERRUPT=n  (default)
 *     Polling path: spins on SPI_CTRL_BUSY between every byte.
 *     Simple, works with no DTS interrupts node.  Blocks the Zephyr
 *     scheduler for the duration of the transfer.
 *
 *   CONFIG_SPI_NEORV32_INTERRUPT=y
 *     Interrupt-driven path: kicks off the first byte, then blocks on
 *     ctx->sync semaphore.  The ISR feeds subsequent bytes and calls
 *     spi_context_complete() when all bytes have been transferred,
 *     releasing the calling thread.  Other Zephyr threads run freely
 *     while the SPI engine is clocking data.
 *
 * Interrupt source: SPI_CTRL_IRQ_RX_AVAIL (CTRL bit 20).
 * The NEORV32 SPI FIRQ fires once per received byte (after each RTX
 * transaction completes and a byte appears in the RX FIFO).
 */

#define DT_DRV_COMPAT neorv32_spi

#define LOG_LEVEL CONFIG_SPI_LOG_LEVEL
#include <zephyr/logging/log.h>
LOG_MODULE_REGISTER(spi_neorv32);

#include <errno.h>
#include <stdint.h>

#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/syscon.h>
#include <zephyr/sys/sys_io.h>

#include "spi_context.h"

#include "../neorv32_regs.h"

/* Register map (see NEORV32 sw/lib/include/neorv32_spi.h) */
#define NEORV32_SPI_CTRL 0x00U
#define NEORV32_SPI_DATA 0x04U

#define SPI_CTRL_EN          BIT(0)
#define SPI_CTRL_CPHA        BIT(1)
#define SPI_CTRL_CPOL        BIT(2)
#define SPI_CTRL_TX_FULL     BIT(19)
#define SPI_CTRL_IRQ_RX_AVAIL BIT(20) /* enable FIRQ on RX-FIFO-not-empty */
#define SPI_CTRL_BUSY        BIT(31)
#define SPI_DATA_CMD         BIT(31)
#define SPI_DATA_CSEN        BIT(3)

#define SPI_POLL_RETRIES NEORV32_POLL_RETRIES

/* NEORV32 SPI supports up to 8 hardware chip-select lines (CS0..CS7). */
#define SPI_MAX_CS 7U

struct neorv32_spi_config {
	mm_reg_t base;
	const struct device *syscon;
#ifdef CONFIG_SPI_NEORV32_INTERRUPT
	void (*irq_config_func)(void);
#endif
};

struct neorv32_spi_data {
	struct spi_context ctx;
};

static const uint16_t prsc_lut[8] = {2, 4, 8, 64, 128, 1024, 2048, 4096};

static inline uint32_t neorv32_spi_reg_read(const struct device *dev, uint32_t reg)
{
	const struct neorv32_spi_config *cfg = dev->config;

	return sys_read32(cfg->base + reg);
}

static inline void neorv32_spi_reg_write(const struct device *dev, uint32_t reg, uint32_t val)
{
	const struct neorv32_spi_config *cfg = dev->config;

	sys_write32(val, cfg->base + reg);
}

static int neorv32_spi_get_clock_hz(const struct device *dev, uint32_t *clk_hz)
{
	const struct neorv32_spi_config *cfg = dev->config;

	return syscon_read_reg(cfg->syscon, NEORV32_SYSINFO_CLK, clk_hz);
}

static int neorv32_spi_compute_ctrl(const struct device *dev, uint32_t frequency,
				    uint16_t operation, uint32_t *ctrl_out)
{
	uint32_t clk_hz;
	uint32_t best = 0U;
	uint32_t best_prsc = 0U;
	uint32_t best_cdiv = 0U;
	bool highspeed = false;
	int err;

	if (SPI_OP_MODE_GET(operation) != SPI_OP_MODE_MASTER) {
		return -ENOTSUP;
	}

	if (SPI_WORD_SIZE_GET(operation) != 8) {
		return -ENOTSUP;
	}

	if ((operation & SPI_LINES_MASK) != SPI_LINES_SINGLE) {
		return -ENOTSUP;
	}

	if ((operation & SPI_HALF_DUPLEX) != 0) {
		return -ENOTSUP;
	}

	if ((operation & SPI_TRANSFER_LSB) != 0) {
		return -ENOTSUP;
	}

	err = neorv32_spi_get_clock_hz(dev, &clk_hz);
	if (err < 0) {
		return err;
	}

	for (uint32_t prsc = 0U; prsc < 8U; prsc++) {
		for (uint32_t cdiv = 0U; cdiv < 16U; cdiv++) {
			uint32_t div = 2U * prsc_lut[prsc] * (1U + cdiv);
			uint32_t f = clk_hz / div;

			if (f > frequency) {
				continue;
			}
			if (f > best) {
				best = f;
				best_prsc = prsc;
				best_cdiv = cdiv;
				highspeed = false;
			}
		}
	}

	/* High-speed mode: bypass prescaler (effective divisor = 2*(1+cdiv)) */
	for (uint32_t cdiv = 0U; cdiv < 16U; cdiv++) {
		uint32_t div = 2U * 1U * (1U + cdiv);
		uint32_t f = clk_hz / div;

		if (f > frequency) {
			continue;
		}
		if (f > best) {
			best = f;
			best_prsc = 0U;
			best_cdiv = cdiv;
			highspeed = true;
		}
	}

	if (best == 0U) {
		LOG_ERR("cannot achieve SPI frequency <= %u Hz (cpu_clk=%u)", frequency, clk_hz);
		return -EINVAL;
	}

	*ctrl_out = SPI_CTRL_EN;
	if ((operation & SPI_MODE_CPHA) != 0U) {
		*ctrl_out |= SPI_CTRL_CPHA;
	}
	if ((operation & SPI_MODE_CPOL) != 0U) {
		*ctrl_out |= SPI_CTRL_CPOL;
	}
	*ctrl_out |= (best_prsc & 0x7U) << 3;
	*ctrl_out |= (best_cdiv & 0xFU) << 6;
	if (highspeed) {
		*ctrl_out |= BIT(10);
	}

	LOG_DBG("SPI: want %u Hz, got ~%u Hz prsc=%u cdiv=%u hs=%d", frequency, best, best_prsc,
		best_cdiv, highspeed);

	return 0;
}

/* Returns 0 on success, -ETIMEDOUT if the TX FIFO stays full too long. */
static int neorv32_spi_wait_tx_ready(const struct device *dev)
{
	for (uint32_t i = 0U; i < SPI_POLL_RETRIES; i++) {
		if (!(neorv32_spi_reg_read(dev, NEORV32_SPI_CTRL) & SPI_CTRL_TX_FULL)) {
			return 0;
		}
	}
	LOG_ERR("SPI TX FIFO full timeout");
	return -ETIMEDOUT;
}

/* Returns 0 on success, -ETIMEDOUT if the peripheral stays busy too long. */
static int neorv32_spi_wait_idle(const struct device *dev)
{
	for (uint32_t i = 0U; i < SPI_POLL_RETRIES; i++) {
		if (!(neorv32_spi_reg_read(dev, NEORV32_SPI_CTRL) & SPI_CTRL_BUSY)) {
			return 0;
		}
	}
	LOG_ERR("SPI BUSY timeout");
	return -ETIMEDOUT;
}

static int neorv32_spi_cs_assert(const struct device *dev, uint8_t cs)
{
	uint32_t cmd = SPI_DATA_CMD | SPI_DATA_CSEN | (uint32_t)(cs & 0x7U);
	int err;

	err = neorv32_spi_wait_tx_ready(dev);
	if (err < 0) {
		return err;
	}
	neorv32_spi_reg_write(dev, NEORV32_SPI_DATA, cmd);
	return 0;
}

static int neorv32_spi_cs_deassert(const struct device *dev)
{
	int err;

	err = neorv32_spi_wait_tx_ready(dev);
	if (err < 0) {
		return err;
	}
	neorv32_spi_reg_write(dev, NEORV32_SPI_DATA, SPI_DATA_CMD);
	return 0;
}

/* Sends txd and returns the received byte via *rxd. */
static int neorv32_spi_transfer_byte(const struct device *dev, uint8_t txd, uint8_t *rxd)
{
	int err;

	err = neorv32_spi_wait_tx_ready(dev);
	if (err < 0) {
		return err;
	}
	neorv32_spi_reg_write(dev, NEORV32_SPI_DATA, txd);

	err = neorv32_spi_wait_idle(dev);
	if (err < 0) {
		return err;
	}

	*rxd = (uint8_t)(neorv32_spi_reg_read(dev, NEORV32_SPI_DATA) & 0xFFU);
	return 0;
}

/* ---------------------------------------------------------------------------
 * Interrupt-driven transfer path
 * --------------------------------------------------------------------------- */
#ifdef CONFIG_SPI_NEORV32_INTERRUPT

/*
 * ISR — called once per received byte (FIRQ fires when RX FIFO is non-empty).
 *
 * Protocol:
 *  1. Read the RX byte from DATA; store it if an RX buffer is active.
 *  2. If more TX bytes remain: write the next byte → hardware starts the
 *     next SPI transaction → another FIRQ will fire when it completes.
 *  3. If no more bytes: disable the RX_AVAIL interrupt, deassert CS
 *     (unless HOLD_ON_CS), then signal completion to the waiting thread.
 */
static void neorv32_spi_isr(const struct device *dev)
{
	struct neorv32_spi_data *data = dev->data;
	struct spi_context *ctx = &data->ctx;

	/* 1. Harvest received byte */
	uint8_t rxd = (uint8_t)(neorv32_spi_reg_read(dev, NEORV32_SPI_DATA) & 0xFFU);

	if (spi_context_rx_buf_on(ctx)) {
		*(uint8_t *)ctx->rx_buf = rxd;
	}
	spi_context_update_rx(ctx, 1, 1);

	/* 2. More bytes to send? */
	if (spi_context_tx_on(ctx) || spi_context_rx_on(ctx)) {
		uint8_t txd = 0U;

		if (spi_context_tx_buf_on(ctx)) {
			txd = *(const uint8_t *)ctx->tx_buf;
		}
		spi_context_update_tx(ctx, 1, 1);
		neorv32_spi_reg_write(dev, NEORV32_SPI_DATA, txd);
		return;
	}

	/* 3. Transfer complete */
	uint32_t ctrl = neorv32_spi_reg_read(dev, NEORV32_SPI_CTRL);

	neorv32_spi_reg_write(dev, NEORV32_SPI_CTRL, ctrl & ~SPI_CTRL_IRQ_RX_AVAIL);

	if (!(ctx->config->operation & SPI_HOLD_ON_CS)) {
		/* Best-effort deassert; ignore errors from ISR context */
		neorv32_spi_reg_write(dev, NEORV32_SPI_DATA, SPI_DATA_CMD);
	}

	spi_context_complete(ctx, dev, 0);
}

/*
 * Interrupt-driven transfer: kick off the first byte and yield the thread.
 * The ISR handles all subsequent bytes and calls spi_context_complete() at
 * the end, which releases the semaphore and wakes this thread.
 */
static int neorv32_spi_xfer_irq(const struct device *dev, const struct spi_config *spi_cfg)
{
	struct neorv32_spi_data *data = dev->data;
	struct spi_context *ctx = &data->ctx;
	uint32_t ctrl;
	int err;

	err = neorv32_spi_cs_assert(dev, (uint8_t)spi_cfg->slave);
	if (err < 0) {
		spi_context_complete(ctx, dev, err);
		return err;
	}

	/* Enable RX-available interrupt before writing the first byte so we
	 * cannot miss the FIRQ if the hardware is very fast. */
	ctrl = neorv32_spi_reg_read(dev, NEORV32_SPI_CTRL);
	neorv32_spi_reg_write(dev, NEORV32_SPI_CTRL, ctrl | SPI_CTRL_IRQ_RX_AVAIL);

	/* Send the first byte; ISR fires when it completes. */
	uint8_t txd = 0U;

	if (spi_context_tx_buf_on(ctx)) {
		txd = *(const uint8_t *)ctx->tx_buf;
	}
	spi_context_update_tx(ctx, 1, 1);
	neorv32_spi_reg_write(dev, NEORV32_SPI_DATA, txd);

	/* Block this thread until ISR signals completion. */
	return spi_context_wait_for_completion(ctx);
}

#endif /* CONFIG_SPI_NEORV32_INTERRUPT */

/* ---------------------------------------------------------------------------
 * Polling transfer path (default / simulation)
 * --------------------------------------------------------------------------- */
static int neorv32_spi_xfer_poll(const struct device *dev, const struct spi_config *spi_cfg)
{
	struct neorv32_spi_data *data = dev->data;
	struct spi_context *ctx = &data->ctx;
	int err;

	err = neorv32_spi_cs_assert(dev, (uint8_t)spi_cfg->slave);
	if (err < 0) {
		spi_context_complete(ctx, dev, err);
		return err;
	}

	while (spi_context_tx_on(ctx) || spi_context_rx_on(ctx)) {
		uint8_t txd = 0U;
		uint8_t rxd;

		if (spi_context_tx_buf_on(ctx)) {
			txd = *(const uint8_t *)ctx->tx_buf;
		}

		err = neorv32_spi_transfer_byte(dev, txd, &rxd);
		if (err < 0) {
			goto xfer_done;
		}

		if (spi_context_rx_buf_on(ctx)) {
			*(uint8_t *)ctx->rx_buf = rxd;
		}

		spi_context_update_tx(ctx, 1, 1);
		spi_context_update_rx(ctx, 1, 1);
	}

	/* Deassert CS unless the caller is holding it across calls. */
	if (!(spi_cfg->operation & SPI_HOLD_ON_CS)) {
		int deassert_err = neorv32_spi_cs_deassert(dev);

		if (err == 0) {
			err = deassert_err;
		}

		/* Wait for the final CS-deassert command to complete. */
		if (err == 0) {
			err = neorv32_spi_wait_idle(dev);
		}
	}

xfer_done:
	spi_context_complete(ctx, dev, err);
	return err;
}

/* ---------------------------------------------------------------------------
 * Common API entry points
 * --------------------------------------------------------------------------- */
static int neorv32_spi_transceive(const struct device *dev, const struct spi_config *spi_cfg,
				  const struct spi_buf_set *tx_bufs,
				  const struct spi_buf_set *rx_bufs)
{
	struct neorv32_spi_data *data = dev->data;
	uint32_t ctrl = 0U;
	int err;

	if (spi_cfg->slave > SPI_MAX_CS) {
		LOG_ERR("slave index %u exceeds maximum %u", spi_cfg->slave, SPI_MAX_CS);
		return -EINVAL;
	}

	spi_context_lock(&data->ctx, false, NULL, NULL, spi_cfg);

	data->ctx.config = spi_cfg;

	err = neorv32_spi_compute_ctrl(dev, spi_cfg->frequency, spi_cfg->operation, &ctrl);
	if (err < 0) {
		spi_context_release(&data->ctx, err);
		return err;
	}

	neorv32_spi_reg_write(dev, NEORV32_SPI_CTRL, 0U);
	neorv32_spi_reg_write(dev, NEORV32_SPI_CTRL, ctrl);

	spi_context_buffers_setup(&data->ctx, tx_bufs, rx_bufs, 1);

#ifdef CONFIG_SPI_NEORV32_INTERRUPT
	err = neorv32_spi_xfer_irq(dev, spi_cfg);
#else
	err = neorv32_spi_xfer_poll(dev, spi_cfg);
#endif

	spi_context_release(&data->ctx, err);

	return err;
}

static int neorv32_spi_release(const struct device *dev, const struct spi_config *spi_cfg)
{
	struct neorv32_spi_data *data = dev->data;

	ARG_UNUSED(spi_cfg);

	spi_context_unlock_unconditionally(&data->ctx);
	return 0;
}

static int neorv32_spi_init(const struct device *dev)
{
	const struct neorv32_spi_config *cfg = dev->config;
	struct neorv32_spi_data *data = dev->data;
	uint32_t soc = 0U;
	int err;

	if (!device_is_ready(cfg->syscon)) {
		LOG_ERR("syscon not ready");
		return -ENODEV;
	}

	err = syscon_read_reg(cfg->syscon, NEORV32_SYSINFO_SOC, &soc);
	if (err < 0) {
		LOG_ERR("syscon read failed (%d)", err);
		return err;
	}

	if ((soc & NEORV32_SYSINFO_SOC_IO_SPI) == 0U) {
		LOG_ERR("SPI not synthesized in this NEORV32 configuration");
		return -ENODEV;
	}

	neorv32_spi_reg_write(dev, NEORV32_SPI_CTRL, 0U);

	err = spi_context_cs_configure_all(&data->ctx);
	if (err < 0) {
		return err;
	}

#ifdef CONFIG_SPI_NEORV32_INTERRUPT
	cfg->irq_config_func();
#endif

	spi_context_unlock_unconditionally(&data->ctx);

	return 0;
}

static DEVICE_API(spi, neorv32_spi_driver_api) = {
	.transceive = neorv32_spi_transceive,
	.release = neorv32_spi_release,
};

/* ---------------------------------------------------------------------------
 * Instance initialisation macros
 * --------------------------------------------------------------------------- */
#ifdef CONFIG_SPI_NEORV32_INTERRUPT

#define NEORV32_SPI_IRQ_CONFIG(n)                                                                  \
	static void neorv32_spi_irq_config_##n(void)                                               \
	{                                                                                          \
		IRQ_CONNECT(DT_INST_IRQN(n), DT_INST_IRQ(n, priority), neorv32_spi_isr,           \
			    DEVICE_DT_INST_GET(n), 0);                                             \
		irq_enable(DT_INST_IRQN(n));                                                       \
	}

#define NEORV32_SPI_CONFIG_IRQ_FIELD(n) .irq_config_func = neorv32_spi_irq_config_##n,

#else /* !CONFIG_SPI_NEORV32_INTERRUPT */

#define NEORV32_SPI_IRQ_CONFIG(n)
#define NEORV32_SPI_CONFIG_IRQ_FIELD(n)

#endif /* CONFIG_SPI_NEORV32_INTERRUPT */

#define NEORV32_SPI_INIT(n)                                                                        \
	NEORV32_SPI_IRQ_CONFIG(n)                                                                  \
                                                                                                   \
	static struct neorv32_spi_data neorv32_spi_data_##n = {                                    \
		SPI_CONTEXT_INIT_LOCK(neorv32_spi_data_##n, ctx),                                  \
		SPI_CONTEXT_INIT_SYNC(neorv32_spi_data_##n, ctx),                                  \
	};                                                                                         \
                                                                                                   \
	static const struct neorv32_spi_config neorv32_spi_config_##n = {                         \
		.base   = DT_INST_REG_ADDR(n),                                                     \
		.syscon = DEVICE_DT_GET(DT_INST_PHANDLE(n, syscon)),                               \
		NEORV32_SPI_CONFIG_IRQ_FIELD(n)                                                    \
	};                                                                                         \
                                                                                                   \
	SPI_DEVICE_DT_INST_DEFINE(n, neorv32_spi_init, NULL, &neorv32_spi_data_##n,               \
				  &neorv32_spi_config_##n, POST_KERNEL, CONFIG_SPI_INIT_PRIORITY,  \
				  &neorv32_spi_driver_api);

DT_INST_FOREACH_STATUS_OKAY(NEORV32_SPI_INIT)
