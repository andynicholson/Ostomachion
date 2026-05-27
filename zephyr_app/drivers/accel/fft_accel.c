/*
 * fft_accel.c — Zephyr MISC driver for the Ostomachion FFT accelerator pipeline
 * Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
 *
 * Device tree compatible: "ostomachion,fft-accel"
 *
 * Hardware overview:
 *   - TX BRAM (0x41000000, 32 KB): CPU word-writes input samples
 *   - RX BRAM (0x41008000, 32 KB): CPU word-reads output samples
 *   - AXI DMA (0x40000000):        streams TX BRAM → Xilinx xfft IP → RX BRAM
 *
 * The FFT core is the Xilinx xfft IP (PG109), pipelined streaming, 4096-point,
 * 16-bit Q1.15 fixed-point.  It has no AXI4-Lite control interface; it is
 * configured at synthesis time (forward, scale all stages) via hardwired
 * constants in the block design.
 *
 * Data format: each sample is a 32-bit word {im[15:0], re[15:0]}, Q1.15.
 *
 * Interrupt architecture (v1.1 — AXI INTC):
 *   The AXI INTC (Xilinx PG099, 0x40010000) aggregates three IRQ sources into
 *   one NEORV32 MEI line.  The ISR reads the INTC ISR register to identify
 *   the active channel:
 *     ch0 — AXI DMA MM2S complete/error
 *     ch1 — AXI DMA S2MM complete/error  (output ready)
 *     ch2 — xfft frame complete (m_axis_status_tvalid; not overflow-only)
 *
 * Transfer sequence (fft_accel_transform):
 *   1. Acquire xfer_lock (prevents concurrent calls).
 *   2. Write N complex samples to TX BRAM via MMIO.
 *   3. Reset and re-arm both DMA channels.
 *   4. Start both DMA channels with IOC + ERR interrupts enabled.
 *   5. Wait for S2MM IOC interrupt (INTC ch1) or DMA error (INTC ch0/ch1).
 *   6. Read N complex samples from RX BRAM via MMIO.
 *   7. Release xfer_lock.
 *
 * Thread safety: not safe for concurrent calls from multiple threads.
 * xfer_lock serialises callers; a second caller blocks until the first
 * completes or times out.
 *
 * Off-by-one contract:
 *   The xfft IP emits exactly N output beats per N-point input frame,
 *   with TLAST on the final beat, as PG109 v9.1 documents.  The driver
 *   therefore uses symmetric N*4 DMA byte counts and reads Y[i] directly
 *   from BRAM[i] with no offset, dummy read, or integrity sentinel.
 *   The 1:1 mapping is held in place by the BRAM read-latency contract
 *   in ACCEL_ARCH.md §4.1; the in-fabric fft_beat_counter on WireOut
 *   0x22 is the standing observability surface (ACCEL_ARCH.md §5).
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

/* ── AXI GPIO register offsets (Xilinx PG144) ───────────────────────────── */
#define GPIO_DATA  0x00  /* GPIO data output register (bit 0 = xfft_aresetn) */

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

/* ── AXI INTC register offsets (Xilinx PG099) ───────────────────────────── */
#define INTC_ISR  0x00U  /* Interrupt Status Register   (bit N = channel N pending) */
#define INTC_IPR  0x04U  /* Interrupt Pending Register  (ISR & IER)                 */
#define INTC_IER  0x08U  /* Interrupt Enable Register                               */
#define INTC_IAR  0x0CU  /* Interrupt Acknowledge Register (w1c clears ISR bit)      */
#define INTC_SIE  0x10U  /* Set Interrupt Enables                                   */
#define INTC_CIE  0x14U  /* Clear Interrupt Enables                                 */
#define INTC_IVR  0x18U  /* Interrupt Vector Register                               */
#define INTC_MER  0x1CU  /* Master Enable Register (bit0=ME, bit1=HIE)              */

/* INTC channel bit masks (must match ostomachion_bd.tcl channel wiring).
 *
 * Note: ch2 is wired to xfft m_axis_status_tvalid, which fires once per
 * completed FFT frame.  It is NOT a clean overflow-only signal: the actual
 * overflow flag is in m_axis_status_tdata[0] and is not currently routed
 * to a readable register in the BD.  See ACCEL_ARCH.md §2.2 (AXI INTC
 * channel wiring). */
#define INTC_CH_MM2S       BIT(0)  /* AXI DMA MM2S complete/error      */
#define INTC_CH_S2MM       BIT(1)  /* AXI DMA S2MM complete/error      */
#define INTC_CH_FRAME_DONE BIT(2)  /* xfft frame complete (not overflow) */

#define INTC_MER_ME  BIT(0)   /* Master Enable                */
#define INTC_MER_HIE BIT(1)   /* Hardware Interrupt Enable    */

/* ── Driver config / data structs ──────────────────────────────────────── */

struct fft_accel_config {
	uintptr_t dma_base;     /* AXI DMA base address          */
	uintptr_t tx_bram_base; /* TX BRAM base address          */
	uintptr_t rx_bram_base; /* RX BRAM base address          */
	uintptr_t intc_base;    /* AXI INTC base address         */
	uintptr_t gpio_base;    /* AXI GPIO base (xfft reset)    */
	uint32_t  dma_max_bytes; /* Maximum DMA transfer length, bytes */
	uint32_t  irq_num;      /* NEORV32 mext IRQ line         */
};

struct fft_accel_data {
	struct k_sem   irq_sem;
	struct k_mutex xfer_lock;
	int            last_error;    /* set by ISR on DMA error; read by transform */
	bool           last_overflow; /* set by ISR when xfft ovflo fires; cleared at transform start */
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

static inline void intc_wr(const struct fft_accel_config *cfg,
			    uint32_t off, uint32_t val)
{
	sys_write32(val, cfg->intc_base + off);
}

static inline uint32_t intc_rd(const struct fft_accel_config *cfg, uint32_t off)
{
	return sys_read32(cfg->intc_base + off);
}

static inline void gpio_wr(const struct fft_accel_config *cfg,
			   uint32_t off, uint32_t val)
{
	sys_write32(val, cfg->gpio_base + off);
}

static inline uint32_t gpio_rd(const struct fft_accel_config *cfg, uint32_t off)
{
	return sys_read32(cfg->gpio_base + off);
}

/**
 * dma_reset_channel() — pulse software reset and poll until the bit clears.
 *
 * The AXI DMA spec says the reset bit is self-clearing, but does not
 * guarantee the exact number of AXI clock cycles.  Polling avoids a
 * race where DMA_CR_RS is written before the reset completes.
 *
 * @return 0 on success, -ETIMEDOUT if the reset bit does not clear within
 *         DMA_RESET_POLL_MAX microseconds.  The caller must abort on timeout
 *         because a partially-reset DMA has undefined internal state.
 */
static int dma_reset_channel(const struct fft_accel_config *cfg, uint32_t cr_reg)
{
	dma_wr(cfg, cr_reg, DMA_CR_RESET);
	for (int i = 0; i < DMA_RESET_POLL_MAX; i++) {
		if (!(dma_rd(cfg, cr_reg) & DMA_CR_RESET)) {
			return 0;
		}
		k_busy_wait(1);
	}
	LOG_ERR("DMA channel reset timed out (cr_reg=0x%02x)", cr_reg);
	return -ETIMEDOUT;
}

/* ── IRQ handler ─────────────────────────────────────────────────────────── */

/**
 * fft_accel_isr() — AXI INTC-aware interrupt handler.
 *
 * Reads the INTC ISR register to determine which channels fired, handles
 * each channel explicitly, then acknowledges via the INTC IAR register.
 * This replaces the prior heuristic approach (inspecting DMA SR registers
 * to guess the source) with definitive per-channel identification.
 *
 * INTC channel mapping (see ostomachion_bd.tcl):
 *   ch0 (INTC_CH_MM2S)       — AXI DMA MM2S complete or error
 *   ch1 (INTC_CH_S2MM)       — AXI DMA S2MM complete or error (triggers sem)
 *   ch2 (INTC_CH_FRAME_DONE) — xfft frame complete (m_axis_status_tvalid pulse)
 */
static void fft_accel_isr(const struct device *dev)
{
	struct fft_accel_data *data = dev->data;
	const struct fft_accel_config *cfg = dev->config;
	bool give_sem = false;

	/* Read INTC ISR: bit N is set if channel N has a pending interrupt */
	uint32_t isr = intc_rd(cfg, INTC_ISR);

	/* ── Channel 0: DMA MM2S (source data read complete or error) ────── */
	if (isr & INTC_CH_MM2S) {
		uint32_t mm2s_sr = dma_rd(cfg, DMA_MM2S_DMASR);
		/* W1C: clears IRQ bits and de-asserts mm2s_introut before IAR */
		dma_wr(cfg, DMA_MM2S_DMASR, mm2s_sr);
		if (mm2s_sr & DMA_SR_ERR_IRQ) {
			LOG_ERR("DMA MM2S error: DMASR=0x%08x", mm2s_sr);
			data->last_error = -EIO;
			give_sem = true;
		}
	}

	/* ── Channel 1: DMA S2MM (output committed to RX BRAM, or error) ── */
	if (isr & INTC_CH_S2MM) {
		uint32_t s2mm_sr = dma_rd(cfg, DMA_S2MM_DMASR);
		/* W1C: clears IRQ bits and de-asserts s2mm_introut before IAR */
		dma_wr(cfg, DMA_S2MM_DMASR, s2mm_sr);
		if (s2mm_sr & DMA_SR_ERR_IRQ) {
			LOG_ERR("DMA S2MM error: DMASR=0x%08x", s2mm_sr);
			data->last_error = -EIO;
			give_sem = true;
		}
		if (s2mm_sr & DMA_SR_IOC_IRQ) {
			give_sem = true;  /* RX BRAM now contains valid output */
		}
	}

	/* ── Channel 2: xfft m_axis_status_tvalid (frame-done pulse) ─────
	 * Fires once per completed FFT frame, NOT exclusively on overflow.
	 * The actual overflow flag is m_axis_status_tdata[0], which is not
	 * currently wired to a readable register in the BD.  No action is
	 * required here; the channel is left enabled so the IAR W1C clears
	 * any pending edge before the next transform. */
	if (isr & INTC_CH_FRAME_DONE) {
		(void)0;  /* frame-complete notification — driver does not act on it */
	}

	/* Acknowledge INTC after all DMA DMASR W1C writes have de-asserted
	 * the source lines.  For level-sensitive channels (C_KIND_OF_INTR=0),
	 * writing IAR before the source de-asserts causes the ISR bit to
	 * immediately re-set, generating a spurious second ISR entry where
	 * give_sem fires again on stale isr state. */
	intc_wr(cfg, INTC_IAR, isr);

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
 * @param n    Transform size (must be 4096; other values return -EINVAL)
 * @return 0 on success, negative errno on error or timeout
 */
int fft_accel_transform(const struct device *dev,
			const struct fft_sample_t *in,
			struct fft_sample_t *out,
			size_t n)
{
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}

	const struct fft_accel_config *cfg = dev->config;
	struct fft_accel_data *data = dev->data;

	/* The xfft IP is synthesised for a fixed transform length (4096).
	 * A partial transfer would leave the IP waiting for more samples and
	 * the DMA would time out; reject any other size immediately. */
	if (n != 4096) {
		return -EINVAL;
	}

	/* Symmetric N-word DMA on both sides.
	 *
	 * The xfft IP emits exactly N output beats per N-point input frame
	 * with TLAST on the final beat (PG109 v9.1).  Both MM2S and S2MM
	 * therefore use byte_len = N*4 and the driver reads out[i] = BRAM[i]
	 * with no offset.  The fft_beat_counter on WireOut 0x22 is the
	 * standing observability surface for this invariant.  See
	 * ACCEL_ARCH.md §4.4 (symmetric DMA byte length) and §5
	 * (observability) for details.
	 */
	uint32_t byte_len = (uint32_t)(n * sizeof(struct fft_sample_t));

	if (byte_len > cfg->dma_max_bytes) {
		return -EINVAL;
	}

	/* Serialise concurrent callers */
	k_mutex_lock(&data->xfer_lock, K_FOREVER);
	data->last_error    = 0;
	data->last_overflow = false;

	/* Discard any stale completion left by a previous timed-out transfer.
	 * After k_sem_take returns -EAGAIN the DMA channels are reset, but a
	 * late ISR may still call k_sem_give before the reset completes.
	 * Resetting here (while holding xfer_lock) is safe and avoids the
	 * next transfer reading a bogus immediate-complete. */
	k_sem_reset(&data->irq_sem);

	/* 1. Write input samples to TX BRAM */
	for (size_t i = 0; i < n; i++) {
		uint32_t word = ((uint32_t)(uint16_t)in[i].im << 16) |
				(uint32_t)(uint16_t)in[i].re;
		sys_write32(word, cfg->tx_bram_base + i * 4);
	}

	/* 2. Reset xfft pipeline then DMA channels.
	 *
	 * Per PG109 §3, aresetn must be held low for at least two aclk cycles
	 * to flush the internal pipeline.  GPIO bit 0 drives xfft_aresetn through
	 * a util_vector_logic AND with peripheral_rstn (C_DOUT_DEFAULT=1, so
	 * xfft starts un-reset after FPGA power-on).
	 *
	 * Sequence (PG021 §2.4):
	 *   a. GPIO=0 → assert xfft_aresetn=0: flush pipeline state.
	 *   b. DMA software reset: halts any in-progress transfers cleanly.
	 *   c. GPIO=1 → release xfft_aresetn=1: pipeline ready to accept input.
	 *
	 * The k_busy_wait calls below make the >=2 aclk-cycle requirement
	 * explicit rather than relying on MMIO-write latency between back-to-back
	 * register writes.  At 100 MHz, 1 us = 100 cycles (50× margin over the
	 * 2-cycle minimum).
	 */
	gpio_wr(cfg, GPIO_DATA, 0x0);  /* assert xfft reset (aresetn=0) */
	k_busy_wait(1);                /* hold aresetn=0 for >=2 aclk cycles */

	int reset_err = dma_reset_channel(cfg, DMA_MM2S_DMACR);
	reset_err    |= dma_reset_channel(cfg, DMA_S2MM_DMACR);
	if (reset_err) {
		gpio_wr(cfg, GPIO_DATA, 0x1);  /* release xfft reset before exit */
		k_mutex_unlock(&data->xfer_lock);
		return -EIO;
	}

	gpio_wr(cfg, GPIO_DATA, 0x1);  /* release xfft reset (aresetn=1) */
	k_busy_wait(1);                /* let xfft pipeline come out of reset */

	/* 3. Arm S2MM first (xfft output stream → RX BRAM, IOC + ERR IRQs).
	 * PG021 sequence: RS=1 first (channel Halted→Idle), then DA, then LENGTH.
	 * Writing LENGTH to a running channel triggers the transfer.
	 * S2MM is armed before MM2S so its TREADY is high before xfft output begins;
	 * in nonrealtime throttle mode a low TREADY backpressures through the xfft
	 * pipeline to s_axis_data_tready=0, deadlocking the MM2S input side. */
	dma_wr(cfg, DMA_S2MM_DMACR,  DMA_CR_RS | DMA_CR_IOC_IRQEN | DMA_CR_ERR_IRQEN);
	dma_wr(cfg, DMA_S2MM_DA,     (uint32_t)cfg->rx_bram_base);
	dma_wr(cfg, DMA_S2MM_LENGTH, byte_len);

	/* 4. Trigger MM2S last (TX BRAM → xfft input stream, ERR IRQ only).
	 * Same PG021 sequence: RS=1, then SA, then LENGTH (transfer starts). */
	dma_wr(cfg, DMA_MM2S_DMACR,  DMA_CR_RS | DMA_CR_ERR_IRQEN);
	dma_wr(cfg, DMA_MM2S_SA,     (uint32_t)cfg->tx_bram_base);
	dma_wr(cfg, DMA_MM2S_LENGTH, byte_len);

	/* 5. Wait for S2MM IOC interrupt (output committed to RX BRAM) or error.
	 *
	 * The ISR gives irq_sem on S2MM IOC (channel 1) or any DMA error
	 * (channels 0 or 1).  A single blocking wait covers both cases;
	 * data->last_error is set by the ISR on error before giving the sem. */
	int ret = k_sem_take(&data->irq_sem, K_MSEC(CONFIG_FFT_ACCEL_TIMEOUT_MS));
	if (ret != 0) {
		LOG_ERR("FFT DMA timeout after %d ms", CONFIG_FFT_ACCEL_TIMEOUT_MS);

		/* DIAGNOSTIC: snapshot registers before reset to identify failure mode.
		 *
		 * Interpretation guide:
		 *  MM2S_DMASR IDLE=0        → MM2S still running; xfft not accepting input
		 *                             (s_axis_data_tready stuck LOW — xfft config
		 *                              handshake or pipeline stall)
		 *  MM2S_DMASR IDLE=1        → MM2S finished (xfft received all samples)
		 *  S2MM_DMASR IOC=1         → S2MM finished; interrupt never reached CPU
		 *                             (check INTC_ISR, MIE[11], mext_irq_i path)
		 *  S2MM_DMASR IDLE=0,IOC=0  → S2MM still running; xfft not producing output
		 *  INTC_ISR ≠ 0             → INTC generated an IRQ; CPU did not take it
		 *                             (MEIE not set, mstatus.MIE cleared, or mtvec wrong)
		 *  INTC_ISR = 0             → No pending INTC interrupt at all
		 *  INTC_MER ≠ 0x3           → Master enable was cleared (INTC init bug)
		 */
		uint32_t mm2s_sr = dma_rd(cfg, DMA_MM2S_DMASR);
		uint32_t s2mm_sr = dma_rd(cfg, DMA_S2MM_DMASR);
		uint32_t intc_isr = intc_rd(cfg, INTC_ISR);
		uint32_t intc_ier = intc_rd(cfg, INTC_IER);
		uint32_t intc_mer = intc_rd(cfg, INTC_MER);

		LOG_ERR("  MM2S_DMASR=0x%08x (IDLE=%d IOC=%d ERR=%d)",
			mm2s_sr,
			!!(mm2s_sr & DMA_SR_IDLE),
			!!(mm2s_sr & DMA_SR_IOC_IRQ),
			!!(mm2s_sr & DMA_SR_ERR_IRQ));
		LOG_ERR("  S2MM_DMASR=0x%08x (IDLE=%d IOC=%d ERR=%d)",
			s2mm_sr,
			!!(s2mm_sr & DMA_SR_IDLE),
			!!(s2mm_sr & DMA_SR_IOC_IRQ),
			!!(s2mm_sr & DMA_SR_ERR_IRQ));
		LOG_ERR("  INTC_ISR=0x%08x INTC_IER=0x%08x INTC_MER=0x%08x",
			intc_isr, intc_ier, intc_mer);

		/* Halt both channels to prevent a stale IRQ on the next call */
		dma_reset_channel(cfg, DMA_MM2S_DMACR);
		dma_reset_channel(cfg, DMA_S2MM_DMACR);
		k_mutex_unlock(&data->xfer_lock);
		return -ETIMEDOUT;
	}

	int err = data->last_error;

	if (data->last_overflow) {
		LOG_WRN("FFT overflow occurred — results may be corrupted; "
			"reduce input amplitude or enable scaling");
	}

	/* 6a. Post-completion DMA state validation.
	 *
	 * S2MM_DMASR.IDLE must be set after IOC for a non-SG DMA: an IOC
	 * delivered while the channel is still running indicates a spurious
	 * interrupt or an unhandled error. */
	if (err == 0) {
		uint32_t s2mm_sr = dma_rd(cfg, DMA_S2MM_DMASR);
		if (!(s2mm_sr & DMA_SR_IDLE)) {
			LOG_ERR("S2MM IOC fired but channel not IDLE: DMASR=0x%08x",
				s2mm_sr);
			err = -EIO;
		}
	}

	/* 7. Read output samples from RX BRAM (only on success).
	 *
	 * Direct 1:1 mapping — Y[i] lands at BRAM[i] because xfft emits
	 * exactly N output beats per N-point frame (verified on-fabric by
	 * fft_beat_counter, WireOut 0x22).  No dummy read, no offset.
	 *
	 * Each 32-bit word is {im[31:16], re[15:0]} in Q1.15 fixed-point. */
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

/**
 * fft_accel_get_last_overflow() — check whether the last transform overflowed.
 *
 * The xfft IP fires an interrupt on m_axis_status_tvalid when the
 * fixed-point accumulator would have overflowed.  This function returns true
 * if that event was recorded during the most recent fft_accel_transform() call.
 * The flag is cleared at the start of every fft_accel_transform().
 *
 * @param dev  FFT accelerator device
 * @return true if overflow was detected in the last transform, false otherwise
 */
bool fft_accel_get_last_overflow(const struct device *dev)
{
	if (!device_is_ready(dev)) {
		return false;
	}
	const struct fft_accel_data *data = dev->data;
	return data->last_overflow;
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
		.intc_base    = DT_INST_REG_ADDR_BY_NAME(inst, intc),		\
		.gpio_base    = DT_INST_REG_ADDR_BY_NAME(inst, gpio),		\
		.dma_max_bytes = DT_INST_PROP(inst, dma_max_bytes),		\
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
		/* Initialise AXI INTC: enable channels 0,1,2 and master */	\
		intc_wr(cfg, INTC_IER, INTC_CH_MM2S | INTC_CH_S2MM | INTC_CH_FRAME_DONE); \
		intc_wr(cfg, INTC_MER, INTC_MER_ME | INTC_MER_HIE);		\
									\
		IRQ_CONNECT(DT_INST_IRQN(inst), 0,				\
			    fft_accel_isr, DEVICE_DT_INST_GET(inst), 0);	\
		irq_enable(cfg->irq_num);					\
									\
		LOG_INF("FFT accelerator (xfft) initialised, "			\
			"DMA @ 0x%08x, INTC @ 0x%08x",				\
			(unsigned)cfg->dma_base, (unsigned)cfg->intc_base);	\
		if (sizeof(CONFIG_OSTOMACHION_HW_BUILD_ID) > 1) {		\
			LOG_INF("Expected HW build ID : %s",			\
				CONFIG_OSTOMACHION_HW_BUILD_ID);		\
		} else {							\
			LOG_DBG("HW build ID check disabled "			\
				"(CONFIG_OSTOMACHION_HW_BUILD_ID not set)");	\
		}								\
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
