/*
 * Copyright (c) 2026
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * NEORV32 TWI (I2C-compatible) master driver (polling).
 *
 * Register map (neorv32_twi.h):
 *   CTRL @ 0x00  –  control/status
 *   DCMD @ 0x04  –  command/data FIFO port
 *
 * DCMD encoding (write):
 *   bits  7:0  – data byte
 *   bit   8    – MACK (master ACK after byte receive when reading)
 *   bits 10:9  – CMD: 00=NOP, 01=START, 10=STOP, 11=RTX
 *
 * DCMD encoding (read):
 *   bits  7:0  – received byte
 *   bit   8    – ACK received (0=slave ACK, 1=slave NACK)
 */

#define DT_DRV_COMPAT neorv32_twi

#define LOG_LEVEL CONFIG_I2C_LOG_LEVEL
#include <zephyr/logging/log.h>
LOG_MODULE_REGISTER(i2c_neorv32);

#include <errno.h>
#include <stdint.h>

#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/syscon.h>
#include <zephyr/sys/sys_io.h>

#include <soc.h>

/* Register offsets */
#define NEORV32_TWI_CTRL 0x00U
#define NEORV32_TWI_DCMD 0x04U

/* CTRL bits */
#define TWI_CTRL_EN       BIT(0)
#define TWI_CTRL_PRSC0    BIT(1)
#define TWI_CTRL_CDIV0    BIT(4)
#define TWI_CTRL_TX_FULL  BIT(29)
#define TWI_CTRL_RX_AVAIL BIT(30)
#define TWI_CTRL_BUSY     BIT(31)

/* DCMD bits */
#define TWI_DCMD_ACK      BIT(8)
#define TWI_DCMD_CMD_SHIFT 9U
#define TWI_CMD_NOP       0x0U
#define TWI_CMD_START     0x1U
#define TWI_CMD_STOP      0x2U
#define TWI_CMD_RTX       0x3U

/*
 * Maximum poll iterations before returning -ETIMEDOUT.
 * At 100 MHz each iteration is ~10 ns; 1 M iterations ≈ 10 ms, which is
 * well above any legitimate I2C transaction time at 100 kHz (standard mode).
 */
#define TWI_POLL_RETRIES 1000000U

/* NEORV32 clock prescaler LUT: index -> divisor */
static const uint16_t twi_prsc_lut[8] = {2, 4, 8, 64, 128, 1024, 2048, 4096};

struct neorv32_i2c_config {
	mm_reg_t base;
	const struct device *syscon;
};

static inline uint32_t neorv32_i2c_reg_read(const struct neorv32_i2c_config *cfg, uint32_t reg)
{
	return sys_read32(cfg->base + reg);
}

static inline void neorv32_i2c_reg_write(const struct neorv32_i2c_config *cfg, uint32_t reg,
					  uint32_t val)
{
	sys_write32(val, cfg->base + reg);
}

/* Blocks until TX FIFO has at least one free slot. Returns -ETIMEDOUT on hang. */
static int twi_wait_tx(const struct neorv32_i2c_config *cfg)
{
	for (uint32_t i = 0U; i < TWI_POLL_RETRIES; i++) {
		if (!(neorv32_i2c_reg_read(cfg, NEORV32_TWI_CTRL) & TWI_CTRL_TX_FULL)) {
			return 0;
		}
	}
	LOG_ERR("TWI TX FIFO full timeout");
	return -ETIMEDOUT;
}

/* Blocks until bus engine is idle (TX FIFO drained and bus quiet). Returns -ETIMEDOUT on hang. */
static int twi_wait_idle(const struct neorv32_i2c_config *cfg)
{
	for (uint32_t i = 0U; i < TWI_POLL_RETRIES; i++) {
		if (!(neorv32_i2c_reg_read(cfg, NEORV32_TWI_CTRL) & TWI_CTRL_BUSY)) {
			return 0;
		}
	}
	LOG_ERR("TWI bus busy timeout");
	return -ETIMEDOUT;
}

/* Blocks until an RX FIFO entry is available, then returns it via *val. Returns -ETIMEDOUT. */
static int twi_wait_rx(const struct neorv32_i2c_config *cfg, uint32_t *val)
{
	for (uint32_t i = 0U; i < TWI_POLL_RETRIES; i++) {
		if (neorv32_i2c_reg_read(cfg, NEORV32_TWI_CTRL) & TWI_CTRL_RX_AVAIL) {
			*val = neorv32_i2c_reg_read(cfg, NEORV32_TWI_DCMD);
			return 0;
		}
	}
	LOG_ERR("TWI RX FIFO empty timeout");
	return -ETIMEDOUT;
}

/* Issues a START (or REPEATED-START) condition and waits for completion. */
static int twi_start(const struct neorv32_i2c_config *cfg)
{
	int err;

	err = twi_wait_tx(cfg);
	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(cfg, NEORV32_TWI_DCMD, TWI_CMD_START << TWI_DCMD_CMD_SHIFT);
	return twi_wait_idle(cfg);
}

/* Issues a STOP condition and waits for completion. */
static int twi_stop(const struct neorv32_i2c_config *cfg)
{
	int err;

	err = twi_wait_tx(cfg);
	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(cfg, NEORV32_TWI_DCMD, TWI_CMD_STOP << TWI_DCMD_CMD_SHIFT);
	return twi_wait_idle(cfg);
}

/*
 * Sends one byte via RTX and returns the DCMD read value via *result.
 * For address/write bytes: mack=false.
 * For all read bytes except the last: mack=true (master ACK).
 * For the last read byte: mack=false (master NACK to signal end of read).
 */
static int twi_rtx(const struct neorv32_i2c_config *cfg, uint8_t data, bool mack, uint32_t *result)
{
	uint32_t cmd = (uint32_t)data | (TWI_CMD_RTX << TWI_DCMD_CMD_SHIFT);
	int err;

	if (mack) {
		cmd |= TWI_DCMD_ACK;
	}

	err = twi_wait_tx(cfg);
	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(cfg, NEORV32_TWI_DCMD, cmd);
	return twi_wait_rx(cfg, result);
}

static int neorv32_i2c_configure(const struct device *dev, uint32_t dev_config)
{
	const struct neorv32_i2c_config *cfg = dev->config;
	uint32_t clk_hz = 0U;
	uint32_t speed_hz;
	uint32_t best = 0U;
	uint32_t best_prsc = 4U;
	uint32_t best_cdiv = 1U;
	int err;

	/* Only master mode, 7-bit addressing */
	if (!(dev_config & I2C_MODE_CONTROLLER)) {
		return -ENOTSUP;
	}
	if (dev_config & I2C_ADDR_10_BITS) {
		return -ENOTSUP;
	}

	switch (I2C_SPEED_GET(dev_config)) {
	case I2C_SPEED_FAST:
		speed_hz = 400000U;
		break;
	case I2C_SPEED_FAST_PLUS:
		speed_hz = 1000000U;
		break;
	case I2C_SPEED_STANDARD:
	default:
		speed_hz = 100000U;
		break;
	}

	err = syscon_read_reg(cfg->syscon, NEORV32_SYSINFO_CLK, &clk_hz);
	if (err < 0) {
		LOG_ERR("syscon clock read failed (%d)", err);
		return err;
	}

	if (clk_hz == 0U) {
		LOG_ERR("SYSINFO reports zero CPU clock — SYSINFO may be uninitialised");
		return -EINVAL;
	}

	/* f_twi = f_cpu / (4 * PRSC * (1 + CDIV)) – find closest without exceeding speed_hz */
	for (uint32_t p = 0U; p < 8U; p++) {
		for (uint32_t d = 0U; d < 16U; d++) {
			uint32_t f = clk_hz / (4U * twi_prsc_lut[p] * (1U + d));

			if (f <= speed_hz && f > best) {
				best = f;
				best_prsc = p;
				best_cdiv = d;
			}
		}
	}

	if (best == 0U) {
		LOG_ERR("cannot achieve I2C frequency <= %u Hz", speed_hz);
		return -EINVAL;
	}

	LOG_DBG("I2C: target=%u got~%u Hz prsc=%u cdiv=%u", speed_hz, best, best_prsc, best_cdiv);

	uint32_t ctrl = TWI_CTRL_EN |
			((best_prsc & 0x7U) << 1U) |
			((best_cdiv & 0xFU) << 4U);

	neorv32_i2c_reg_write(cfg, NEORV32_TWI_CTRL, 0U);
	neorv32_i2c_reg_write(cfg, NEORV32_TWI_CTRL, ctrl);

	return 0;
}

static int neorv32_i2c_transfer(const struct device *dev, struct i2c_msg *msgs, uint8_t num_msgs,
				 uint16_t addr)
{
	const struct neorv32_i2c_config *cfg = dev->config;
	int ret = 0;
	int err;
	bool stop_issued = false;

	if (num_msgs == 0U) {
		return 0;
	}

	for (uint8_t i = 0U; i < num_msgs; i++) {
		/* Skip zero-length messages without disturbing the bus. */
		if (msgs[i].len == 0U) {
			continue;
		}

		bool is_read = (msgs[i].flags & I2C_MSG_READ) != 0U;

		/*
		 * Issue START or REPEATED START before each message.
		 * The NEORV32 TWI hardware generates a REPEATED START if the bus
		 * is already active (no STOP has been issued since the last START).
		 */
		err = twi_start(cfg);
		if (err < 0) {
			ret = err;
			goto done;
		}
		stop_issued = false;

		/* Address phase: send addr+R/W, check slave ACK */
		uint8_t addr_byte = (uint8_t)((addr << 1U) | (is_read ? 1U : 0U));
		uint32_t rx_val;

		err = twi_rtx(cfg, addr_byte, false, &rx_val);
		if (err < 0) {
			ret = err;
			goto done;
		}
		if (rx_val & TWI_DCMD_ACK) {
			/* Slave NACK'd the address */
			LOG_DBG("NACK on address 0x%02x", addr);
			ret = -ENXIO;
			goto done;
		}

		if (!is_read) {
			/* Write data bytes */
			for (uint32_t j = 0U; j < msgs[i].len; j++) {
				err = twi_rtx(cfg, msgs[i].buf[j], false, &rx_val);
				if (err < 0) {
					ret = err;
					goto done;
				}
				if (rx_val & TWI_DCMD_ACK) {
					LOG_DBG("NACK on write byte %u", j);
					ret = -EIO;
					goto done;
				}
			}
		} else {
			/* Read data bytes: MACK for all except the final byte. */
			for (uint32_t j = 0U; j < msgs[i].len; j++) {
				bool mack = (j < msgs[i].len - 1U);

				err = twi_rtx(cfg, 0xFFU, mack, &rx_val);
				if (err < 0) {
					ret = err;
					goto done;
				}
				msgs[i].buf[j] = (uint8_t)(rx_val & 0xFFU);
			}
		}

		/*
		 * Emit STOP if this message explicitly requests it (e.g. the last
		 * segment of an i2c_write_read, or any message where the caller
		 * wants to release the bus before issuing a fresh START).
		 */
		if (msgs[i].flags & I2C_MSG_STOP) {
			err = twi_stop(cfg);
			stop_issued = true;
			if (err < 0) {
				ret = err;
				goto done_no_stop;
			}
		}
	}

done:
	/* Always release the bus with a STOP unless one was already issued. */
	if (!stop_issued) {
		(void)twi_stop(cfg);
	}
done_no_stop:
	return ret;
}

static int neorv32_i2c_init(const struct device *dev)
{
	const struct neorv32_i2c_config *cfg = dev->config;
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

	if ((soc & NEORV32_SYSINFO_SOC_IO_TWI) == 0U) {
		LOG_ERR("TWI not synthesized in this NEORV32 configuration");
		return -ENODEV;
	}

	/* Disable peripheral; configure call will enable with proper speed */
	neorv32_i2c_reg_write(cfg, NEORV32_TWI_CTRL, 0U);

	/* Default: standard-speed master */
	return neorv32_i2c_configure(dev, I2C_MODE_CONTROLLER | I2C_SPEED_SET(I2C_SPEED_STANDARD));
}

static DEVICE_API(i2c, neorv32_i2c_driver_api) = {
	.configure = neorv32_i2c_configure,
	.transfer  = neorv32_i2c_transfer,
};

#define NEORV32_I2C_INIT(n)                                                                        \
	static const struct neorv32_i2c_config neorv32_i2c_config_##n = {                         \
		.base   = DT_INST_REG_ADDR(n),                                                     \
		.syscon = DEVICE_DT_GET(DT_INST_PHANDLE(n, syscon)),                               \
	};                                                                                         \
                                                                                                   \
	I2C_DEVICE_DT_INST_DEFINE(n, neorv32_i2c_init, NULL, NULL,                                \
				   &neorv32_i2c_config_##n, POST_KERNEL,                           \
				   CONFIG_I2C_INIT_PRIORITY, &neorv32_i2c_driver_api);

DT_INST_FOREACH_STATUS_OKAY(NEORV32_I2C_INIT)
