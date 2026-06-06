/*
 * fft_demo_main.c — Realtime FFT-accelerator demo driver thread
 * Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
 *
 * Compiled when CONFIG_FFT_DEMO=y (see zephyr_app/Kconfig + prj_demo.conf).
 *
 * Drives the existing FFT hardware accelerator (Xilinx xfft via AXI DMA)
 * from sample frames pushed across the FrontPanel BTPipe endpoints that
 * the fp_fft_pipe_bridge.vhd RTL module exposes at XBUS region
 * 0x9000_0000.  The CPU stays in the loop: it MMIO-copies each input
 * frame from FIFO_IN into TX BRAM (inside the HAL via fft_accel_transform),
 * runs the transform, and MMIO-copies the result from the driver's output
 * buffer into FIFO_OUT.
 *
 * MMIO register window (matches fp_fft_pipe_bridge.vhd — 32-byte window):
 *   0x9000_0000 (R) — pop one 32-bit sample from FIFO_IN
 *   0x9000_0004 (W) — push one 32-bit sample to FIFO_OUT
 *   0x9000_0008 (R) — status = {fifo_out_count[15:0], fifo_in_count[15:0]}
 *   0x9000_000C (W) — store HW FFT cycle count + bump frame counter
 *   0x9000_0010 (R) — filter control word from the host (WireIn 0x01)
 *   0x9000_0014 (W) — filter status echo to the host (WireOut 0x28)
 *
 * Each FIFO sample is packed identically to the TX/RX BRAMs the HAL talks
 * to: bits[15:0] = re (Q1.15), bits[31:16] = im (Q1.15).
 *
 * Host-programmable spectral filter:
 *   The host selects a brick-wall filter (LP/HP/BP/notch) by writing a control
 *   word to WireIn 0x01, which this thread reads at 0x9000_0010.  On a confirmed
 *   change the thread synthesises the per-bin complex mask and loads it into the
 *   coeff BRAM (fft_accel_load_coeffs), then runs fft_accel_transform_filtered
 *   instead of the plain forward FFT — so the output frame is the FILTERED
 *   TIME-DOMAIN signal (inverse transform of H[k]·X[k]) rather than frequency
 *   bins.  The thread echoes the applied mode / availability / overflow back to
 *   the host on WireOut 0x28 so the host knows how to interpret the frame.
 *
 *   Control word (0x9000_0010):
 *     [2:0]   mode  (0=bypass/off, 1=LP, 2=HP, 3=BP, 4=notch)
 *     [14:3]  lo    (folded-frequency bin, 0..2048)
 *     [26:15] hi    (folded-frequency bin, 0..2048)
 *   Status word (0x9000_0014):
 *     [2:0] applied_mode  [3] filter_avail  [4] last_overflow  [5] last_failed
 *
 * Frame flow per iteration:
 *   1. Wait for FIFO_IN to hold a full frame (4096 samples).
 *   2. Pop the 4096 samples into a local Q1.15 complex buffer.
 *   3. Read + debounce the filter control word; on a confirmed change, reload
 *      the coeff BRAM (mode!=bypass) and record availability.
 *   4. Run the selected transform (forward FFT, or FFT→filter→IFFT) and measure
 *      HW cycles.
 *   5. Wait for the host to have drained the previous frame from
 *      FIFO_OUT (status.out_count == 0).
 *   6. Publish HW cycles to WireOut 0x25 + bump the frame counter (WireOut 0x26)
 *      and write the filter status echo to WireOut 0x28.
 *   7. Push the 4096 output samples to FIFO_OUT for the host.
 *
 * The host polls fifo_out_count >= 4096 to know when to read the frame.
 * Because step 6 runs before step 7, the cycles + status registers are
 * guaranteed fresh by the time the host sees the count rise.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/sys_io.h>

#include <zephyr/drivers/misc/fft_accel.h>

#include <stdint.h>

LOG_MODULE_REGISTER(fft_demo, LOG_LEVEL_INF);

#define FFT_N             4096

/* FrontPanel FFT pipe bridge MMIO map (xem7310_top.vhd region 0x9000_0000) */
#define FFT_PIPE_BASE        0x90000000UL
#define FFT_PIPE_POP         (FFT_PIPE_BASE + 0x0)   /* R: pop one sample      */
#define FFT_PIPE_PUSH        (FFT_PIPE_BASE + 0x4)   /* W: push one sample     */
#define FFT_PIPE_STATUS      (FFT_PIPE_BASE + 0x8)   /* R: fifo counts         */
#define FFT_PIPE_PUBLISH     (FFT_PIPE_BASE + 0xC)   /* W: cycles + frame bump */
#define FFT_PIPE_FILTER_CFG  (FFT_PIPE_BASE + 0x10)  /* R: host filter cfg word */
#define FFT_PIPE_APPLIED     (FFT_PIPE_BASE + 0x14)  /* W: filter status echo   */

#define STATUS_IN_COUNT(s)   ((uint32_t)((s) & 0xFFFFU))
#define STATUS_OUT_COUNT(s)  ((uint32_t)(((s) >> 16) & 0xFFFFU))

/* Filter control word (FFT_PIPE_FILTER_CFG) field accessors. */
#define CFG_MODE(c)          ((uint32_t)((c) & 0x7U))
#define CFG_LO(c)            ((uint32_t)(((c) >> 3) & 0xFFFU))
#define CFG_HI(c)            ((uint32_t)(((c) >> 15) & 0xFFFU))

/* Filter modes (must match the host control-word encoding). */
#define FILT_BYPASS  0U
#define FILT_LP      1U
#define FILT_HP      2U
#define FILT_BP      3U
#define FILT_NOTCH   4U

/* Filter status word (FFT_PIPE_APPLIED) bit fields. */
#define STAT_AVAIL     BIT(3)
#define STAT_OVERFLOW  BIT(4)
#define STAT_FAILED    BIT(5)

/* Shared sample buffers — kept at file scope to avoid 32 KB on the stack. */
static struct fft_sample_t g_demo_in[FFT_N];
static struct fft_sample_t g_demo_out[FFT_N];

static inline uint32_t cycles_to_us(uint32_t cycles)
{
#if CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC > 0
	return (uint32_t)((uint64_t)cycles * 1000000U /
			  CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
#else
	return cycles;
#endif
}

/* Folded (physical) frequency index — matches filter_mask.hpp folded_freq()
 * and fft_shell.c folded_freq_sh().  Bin k mirrors to N-k; the lower of the two
 * is the physical frequency, giving Hermitian-symmetric masks. */
static inline int demo_folded_freq(int k, int n)
{
	int mirror = n - k;
	return (k <= mirror) ? k : mirror;
}

/* Synthesise a brick-wall mask for `mode` (lo/hi folded-bin edges) into out[].
 * Bit-for-bit identical to fft_shell.c's cmd_fft_filter loop and to the host's
 * synth_mask() so the on-screen H[k] overlay matches the fabric exactly.
 * Passband bins get { 0x7FFF, 0 }; stopband bins { 0, 0 }. */
static void demo_synth_mask(uint32_t mode, int lo, int hi,
			    struct fft_sample_t *out)
{
	for (int k = 0; k < FFT_N; k++) {
		int f = demo_folded_freq(k, FFT_N);
		bool pass;
		switch (mode) {
		case FILT_LP:    pass = (f <= hi);            break;
		case FILT_HP:    pass = (f >= lo);            break;
		case FILT_BP:    pass = (f >= lo && f <= hi); break;
		case FILT_NOTCH: pass = (f < lo  || f > hi);  break;
		default:         pass = false;                break;
		}
		out[k].re = pass ? (int16_t)0x7FFF : (int16_t)0;
		out[k].im = 0;
	}
}

static void fft_demo_thread(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		LOG_ERR("fft_accel not ready — check DTS overlay and that the "
			"accelerator bitstream is loaded");
		return;
	}

	LOG_INF("FFT demo loop ready (N=%d, pipe @ 0x%08lx)",
		FFT_N, (unsigned long)FFT_PIPE_BASE);

	uint32_t frame_n = 0;
	/* Filter state.  applied_cfg starts at all-ones (never a valid cfg word —
	 * mode field 0x7 is unused) so the first real cfg, including a host's
	 * explicit "bypass" at startup, always counts as a change and is acted on.
	 * filter_avail tracks whether this bitstream actually has the coeff BRAM
	 * (load_coeffs returns -ENOTSUP on a forward-FFT-only build). */
	uint32_t applied_cfg = 0xFFFFFFFFU;
	uint32_t applied_mode = FILT_BYPASS;
	bool filter_avail = true;

	while (true) {
		/* 1. Wait for a complete input frame in FIFO_IN. */
		uint32_t status;
		do {
			status = sys_read32(FFT_PIPE_STATUS);
			if (STATUS_IN_COUNT(status) < FFT_N) {
				k_msleep(1);
			}
		} while (STATUS_IN_COUNT(status) < FFT_N);

		/* 2. Pop the frame from FIFO_IN.  Each 32-bit word carries
		 *    {im[15:0], re[15:0]} — the same packing the HAL uses
		 *    when writing TX BRAM (ACCEL_ARCH.md §3 step 2). */
		for (int i = 0; i < FFT_N; i++) {
			uint32_t w = sys_read32(FFT_PIPE_POP);
			g_demo_in[i].re = (int16_t)(w & 0xFFFFU);
			g_demo_in[i].im = (int16_t)((w >> 16) & 0xFFFFU);
		}

		/* 3. Read + debounce the host filter control word.  The host's
		 *    UpdateWireIns can momentarily tear the multi-field word, so we
		 *    require two reads (straddling the frame pop above, which gives
		 *    them ample separation) to agree before acting — and only when the
		 *    confirmed value differs from what we last applied.  On a confirmed
		 *    change with a non-bypass mode we synthesise the brick-wall mask
		 *    into g_demo_out and load it into the coeff BRAM.
		 *
		 *    Reusing g_demo_out as the coeff scratch is safe ONLY because
		 *    fft_accel_load_coeffs() is synchronous: it copies the table into
		 *    fabric BRAM and fences before returning, and the previous frame's
		 *    output was already pushed to FIFO_OUT last iteration.  The
		 *    transform in step 4 then overwrites g_demo_out.  If coeff loading
		 *    ever became async/DMA-backed, this reuse would break — use a
		 *    dedicated buffer then (DMEM permitting). */
		uint32_t cfg_a = sys_read32(FFT_PIPE_FILTER_CFG);
		uint32_t cfg_b = sys_read32(FFT_PIPE_FILTER_CFG);
		if (cfg_a == cfg_b && cfg_a != applied_cfg) {
			uint32_t mode = CFG_MODE(cfg_a);
			if (mode != FILT_BYPASS) {
				demo_synth_mask(mode, (int)CFG_LO(cfg_a),
						(int)CFG_HI(cfg_a), g_demo_out);
				int lrc = fft_accel_load_coeffs(dev, g_demo_out, FFT_N);
				if (lrc == -ENOTSUP) {
					/* Forward-FFT-only bitstream: no coeff BRAM.
					 * Fall back to plain FFT and tell the host the
					 * filter datapath is unavailable. */
					filter_avail = false;
					applied_mode = FILT_BYPASS;
				} else if (lrc != 0) {
					LOG_ERR("frame %u: load_coeffs failed: %d",
						frame_n, lrc);
					filter_avail = true;
					applied_mode = FILT_BYPASS;
				} else {
					filter_avail = true;
					applied_mode = mode;
				}
			} else {
				applied_mode = FILT_BYPASS;
			}
			applied_cfg = cfg_a;
			LOG_INF("filter cfg=0x%08x → mode=%u avail=%d",
				cfg_a, applied_mode, (int)filter_avail);
		}

		/* 4. Run the selected transform and measure compute cycles only.
		 *    Bypass / unavailable-filter → forward FFT (frequency bins);
		 *    otherwise FFT → filter → IFFT (filtered TIME-DOMAIN output). */
		bool filtered = (applied_mode != FILT_BYPASS) && filter_avail;
		uint32_t t0 = k_cycle_get_32();
		int rc = filtered
			? fft_accel_transform_filtered(dev, g_demo_in, g_demo_out, FFT_N)
			: fft_accel_transform(dev, g_demo_in, g_demo_out, FFT_N);
		uint32_t t1 = k_cycle_get_32();

		if (rc != 0) {
			LOG_ERR("frame %u: transform failed: %d", frame_n, rc);
			/* Tell the host this frame failed (status echo) and bump the
			 * frame counter with a zero-cycles sentinel so it sees forward
			 * progress without reading stale output. */
			uint32_t st = applied_mode
				    | (filter_avail ? STAT_AVAIL : 0U)
				    | STAT_FAILED;
			sys_write32(st, FFT_PIPE_APPLIED);
			sys_write32(0, FFT_PIPE_PUBLISH);
			continue;
		}

		uint32_t hw_cycles = t1 - t0;
		bool overflow = fft_accel_get_last_overflow(dev);

		/* 5. Wait until the host has consumed any prior output frame.
		 *    On the first iteration FIFO_OUT is empty, so this returns
		 *    immediately. */
		while (STATUS_OUT_COUNT(sys_read32(FFT_PIPE_STATUS)) != 0) {
			k_msleep(1);
		}

		/* 6. Publish HW cycles + filter status BEFORE pushing samples so the
		 *    host reads fresh values when fifo_out_count rises to FFT_N.  The
		 *    status echo lets the host interpret the frame correctly (freq bins
		 *    vs filtered time samples) and surface overflow. */
		uint32_t st = applied_mode
			    | (filter_avail ? STAT_AVAIL : 0U)
			    | (overflow ? STAT_OVERFLOW : 0U);
		sys_write32(st, FFT_PIPE_APPLIED);
		sys_write32(hw_cycles, FFT_PIPE_PUBLISH);

		/* 7. Push the result to FIFO_OUT.  Same {im, re} packing. */
		for (int i = 0; i < FFT_N; i++) {
			uint32_t w = ((uint32_t)(uint16_t)g_demo_out[i].im << 16)
				   |  (uint32_t)(uint16_t)g_demo_out[i].re;
			sys_write32(w, FFT_PIPE_PUSH);
		}

		frame_n++;
		if ((frame_n & 0x1FU) == 0U) {
			LOG_INF("frames=%u  hw=%u cycles (%u us)  mode=%u%s",
				frame_n, hw_cycles, cycles_to_us(hw_cycles),
				applied_mode, overflow ? " OVF" : "");
		}
	}
}

K_THREAD_DEFINE(fft_demo_tid, 4096, fft_demo_thread,
		NULL, NULL, NULL, 5, 0, 0);
