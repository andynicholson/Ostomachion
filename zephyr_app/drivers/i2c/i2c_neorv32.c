/*
 * Copyright (c) 2026
 *
 * SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
 *
 * NEORV32 TWI (I2C-compatible) master driver.
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
 *
 * Two transfer paths are compiled in, selected by Kconfig:
 *
 *   CONFIG_I2C_NEORV32_INTERRUPT=n  (default)
 *     Polling path: spins on TWI_CTRL_RX_AVAIL / TWI_CTRL_BUSY between
 *     every command.  Blocks the Zephyr scheduler but requires no DTS
 *     interrupt node.
 *
 *   CONFIG_I2C_NEORV32_INTERRUPT=y
 *     Interrupt-driven path: uses a state machine driven by the TWI FIRQ
 *     (FIRQ 7).  The FIRQ fires unconditionally whenever TWI_CTRL_RX_AVAIL
 *     is asserted — i.e., after every RTX command completes (address phase,
 *     write data, read data).  START and STOP commands produce no RX FIFO
 *     entry and therefore do not trigger the FIRQ; they are "fire and
 *     forget" writes to the TX FIFO.
 *
 *     The calling thread blocks on a semaphore; the ISR drives all byte
 *     transfers through the state machine and signals completion.
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
#include <zephyr/kernel.h>

#include "../neorv32_regs.h"

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
#define TWI_DCMD_ACK       BIT(8)
#define TWI_DCMD_CMD_SHIFT 9U
#define TWI_CMD_NOP        0x0U
#define TWI_CMD_START      0x1U
#define TWI_CMD_STOP       0x2U
#define TWI_CMD_RTX        0x3U

#define TWI_POLL_RETRIES NEORV32_POLL_RETRIES

/* Backstop timeout for the interrupt-driven completion wait.  The ISR drives
 * every byte and signals completion or error; this bound only fires if a FIRQ
 * is genuinely lost, turning an unrecoverable thread hang into -ETIMEDOUT.
 * A full multi-message I2C transaction at 100 kHz is well under 1 s. */
#define TWI_XFER_TIMEOUT K_SECONDS(1)

/* NEORV32 clock prescaler LUT: index -> divisor */
static const uint16_t twi_prsc_lut[8] = {2, 4, 8, 64, 128, 1024, 2048, 4096};

/* ---------------------------------------------------------------------------
 * ISR state machine states (interrupt path only)
 * --------------------------------------------------------------------------- */
enum neorv32_i2c_state {
	STATE_IDLE,
	STATE_ADDR,
	STATE_WR_DATA,
	STATE_RD_DATA,
};

struct neorv32_i2c_config {
	mm_reg_t base;
	const struct device *syscon;
#ifdef CONFIG_I2C_NEORV32_INTERRUPT
	void (*irq_config_func)(void);
	unsigned int irqn;
#endif
};

struct neorv32_i2c_data {
#ifdef CONFIG_I2C_NEORV32_INTERRUPT
	struct i2c_msg         *msgs;
	uint8_t                 num_msgs;
	uint8_t                 msg_idx;
	uint32_t                byte_idx;
	uint16_t                addr;
	int                     result;
	enum neorv32_i2c_state  state;
	struct k_sem            completion;
#endif
};

static inline uint32_t neorv32_i2c_reg_read(const struct device *dev, uint32_t reg)
{
	const struct neorv32_i2c_config *cfg = dev->config;

	return sys_read32(cfg->base + reg);
}

static inline void neorv32_i2c_reg_write(const struct device *dev, uint32_t reg, uint32_t val)
{
	const struct neorv32_i2c_config *cfg = dev->config;

	sys_write32(val, cfg->base + reg);
}

/* Blocks until TX FIFO has at least one free slot. Returns -ETIMEDOUT on hang. */
static int twi_wait_tx(const struct device *dev)
{
	for (uint32_t i = 0U; i < TWI_POLL_RETRIES; i++) {
		if (!(neorv32_i2c_reg_read(dev, NEORV32_TWI_CTRL) & TWI_CTRL_TX_FULL)) {
			return 0;
		}
	}
	LOG_ERR("TWI TX FIFO full timeout");
	return -ETIMEDOUT;
}

/* Blocks until bus engine is idle (TX FIFO drained and bus quiet). Returns -ETIMEDOUT. */
static int twi_wait_idle(const struct device *dev)
{
	for (uint32_t i = 0U; i < TWI_POLL_RETRIES; i++) {
		if (!(neorv32_i2c_reg_read(dev, NEORV32_TWI_CTRL) & TWI_CTRL_BUSY)) {
			return 0;
		}
	}
	LOG_ERR("TWI bus busy timeout");
	return -ETIMEDOUT;
}

#ifndef CONFIG_I2C_NEORV32_INTERRUPT
/* Blocks until an RX FIFO entry is available, then returns it via *val. */
static int twi_wait_rx(const struct device *dev, uint32_t *val)
{
	for (uint32_t i = 0U; i < TWI_POLL_RETRIES; i++) {
		if (neorv32_i2c_reg_read(dev, NEORV32_TWI_CTRL) & TWI_CTRL_RX_AVAIL) {
			*val = neorv32_i2c_reg_read(dev, NEORV32_TWI_DCMD);
			return 0;
		}
	}
	LOG_ERR("TWI RX FIFO empty timeout");
	return -ETIMEDOUT;
}
/* Issues a START (or REPEATED-START) condition and waits for bus idle. */
static int twi_start(const struct device *dev)
{
	int err;

	err = twi_wait_tx(dev);
	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(dev, NEORV32_TWI_DCMD, TWI_CMD_START << TWI_DCMD_CMD_SHIFT);
	return twi_wait_idle(dev);
}

/* Issues a STOP condition and waits for bus idle. */
static int twi_stop(const struct device *dev)
{
	int err;

	err = twi_wait_tx(dev);
	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(dev, NEORV32_TWI_DCMD, TWI_CMD_STOP << TWI_DCMD_CMD_SHIFT);
	return twi_wait_idle(dev);
}

/*
 * Sends one byte via RTX and waits for the RX result.
 * mack=true: master sends ACK after receiving (use for all-but-last read bytes).
 * mack=false: master sends NACK (use for address phase and last read byte).
 */
static int twi_rtx(const struct device *dev, uint8_t data_byte, bool mack, uint32_t *result)
{
	uint32_t cmd = (uint32_t)data_byte | (TWI_CMD_RTX << TWI_DCMD_CMD_SHIFT);
	int err;

	if (mack) {
		cmd |= TWI_DCMD_ACK;
	}

	err = twi_wait_tx(dev);
	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(dev, NEORV32_TWI_DCMD, cmd);
	return twi_wait_rx(dev, result);
}
#endif /* !CONFIG_I2C_NEORV32_INTERRUPT (blocking helpers) */

/* ---------------------------------------------------------------------------
 * Non-blocking variants for the interrupt-driven path
 * (write to TX FIFO and return immediately; no polling for RX)
 * --------------------------------------------------------------------------- */
#ifdef CONFIG_I2C_NEORV32_INTERRUPT

/* Write a START command to the TX FIFO (fire-and-forget; no RX entry). */
static int twi_start_nb(const struct device *dev)
{
	int err = twi_wait_tx(dev);

	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(dev, NEORV32_TWI_DCMD, TWI_CMD_START << TWI_DCMD_CMD_SHIFT);
	return 0;
}

/* Write a STOP command to the TX FIFO (fire-and-forget; no RX entry). */
static int twi_stop_nb(const struct device *dev)
{
	int err = twi_wait_tx(dev);

	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(dev, NEORV32_TWI_DCMD, TWI_CMD_STOP << TWI_DCMD_CMD_SHIFT);
	return 0;
}

/* Write an RTX command to the TX FIFO (fire-and-forget; RX entry appears later). */
static int twi_rtx_nb(const struct device *dev, uint8_t data_byte, bool mack)
{
	uint32_t cmd = (uint32_t)data_byte | (TWI_CMD_RTX << TWI_DCMD_CMD_SHIFT);
	int err;

	if (mack) {
		cmd |= TWI_DCMD_ACK;
	}

	err = twi_wait_tx(dev);
	if (err < 0) {
		return err;
	}
	neorv32_i2c_reg_write(dev, NEORV32_TWI_DCMD, cmd);
	return 0;
}

/*
 * ISR state machine.
 *
 * Called once per RTX completion (when an RX FIFO entry becomes available).
 * START and STOP commands do NOT produce RX entries, so they do not trigger
 * this ISR.
 *
 * Flow:
 *   STATE_ADDR   : read address-phase ACK/NACK, transition to data state.
 *   STATE_WR_DATA: read write-byte ACK/NACK, feed next byte or advance msg.
 *   STATE_RD_DATA: harvest received byte, feed next dummy RTX or advance msg.
 */
static void neorv32_i2c_isr(const struct device *dev)
{
	const struct neorv32_i2c_config *cfg = dev->config;
	struct neorv32_i2c_data *data = dev->data;
	uint32_t rx_val;
	int err = 0;

	/* Harvest the RX FIFO entry that triggered this interrupt. */
	if (!(neorv32_i2c_reg_read(dev, NEORV32_TWI_CTRL) & TWI_CTRL_RX_AVAIL)) {
		/* Spurious interrupt (should not happen) */
		return;
	}
	rx_val = neorv32_i2c_reg_read(dev, NEORV32_TWI_DCMD);

	switch (data->state) {

	case STATE_ADDR:
		if (rx_val & TWI_DCMD_ACK) {
			/* Slave NACK'd the address */
			LOG_DBG("NACK on address 0x%02x", data->addr);
			data->result = -ENXIO;
			goto done;
		}
		/* Address ACK'd — start data phase.  Every twi_*_nb() push can
		 * fail if the TX FIFO is full; a dropped push produces no further
		 * FIRQ, so on error we must abort to done rather than return and
		 * hang the waiting thread forever (see neorv32_i2c_transfer_irq). */
		data->byte_idx = 0U;
		if (data->msgs[data->msg_idx].flags & I2C_MSG_READ) {
			data->state = STATE_RD_DATA;
			bool mack = (data->msgs[data->msg_idx].len > 1U);

			err = twi_rtx_nb(dev, 0xFFU, mack);
		} else {
			data->state = STATE_WR_DATA;
			err = twi_rtx_nb(dev, data->msgs[data->msg_idx].buf[0], false);
		}
		if (err < 0) {
			data->result = err;
			goto done;
		}
		return;

	case STATE_WR_DATA:
		if (rx_val & TWI_DCMD_ACK) {
			LOG_DBG("NACK on write byte %u msg %u", data->byte_idx, data->msg_idx);
			data->result = -EIO;
			goto done;
		}
		data->byte_idx++;
		if (data->byte_idx < data->msgs[data->msg_idx].len) {
			err = twi_rtx_nb(dev, data->msgs[data->msg_idx].buf[data->byte_idx], false);
			if (err < 0) {
				data->result = err;
				goto done;
			}
			return;
		}
		goto next_msg;

	case STATE_RD_DATA:
		data->msgs[data->msg_idx].buf[data->byte_idx] = (uint8_t)(rx_val & 0xFFU);
		data->byte_idx++;
		if (data->byte_idx < data->msgs[data->msg_idx].len) {
			bool mack = (data->byte_idx < data->msgs[data->msg_idx].len - 1U);

			err = twi_rtx_nb(dev, 0xFFU, mack);
			if (err < 0) {
				data->result = err;
				goto done;
			}
			return;
		}
		goto next_msg;

	default:
		/* Unexpected state — fall through to done with EIO */
		data->result = -EIO;
		goto done;
	}

next_msg:
	/* The message at msg_idx just completed.  Decide STOP based on its flag
	 * BEFORE advancing msg_idx (reading msgs[msg_idx] after the increment
	 * would index one past the array on the final message).  Each path below
	 * issues at most one STOP, fixing the prior double-STOP where next_msg
	 * emitted a STOP and the unconditional done: emitted a second. */
	if (data->msgs[data->msg_idx].flags & I2C_MSG_STOP) {
		err = twi_stop_nb(dev);
		if (err < 0) {
			data->result = err;
			goto done_no_stop;   /* STOP already attempted */
		}
		data->msg_idx++;
		if (data->msg_idx >= data->num_msgs) {
			goto done_no_stop;   /* all messages done, STOP issued */
		}
	} else {
		data->msg_idx++;
		if (data->msg_idx >= data->num_msgs) {
			/* Final message had no STOP flag: release the bus. */
			(void)twi_stop_nb(dev);
			goto done_no_stop;
		}
	}

	/* More messages remain: issue REPEATED START + new address. */
	{
		uint8_t addr_byte = (uint8_t)((data->addr << 1U) |
			((data->msgs[data->msg_idx].flags & I2C_MSG_READ) ? 1U : 0U));

		data->byte_idx = 0U;
		data->state = STATE_ADDR;

		err = twi_start_nb(dev);
		if (err == 0) {
			err = twi_rtx_nb(dev, addr_byte, false);
		}
		if (err < 0) {
			data->result = err;
			goto done;
		}
		return;
	}

done:
	/* Error path: release the bus with a STOP, then wake the thread. */
	(void)twi_stop_nb(dev);

done_no_stop:
	data->state = STATE_IDLE;
	irq_disable(cfg->irqn);
	k_sem_give(&data->completion);
}

/* ---------------------------------------------------------------------------
 * Interrupt-driven transfer entry point
 * --------------------------------------------------------------------------- */
static int neorv32_i2c_transfer_irq(const struct device *dev, struct i2c_msg *msgs,
				    uint8_t num_msgs, uint16_t addr)
{
	const struct neorv32_i2c_config *cfg = dev->config;
	struct neorv32_i2c_data *data = dev->data;
	int err;

	if (num_msgs == 0U) {
		return 0;
	}

	/* Ensure the bus is idle after any previous STOP (executes asynchronously). */
	err = twi_wait_idle(dev);
	if (err < 0) {
		return err;
	}

	/* Set up state machine */
	data->msgs     = msgs;
	data->num_msgs = num_msgs;
	data->msg_idx  = 0U;
	data->byte_idx = 0U;
	data->addr     = addr;
	data->result   = 0;
	data->state    = STATE_ADDR;

	k_sem_reset(&data->completion);

	/* Enable interrupt before kicking off the first byte so we cannot
	 * miss the FIRQ if the hardware completes very quickly. */
	irq_enable(cfg->irqn);

	/* Write START (fire-and-forget: no RX entry, no FIRQ) */
	err = twi_start_nb(dev);
	if (err < 0) {
		irq_disable(cfg->irqn);
		return err;
	}

	/* Write address RTX: this produces an RX entry → FIRQ fires → ISR runs */
	uint8_t addr_byte = (uint8_t)((addr << 1U) |
				      ((msgs[0].flags & I2C_MSG_READ) ? 1U : 0U));

	err = twi_rtx_nb(dev, addr_byte, false);
	if (err < 0) {
		irq_disable(cfg->irqn);
		return err;
	}

	/* Yield this thread until the ISR signals completion.  A bounded wait is
	 * the backstop for a lost FIRQ: without it a single dropped interrupt
	 * hangs the caller forever. */
	if (k_sem_take(&data->completion, TWI_XFER_TIMEOUT) != 0) {
		LOG_ERR("I2C transfer timed out (lost FIRQ?) addr=0x%02x", addr);
		irq_disable(cfg->irqn);
		/* Best-effort bus release; the engine may be mid-byte. */
		(void)twi_stop_nb(dev);
		data->state = STATE_IDLE;
		return -ETIMEDOUT;
	}

	return data->result;
}

#endif /* CONFIG_I2C_NEORV32_INTERRUPT */

#ifndef CONFIG_I2C_NEORV32_INTERRUPT
/* ---------------------------------------------------------------------------
 * Polling transfer path (default / simulation)
 * --------------------------------------------------------------------------- */
static int neorv32_i2c_transfer_poll(const struct device *dev, struct i2c_msg *msgs,
				     uint8_t num_msgs, uint16_t addr)
{
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
		 * The NEORV32 TWI hardware generates a REPEATED START if the
		 * bus is already active (no STOP has been issued).
		 */
		err = twi_start(dev);
		if (err < 0) {
			ret = err;
			goto done;
		}
		stop_issued = false;

		/* Address phase: send addr+R/W, check slave ACK */
		uint8_t addr_byte = (uint8_t)((addr << 1U) | (is_read ? 1U : 0U));
		uint32_t rx_val;

		err = twi_rtx(dev, addr_byte, false, &rx_val);
		if (err < 0) {
			ret = err;
			goto done;
		}
		if (rx_val & TWI_DCMD_ACK) {
			LOG_DBG("NACK on address 0x%02x", addr);
			ret = -ENXIO;
			goto done;
		}

		if (!is_read) {
			/* Write data bytes */
			for (uint32_t j = 0U; j < msgs[i].len; j++) {
				err = twi_rtx(dev, msgs[i].buf[j], false, &rx_val);
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

				err = twi_rtx(dev, 0xFFU, mack, &rx_val);
				if (err < 0) {
					ret = err;
					goto done;
				}
				msgs[i].buf[j] = (uint8_t)(rx_val & 0xFFU);
			}
		}

		/*
		 * Emit STOP if this message explicitly requests it.
		 */
		if (msgs[i].flags & I2C_MSG_STOP) {
			err = twi_stop(dev);
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
		(void)twi_stop(dev);
	}
done_no_stop:
	return ret;
}
#endif /* !CONFIG_I2C_NEORV32_INTERRUPT */

/* ---------------------------------------------------------------------------
 * Common API entry points
 * --------------------------------------------------------------------------- */
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

	/* f_twi = f_cpu / (4 * PRSC * (1 + CDIV)) – find closest ≤ speed_hz */
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

	neorv32_i2c_reg_write(dev, NEORV32_TWI_CTRL, 0U);
	neorv32_i2c_reg_write(dev, NEORV32_TWI_CTRL, ctrl);

	return 0;
}

static int neorv32_i2c_transfer(const struct device *dev, struct i2c_msg *msgs, uint8_t num_msgs,
				uint16_t addr)
{
#ifdef CONFIG_I2C_NEORV32_INTERRUPT
	return neorv32_i2c_transfer_irq(dev, msgs, num_msgs, addr);
#else
	return neorv32_i2c_transfer_poll(dev, msgs, num_msgs, addr);
#endif
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
	neorv32_i2c_reg_write(dev, NEORV32_TWI_CTRL, 0U);

#ifdef CONFIG_I2C_NEORV32_INTERRUPT
	{
		struct neorv32_i2c_data *data = dev->data;

		k_sem_init(&data->completion, 0, 1);
		data->state = STATE_IDLE;

		/* Connect the ISR but do NOT enable — enabled per-transfer */
		cfg->irq_config_func();
	}
#endif

	/* Default: standard-speed master */
	return neorv32_i2c_configure(dev, I2C_MODE_CONTROLLER | I2C_SPEED_SET(I2C_SPEED_STANDARD));
}

static DEVICE_API(i2c, neorv32_i2c_driver_api) = {
	.configure = neorv32_i2c_configure,
	.transfer  = neorv32_i2c_transfer,
};

/* ---------------------------------------------------------------------------
 * Instance initialisation macros
 * --------------------------------------------------------------------------- */
#ifdef CONFIG_I2C_NEORV32_INTERRUPT

#define NEORV32_I2C_IRQ_CONFIG(n)                                                                  \
	static void neorv32_i2c_irq_config_##n(void)                                               \
	{                                                                                          \
		IRQ_CONNECT(DT_INST_IRQN(n), DT_INST_IRQ(n, priority), neorv32_i2c_isr,           \
			    DEVICE_DT_INST_GET(n), 0);                                             \
		/* IRQ intentionally left disabled here; enabled per-transfer */                   \
	}

#define NEORV32_I2C_DATA(n) static struct neorv32_i2c_data neorv32_i2c_data_##n;

#define NEORV32_I2C_DATA_PTR(n) &neorv32_i2c_data_##n,

#define NEORV32_I2C_CONFIG_IRQ_FIELDS(n) \
	.irq_config_func = neorv32_i2c_irq_config_##n, \
	.irqn            = DT_INST_IRQN(n),

#else /* !CONFIG_I2C_NEORV32_INTERRUPT */

#define NEORV32_I2C_IRQ_CONFIG(n)
#define NEORV32_I2C_DATA(n)
#define NEORV32_I2C_DATA_PTR(n) NULL,
#define NEORV32_I2C_CONFIG_IRQ_FIELDS(n)

#endif /* CONFIG_I2C_NEORV32_INTERRUPT */

#define NEORV32_I2C_INIT(n)                                                                        \
	NEORV32_I2C_IRQ_CONFIG(n)                                                                  \
	NEORV32_I2C_DATA(n)                                                                        \
                                                                                                   \
	static const struct neorv32_i2c_config neorv32_i2c_config_##n = {                         \
		.base   = DT_INST_REG_ADDR(n),                                                     \
		.syscon = DEVICE_DT_GET(DT_INST_PHANDLE(n, syscon)),                               \
		NEORV32_I2C_CONFIG_IRQ_FIELDS(n)                                                   \
	};                                                                                         \
                                                                                                   \
	I2C_DEVICE_DT_INST_DEFINE(n, neorv32_i2c_init, NULL, NEORV32_I2C_DATA_PTR(n)             \
				  &neorv32_i2c_config_##n, POST_KERNEL,                            \
				  CONFIG_I2C_INIT_PRIORITY, &neorv32_i2c_driver_api);

DT_INST_FOREACH_STATUS_OKAY(NEORV32_I2C_INIT)
