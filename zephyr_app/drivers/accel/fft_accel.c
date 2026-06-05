/*
 * fft_accel.c — Zephyr MISC driver for the Ostomachion FFT accelerator pipeline
 * Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
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
#include <zephyr/sys/barrier.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(fft_accel, CONFIG_FFT_ACCEL_LOG_LEVEL);

#define DT_DRV_COMPAT ostomachion_fft_accel

/* ── AXI GPIO register offsets (Xilinx PG144) ───────────────────────────── */
#define GPIO_DATA   0x00  /* Ch1 data (output): bit0 = xfft_aresetn gate,
			   *                    bit1 = filter bypass select   */
#define GPIO_DATA2  0x08  /* Ch2 data (input):  bit0 = latched xfft overflow,
			   *                    bit1 = aggregated stage overflow */

/* GPIO ch1 output bits (xem7310_top.vhd routing). */
#define GPIO_ARESETN       BIT(0)  /* 1 = xfft running, 0 = pipeline reset      */
#define GPIO_FILTER_BYPASS BIT(1)  /* 1 = S2MM <- forward FFT (bins),
				    * 0 = S2MM <- filter + IFFT (round trip).
				    * Unimplemented (RAZ/WI) on a forward-only
				    * bitstream, so writes are harmless there.   */

/* xfft overflow flags, read from the AXI GPIO input channel.  bit0 is set in
 * fabric when xfft_0 m_axis_status_tdata[0] is high during a frame; bit1
 * aggregates xfft_0 OR xfft_1 OR normalizer-saturation.  Both are cleared by
 * the xfft aresetn pulse this driver issues at the start of every transform. */
#define GPIO_OVERFLOW     BIT(0)
#define GPIO_OVERFLOW_AGG BIT(1)

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
 * completed FFT frame.  It is NOT a clean overflow-only signal.  The actual
 * overflow flag (m_axis_status_tdata[0]) is captured separately in fabric and
 * read back via the AXI GPIO input channel (GPIO_DATA2) — see the overflow
 * read in fft_accel_transform() and ACCEL_ARCH.md §2.2 / §2.3. */
#define INTC_CH_MM2S       BIT(0)  /* AXI DMA MM2S complete/error      */
#define INTC_CH_S2MM       BIT(1)  /* AXI DMA S2MM complete/error      */
#define INTC_CH_FRAME_DONE BIT(2)  /* xfft frame complete (not overflow) */

#define INTC_MER_ME  BIT(0)   /* Master Enable                */
#define INTC_MER_HIE BIT(1)   /* Hardware Interrupt Enable    */

/* ── Driver config / data structs ──────────────────────────────────────── */

struct fft_accel_config {
	uintptr_t dma_base;       /* AXI DMA base address          */
	uintptr_t tx_bram_base;   /* TX BRAM base address          */
	uintptr_t rx_bram_base;   /* RX BRAM base address          */
	uintptr_t intc_base;      /* AXI INTC base address         */
	uintptr_t gpio_base;      /* AXI GPIO base (xfft reset)    */
	uintptr_t coeff_bram_base; /* Filter coeff BRAM base, 0 if absent (no filter HW) */
	uint32_t  dma_max_bytes;  /* Maximum DMA transfer length, bytes */
	uint32_t  irq_num;        /* NEORV32 mext IRQ line         */
};

struct fft_accel_data {
	struct k_sem   irq_sem;
	struct k_mutex xfer_lock;
	int            last_error;    /* set by ISR on DMA error; read by transform */
	bool           last_overflow; /* read from GPIO overflow latch after IOC; cleared at transform start */
	bool           filter_bypass; /* shadow of GPIO ch1 bit1; true = forward FFT only */
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
 * gpio_data_word() — compose the GPIO ch1 output word.
 *
 * bit0 (GPIO_ARESETN) is the per-transform xfft reset gate; bit1
 * (GPIO_FILTER_BYPASS) selects the S2MM source (forward FFT vs filtered IFFT).
 * The reset sequence toggles bit0 while bit1 must hold its selected value, so
 * every GPIO_DATA write goes through here rather than writing a bare 0/1 (which
 * would clear the bypass bit mid-transform).  The shadow lives in data->
 * filter_bypass because the GPIO output channel is write-only.
 */
static inline uint32_t gpio_data_word(bool aresetn_high, bool filter_bypass)
{
	return (aresetn_high ? GPIO_ARESETN : 0u) |
	       (filter_bypass ? GPIO_FILTER_BYPASS : 0u);
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
	 * Fires once per completed FFT frame.  The overflow bit it carries
	 * (m_axis_status_tdata[0]) is captured by a fabric latch and read via
	 * GPIO_DATA2 in fft_accel_transform(), so no action is required here.
	 * The channel stays enabled so the IAR W1C clears the pending edge
	 * before the next transform. */
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
 * fft_accel_run() — shared transform worker for the FFT-only and filtered paths.
 *
 * The DMA / INTC / aresetn sequence is byte-for-byte identical whether or not
 * the filter is engaged; the ONLY difference is which datapath the fabric
 * routes to S2MM, selected by GPIO ch1 bit1.  Keeping a single worker (rather
 * than forking the load-bearing sequence) preserves every ordering invariant
 * in ACCEL_ARCH.md §3-§4.  @p filter_bypass is latched into data->filter_bypass
 * under the mutex so the reset-sequence GPIO writes carry the right selection.
 *
 * Serialised by an internal mutex: a second caller blocks until the first call
 * returns.  Not safe for use from ISR context.
 *
 * @param dev           FFT accelerator device
 * @param in            Input samples (re/im Q1.15), length n
 * @param out           Output buffer, same size
 * @param n             Transform size (must be 4096; other values return -EINVAL)
 * @param filter_bypass true = forward FFT bins to S2MM; false = filter + IFFT
 * @return 0 on success, negative errno on error or timeout
 */
static int fft_accel_run(const struct device *dev,
			 const struct fft_sample_t *in,
			 struct fft_sample_t *out,
			 size_t n,
			 bool filter_bypass)
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

	/* Defense-in-depth backstop, not the primary length check: n is already
	 * pinned to 4096 above, so byte_len is a constant 16384 and this only
	 * trips if the DTS dma-max-bytes prop is mis-set below the transform
	 * size.  Kept so a future variable-n path cannot silently overrun the
	 * DMA bound; it is intentionally redundant while n is fixed. */
	if (byte_len > cfg->dma_max_bytes) {
		return -EINVAL;
	}

	/* Serialise concurrent callers */
	k_mutex_lock(&data->xfer_lock, K_FOREVER);
	data->last_error     = 0;
	data->last_overflow  = false;
	data->filter_bypass  = filter_bypass;  /* drives GPIO ch1 bit1 in the reset seq */

	/* 1. Write input samples to TX BRAM */
	for (size_t i = 0; i < n; i++) {
		uint32_t word = ((uint32_t)(uint16_t)in[i].im << 16) |
				(uint32_t)(uint16_t)in[i].re;
		sys_write32(word, cfg->tx_bram_base + i * 4);
	}

	/* Ordering barrier: the TX-BRAM stores above and the DMA register
	 * writes below target *different* AXI slaves through the SmartConnect,
	 * which provides no global write-ordering guarantee.  sys_write32 is a
	 * volatile store (compiler ordering only), so without an explicit fence
	 * the MM2S LENGTH write that *triggers* the transfer (step 4) could
	 * overtake the final BRAM store and the DMA would read stale input for
	 * the last beat(s).  NEORV32 has no D-cache, so this is a store-ordering
	 * issue, not a coherency one; a full data-memory fence is sufficient. */
	barrier_dmem_fence_full();

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
	/* assert xfft reset (aresetn=0), holding the bypass selection for this
	 * transform */
	gpio_wr(cfg, GPIO_DATA, gpio_data_word(false, data->filter_bypass));
	k_busy_wait(1);                /* hold aresetn=0 for >=2 aclk cycles */

	/* Check each reset explicitly.  dma_reset_channel() returns 0 or a
	 * negative errno; bit-ORing two negative errnos (|=) only stays
	 * non-zero by twos-complement coincidence and discards the actual
	 * error code, so test them individually and propagate the real one. */
	int reset_err = dma_reset_channel(cfg, DMA_MM2S_DMACR);
	if (reset_err == 0) {
		reset_err = dma_reset_channel(cfg, DMA_S2MM_DMACR);
	}
	if (reset_err != 0) {
		/* release xfft reset before exit */
		gpio_wr(cfg, GPIO_DATA, gpio_data_word(true, data->filter_bypass));
		k_mutex_unlock(&data->xfer_lock);
		return reset_err;              /* -ETIMEDOUT, not a blanket -EIO */
	}

	/* release xfft reset (aresetn=1), bypass selection unchanged */
	gpio_wr(cfg, GPIO_DATA, gpio_data_word(true, data->filter_bypass));
	k_busy_wait(1);                /* let xfft pipeline come out of reset */

	/* Discard any stale completion left by a previously timed-out transfer.
	 *
	 * This MUST come after the DMA software reset above and before the
	 * channels are re-armed below.  A late ISR from a prior transfer can
	 * call k_sem_give right up until dma_reset_channel() halts the channel
	 * and de-asserts its introut line; resetting the semaphore here — once
	 * both channels are quiesced but before either is armed — guarantees the
	 * count is zero going into the wait, so a stale give cannot make the
	 * next k_sem_take return immediately on bogus data.  (Resetting before
	 * the DMA reset, as an earlier version did, left the ~4096-write fill
	 * window open for a stale give to slip through.) */
	k_sem_reset(&data->irq_sem);

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

	/* Ordering barrier: the S2MM IOC signals that the DMA has posted the
	 * output frame to RX BRAM, but the CPU's load path has no guaranteed
	 * ordering against those fabric-side writes.  Fence before the RX-BRAM
	 * read loop (step 7) so we observe the committed output rather than
	 * stale BRAM contents from a previous frame. */
	barrier_dmem_fence_full();

	int err = data->last_error;

	/* Sample the latched xfft overflow flag for this frame.  The fabric latch
	 * was cleared by the aresetn pulse in step 2 and is set on ANY tvalid &&
	 * overflow during the frame; it then holds until the NEXT aresetn pulse.
	 * Because nothing clears it until the next transform's reset, reading it
	 * after this frame's S2MM IOC is safe regardless of the intra-frame ordering
	 * of the status beat relative to the final data beat (PG109 does not pin
	 * that ordering).  Read it via the AXI GPIO input channel rather than the
	 * ISR, where the ch2 edge vs. latch timing would be racy.  See ACCEL_ARCH §2.3.
	 *
	 * bit0 is xfft_0's overflow; bit1 aggregates xfft_0 OR xfft_1 OR the filter
	 * normalizer saturation (only meaningful on the filter bitstream, where it
	 * also flags an overflow that occurred in the inverse stage during a
	 * filtered transform).  bit1 reads as 0 on a forward-only bitstream. */
	data->last_overflow =
		(gpio_rd(cfg, GPIO_DATA2) & (GPIO_OVERFLOW | GPIO_OVERFLOW_AGG)) != 0;

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
 * fft_accel_transform() — run one N-point complex forward FFT.
 *
 * Bypasses the filter/IFFT datapath, so out[] holds the raw frequency bins
 * (the pre-filter behaviour).  On the filter bitstream this is selected by
 * routing the forward-FFT output straight to S2MM; on a forward-only bitstream
 * the bypass bit is unimplemented and the result is identical.
 */
int fft_accel_transform(const struct device *dev,
			const struct fft_sample_t *in,
			struct fft_sample_t *out,
			size_t n)
{
	return fft_accel_run(dev, in, out, n, /*filter_bypass=*/true);
}

/**
 * fft_accel_transform_filtered() — run one N-point FFT → filter → IFFT.
 *
 * Selects the filtered datapath, so out[] holds the time-domain inverse of the
 * coefficient-scaled spectrum.  Load the coefficient table first with
 * fft_accel_load_coeffs(); with an all-pass table this reduces to a unity
 * round trip (out ≈ in within the documented LSB budget).
 */
int fft_accel_transform_filtered(const struct device *dev,
				 const struct fft_sample_t *in,
				 struct fft_sample_t *out,
				 size_t n)
{
	return fft_accel_run(dev, in, out, n, /*filter_bypass=*/false);
}

/**
 * fft_accel_load_coeffs() — program the per-bin complex filter coefficients.
 *
 * Writes the 4096-entry {im[31:16], re[15:0]} Q1.15 table into the fabric
 * coefficient BRAM, mirroring the TX-BRAM fill idiom (same packing, same
 * store-ordering fence rationale as ACCEL_ARCH.md §C1).  Held under xfer_lock
 * so it cannot race an in-flight transform's coeff reads.
 */
int fft_accel_load_coeffs(const struct device *dev,
			  const struct fft_sample_t *coeffs,
			  size_t n)
{
	if (!device_is_ready(dev)) {
		return -ENODEV;
	}

	const struct fft_accel_config *cfg = dev->config;
	struct fft_accel_data *data = dev->data;

	/* No coeff BRAM in this bitstream (forward-FFT-only build): the DTS node
	 * has no "coeff_bram" region, so the base is 0.  Fail explicitly rather
	 * than scribbling over address 0. */
	if (cfg->coeff_bram_base == 0) {
		return -ENOTSUP;
	}

	/* The coeff BRAM is sized for exactly one N=4096 frame. */
	if (n != 4096) {
		return -EINVAL;
	}

	k_mutex_lock(&data->xfer_lock, K_FOREVER);

	for (size_t i = 0; i < n; i++) {
		uint32_t word = ((uint32_t)(uint16_t)coeffs[i].im << 16) |
				(uint32_t)(uint16_t)coeffs[i].re;
		sys_write32(word, cfg->coeff_bram_base + i * 4);
	}

	/* Ordering barrier: the coeff-BRAM stores and the next transform's DMA
	 * trigger target different AXI slaves through the SmartConnect with no
	 * global write-ordering guarantee (identical reasoning to the TX-BRAM
	 * fence in fft_accel_run).  Fence so the full table is visible to the
	 * fabric complex-multiplier before any subsequent transform starts. */
	barrier_dmem_fence_full();

	k_mutex_unlock(&data->xfer_lock);
	return 0;
}

/**
 * fft_accel_set_filter_bypass() — select the S2MM output source.
 *
 * Updates the shadow and the GPIO ch1 output immediately (so an interactive
 * caller sees the change without a transform).  The next fft_accel_run() also
 * re-applies the shadow under the mutex, so the per-transform wrappers remain
 * authoritative.  Held under xfer_lock so a concurrent transform's
 * reset-sequence GPIO writes are not interleaved with this RMW.
 */
void fft_accel_set_filter_bypass(const struct device *dev, bool bypass)
{
	if (!device_is_ready(dev)) {
		return;
	}
	const struct fft_accel_config *cfg = dev->config;
	struct fft_accel_data *data = dev->data;

	k_mutex_lock(&data->xfer_lock, K_FOREVER);
	data->filter_bypass = bypass;
	/* Leave aresetn released (1); a transform re-pulses it as needed. */
	gpio_wr(cfg, GPIO_DATA, gpio_data_word(true, bypass));
	k_mutex_unlock(&data->xfer_lock);
}

/** fft_accel_get_filter_bypass() — return the current bypass selection. */
bool fft_accel_get_filter_bypass(const struct device *dev)
{
	if (!device_is_ready(dev)) {
		return true;  /* no device → behaves as forward-FFT-only */
	}
	const struct fft_accel_data *data = dev->data;
	return data->filter_bypass;
}

/**
 * fft_accel_get_last_overflow() — check whether the last transform overflowed.
 *
 * The xfft overflow bit (m_axis_status_tdata[0]) is captured by a fabric sticky
 * latch (cleared by the per-transform aresetn pulse) and read back over the AXI
 * GPIO input channel (GPIO_DATA2 bit 0) at the end of fft_accel_transform() —
 * NOT through the interrupt path (see ACCEL_ARCH.md §2.3).  This function
 * returns the value sampled during the most recent fft_accel_transform() call.
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
		/* coeff_bram is optional: present only on the filter bitstream.	\
		 * Absent → 0, and fft_accel_load_coeffs() returns -ENOTSUP. */	\
		.coeff_bram_base =						\
			COND_CODE_1(DT_INST_REG_HAS_NAME(inst, coeff_bram),	\
				(DT_INST_REG_ADDR_BY_NAME(inst, coeff_bram)),	\
				(0)),						\
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
		/* Default to forward-FFT-only behaviour: a freshly-booted		\
		 * filter bitstream then matches the pre-filter design until a		\
		 * filtered transform is explicitly requested.  Drive the GPIO		\
		 * (aresetn released, bypass selected) to match the shadow. */	\
		data->filter_bypass = true;					\
		gpio_wr(cfg, GPIO_DATA, gpio_data_word(true, true));		\
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
