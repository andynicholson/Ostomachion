/*
 * fft_accel.c — Zephyr MISC driver for the Ostomachion FFT accelerator pipeline
 * Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
 *
 * Device tree compatible: "ostomachion,fft-accel"
 *
 * Hardware overview:
 *   - TX BRAM (0x41000000, 16 KB): CPU word-writes input samples
 *   - RX BRAM (0x41004000, 16 KB): CPU word-reads output samples
 *   - AXI DMA (0x40000000):        streams TX BRAM → Xilinx xfft IP → RX BRAM
 *
 * The FFT core is the Xilinx xfft IP (PG109), pipelined streaming, 64-point,
 * 16-bit Q1.15 fixed-point.  It has no AXI4-Lite control interface; it is
 * configured at synthesis time (forward, scale all stages) via hardwired
 * constants in the block design.
 *
 * Data format: each sample is a 32-bit word {im[15:0], re[15:0]}, Q1.15.
 *
 * Transfer sequence (fft_accel_transform):
 *   1. Acquire xfer_lock (prevents concurrent calls).
 *   2. Write N complex samples to TX BRAM via MMIO.
 *   3. Reset and re-arm both DMA channels.
 *   4. Start both DMA channels with IOC + ERR interrupts enabled.
 *   5. Wait for S2MM IOC interrupt (output committed to RX BRAM) or error.
 *   6. Read N complex samples from RX BRAM via MMIO.
 *   7. Release xfer_lock.
 *
 * Thread safety: not safe for concurrent calls from multiple threads.
 * xfer_lock serialises callers; a second caller blocks until the first
 * completes or times out.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/misc/fft_accel.h>
#include <zephyr/irq.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(fft_accel, CONFIG_FFT_ACCEL_LOG_LEVEL);

#define DT_DRV_COMPAT ostomachion_fft_accel

/* ── AXI DMA register offsets (simple/register-direct mode) ─────────────── */
#define DMA_MM2S_DMACR  0x00  /* MM2S DMA Control Register   */
#define DMA_MM2S_DMASR  0x04  /* MM2S DMA Status Register    */
#define DMA_MM2S_SA     0x18  /* MM2S Source Address         */
#define DMA_MM2S_LENGTH 0x28  /* MM2S Transfer Length (bytes)*/
#define DMA_S2MM_DMACR  0x30  /* S2MM DMA Control Register   */
#define DMA_S2MM_DMASR  0x34  /* S2MM DMA Status Register    */
#define DMA_S2MM_DA     0x48  /* S2MM Destination Address    */
#define DMA_S2MM_LENGTH 0x58  /* S2MM Transfer Length (bytes)*/

/* DMACR bits */
#define DMA_CR_RS        BIT(0)   /* Run/Stop                  */
#define DMA_CR_RESET     BIT(2)   /* Software reset (self-clr) */
#define DMA_CR_IOC_IRQEN BIT(12)  /* IRQ on completion         */
#define DMA_CR_ERR_IRQEN BIT(14)  /* IRQ on error              */

/* DMASR bits */
#define DMA_SR_IDLE    BIT(1)
#define DMA_SR_IOC_IRQ BIT(12)
#define DMA_SR_ERR_IRQ BIT(14)

/* Maximum polling iterations for software reset (~100 µs at 100 MHz) */
#define DMA_RESET_POLL_MAX 100

/* ── Driver config / data structs ──────────────────────────────────────── */

struct fft_accel_config {
	uintptr_t dma_base;     /* AXI DMA base address   */
	uintptr_t tx_bram_base; /* TX BRAM base address   */
	uintptr_t rx_bram_base; /* RX BRAM base address   */
	uint32_t  bram_size;    /* BRAM size in bytes     */
	uint32_t  irq_num;      /* NEORV32 mext IRQ line  */
};

struct fft_accel_data {
	struct k_sem   irq_sem;
	struct k_mutex xfer_lock;
	int            last_error;  /* set by ISR on DMA error; read by transform */
};

/* ── Register accessors ─────────────────────────────────────────────────── */

static inline void dma_wr(const struct fft_accel_config *cfg,
			   uint32_t off, uint32_t val)
{
	sys_write32(val, cfg->dma_base + off);
}

static inline uint32_t dma_rd(const struct fft_accel_config *cfg, uint32_t off)
{
	return sys_read32(cfg->dma_base + off);
}

/**
 * dma_reset_channel() — pulse software reset and poll until the bit clears.
 *
 * The AXI DMA spec says the reset bit is self-clearing, but does not
 * guarantee the exact number of AXI clock cycles.  Polling avoids a
 * race where DMA_CR_RS is written before the reset completes.
 */
static void dma_reset_channel(const struct fft_accel_config *cfg, uint32_t cr_reg)
{
	dma_wr(cfg, cr_reg, DMA_CR_RESET);
	for (int i = 0; i < DMA_RESET_POLL_MAX; i++) {
		if (!(dma_rd(cfg, cr_reg) & DMA_CR_RESET)) {
			return;
		}
		k_busy_wait(1);
	}
	LOG_WRN("DMA channel reset timed out (cr_reg=0x%02x)", cr_reg);
}

/* ── IRQ handler ─────────────────────────────────────────────────────────── */

static void fft_accel_isr(const struct device *dev)
{
	struct fft_accel_data *data = dev->data;
	const struct fft_accel_config *cfg = dev->config;
	bool give_sem = false;

	uint32_t mm2s_sr = dma_rd(cfg, DMA_MM2S_DMASR);
	uint32_t s2mm_sr = dma_rd(cfg, DMA_S2MM_DMASR);

	/* Acknowledge all active bits (write-1-to-clear) */
	if (mm2s_sr & (DMA_SR_IOC_IRQ | DMA_SR_ERR_IRQ)) {
		dma_wr(cfg, DMA_MM2S_DMASR, mm2s_sr);
	}
	if (s2mm_sr & (DMA_SR_IOC_IRQ | DMA_SR_ERR_IRQ)) {
		dma_wr(cfg, DMA_S2MM_DMASR, s2mm_sr);
	}

	/* DMA errors: log, record, and unblock the caller immediately.
	 * The S2MM IOC will never fire on an error path, so we must
	 * release the semaphore here or fft_accel_transform would time out. */
	if (mm2s_sr & DMA_SR_ERR_IRQ) {
		LOG_ERR("DMA MM2S error: DMASR=0x%08x", mm2s_sr);
		data->last_error = -EIO;
		give_sem = true;
	}
	if (s2mm_sr & DMA_SR_ERR_IRQ) {
		LOG_ERR("DMA S2MM error: DMASR=0x%08x", s2mm_sr);
		data->last_error = -EIO;
		give_sem = true;
	}

	/* S2MM IOC: output committed to RX BRAM — results are ready to read */
	if (s2mm_sr & DMA_SR_IOC_IRQ) {
		give_sem = true;
	}

	if (give_sem) {
		k_sem_give(&data->irq_sem);
	}
}

/* ── Public API ─────────────────────────────────────────────────────────── */

/**
 * fft_accel_transform() — run one N-point complex FFT.
 *
 * Serialised by an internal mutex: a second caller blocks until the first
 * call returns.  Not safe for use from ISR context.
 *
 * @param dev  FFT accelerator device
 * @param in   Input samples (re/im Q1.15), length n
 * @param out  Output buffer, same size
 * @param n    Transform size (must be 64; other values return -EINVAL)
 * @return 0 on success, negative errno on error or timeout
 */
int fft_accel_transform(const struct device *dev,
			const struct fft_sample_t *in,
			struct fft_sample_t *out,
			size_t n)
{
	const struct fft_accel_config *cfg = dev->config;
	struct fft_accel_data *data = dev->data;

	if (n != 64) {
		return -EINVAL;
	}

	uint32_t byte_len = (uint32_t)(n * sizeof(struct fft_sample_t));

	if (byte_len > cfg->bram_size) {
		return -EINVAL;
	}

	/* Serialise concurrent callers */
	k_mutex_lock(&data->xfer_lock, K_FOREVER);
	data->last_error = 0;

	/* 1. Write input samples to TX BRAM */
	for (size_t i = 0; i < n; i++) {
		uint32_t word = ((uint32_t)(uint16_t)in[i].im << 16) |
				(uint32_t)(uint16_t)in[i].re;
		sys_write32(word, cfg->tx_bram_base + i * 4);
	}

	/* 2. Reset both DMA channels (polled until reset bit self-clears) */
	dma_reset_channel(cfg, DMA_MM2S_DMACR);
	dma_reset_channel(cfg, DMA_S2MM_DMACR);

	/* 3. Program MM2S (TX BRAM → xfft input stream) with IOC + ERR IRQs */
	dma_wr(cfg, DMA_MM2S_DMACR,  DMA_CR_RS | DMA_CR_IOC_IRQEN | DMA_CR_ERR_IRQEN);
	dma_wr(cfg, DMA_MM2S_SA,     (uint32_t)cfg->tx_bram_base);
	dma_wr(cfg, DMA_MM2S_LENGTH, byte_len);

	/* 4. Program S2MM (xfft output stream → RX BRAM) with IOC + ERR IRQs */
	dma_wr(cfg, DMA_S2MM_DMACR,  DMA_CR_RS | DMA_CR_IOC_IRQEN | DMA_CR_ERR_IRQEN);
	dma_wr(cfg, DMA_S2MM_DA,     (uint32_t)cfg->rx_bram_base);
	dma_wr(cfg, DMA_S2MM_LENGTH, byte_len);

	/* 5. Wait for S2MM IOC (output ready) or DMA error */
	int ret = k_sem_take(&data->irq_sem, K_MSEC(100));
	if (ret != 0) {
		LOG_ERR("FFT DMA timeout after 100 ms");
		/* Halt both channels to prevent a stale IRQ on the next call */
		dma_reset_channel(cfg, DMA_MM2S_DMACR);
		dma_reset_channel(cfg, DMA_S2MM_DMACR);
		k_mutex_unlock(&data->xfer_lock);
		return -ETIMEDOUT;
	}

	int err = data->last_error;

	/* 6. Read output samples from RX BRAM (only on success) */
	if (err == 0) {
		for (size_t i = 0; i < n; i++) {
			uint32_t word = sys_read32(cfg->rx_bram_base + i * 4);
			out[i].re = (int16_t)(word & 0xFFFFu);
			out[i].im = (int16_t)(word >> 16);
		}
	}

	k_mutex_unlock(&data->xfer_lock);
	return err;
}

/* ── Device instantiation macros ─────────────────────────────────────────── */
/*
 * Each instance gets its own init function so that IRQ_CONNECT is called
 * with the correct compile-time instance number.  The common pattern of
 * calling IRQ_CONNECT inside a shared fft_accel_init() hardcodes instance 0
 * and is incorrect for multi-instance drivers.
 */

#define FFT_ACCEL_DEFINE(inst)							\
									\
	static struct fft_accel_data fft_accel_data_##inst;			\
									\
	static const struct fft_accel_config fft_accel_cfg_##inst = {		\
		.dma_base     = DT_INST_REG_ADDR_BY_NAME(inst, dma),		\
		.tx_bram_base = DT_INST_REG_ADDR_BY_NAME(inst, tx_bram),	\
		.rx_bram_base = DT_INST_REG_ADDR_BY_NAME(inst, rx_bram),	\
		.bram_size    = DT_INST_PROP(inst, bram_size),			\
		.irq_num      = DT_INST_IRQN(inst),				\
	};									\
									\
	static int fft_accel_init_##inst(const struct device *dev)		\
	{									\
		struct fft_accel_data *data = dev->data;			\
		const struct fft_accel_config *cfg = dev->config;		\
									\
		k_sem_init(&data->irq_sem, 0, 1);				\
		k_mutex_init(&data->xfer_lock);					\
									\
		IRQ_CONNECT(DT_INST_IRQN(inst), 0,				\
			    fft_accel_isr, DEVICE_DT_INST_GET(inst), 0);	\
		irq_enable(cfg->irq_num);					\
									\
		LOG_INF("FFT accelerator (xfft) initialised, DMA @ 0x%08x",	\
			(unsigned)cfg->dma_base);				\
		return 0;							\
	}									\
									\
	DEVICE_DT_INST_DEFINE(inst,						\
			      fft_accel_init_##inst,				\
			      NULL,						\
			      &fft_accel_data_##inst,				\
			      &fft_accel_cfg_##inst,				\
			      POST_KERNEL,					\
			      CONFIG_KERNEL_INIT_PRIORITY_DEVICE,		\
			      NULL);

DT_INST_FOREACH_STATUS_OKAY(FFT_ACCEL_DEFINE)
