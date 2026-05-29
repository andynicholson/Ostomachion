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
 * MMIO register window (matches fp_fft_pipe_bridge.vhd):
 *   0x9000_0000 (R) — pop one 32-bit sample from FIFO_IN
 *   0x9000_0004 (W) — push one 32-bit sample to FIFO_OUT
 *   0x9000_0008 (R) — status = {fifo_out_count[15:0], fifo_in_count[15:0]}
 *   0x9000_000C (W) — store HW FFT cycle count + bump frame counter
 *
 * Each FIFO sample is packed identically to the TX/RX BRAMs the HAL talks
 * to: bits[15:0] = re (Q1.15), bits[31:16] = im (Q1.15).
 *
 * Frame flow per iteration:
 *   1. Wait for FIFO_IN to hold a full frame (4096 samples).
 *   2. Pop the 4096 samples into a local Q1.15 complex buffer.
 *   3. Call fft_accel_transform() and measure HW cycles.
 *   4. Wait for the host to have drained the previous frame from
 *      FIFO_OUT (status.out_count == 0).
 *   5. Publish HW cycles to WireOut 0x25 and bump the frame counter on
 *      WireOut 0x26 (a single MMIO write does both).
 *   6. Push the 4096 output samples to FIFO_OUT for the host.
 *
 * The host polls fifo_out_count >= 4096 to know when to read the frame.
 * Because step 5 runs before step 6, the cycles register is guaranteed
 * fresh by the time the host sees the count rise.
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
#define FFT_PIPE_BASE     0x90000000UL
#define FFT_PIPE_POP      (FFT_PIPE_BASE + 0x0)   /* R: pop one sample      */
#define FFT_PIPE_PUSH     (FFT_PIPE_BASE + 0x4)   /* W: push one sample     */
#define FFT_PIPE_STATUS   (FFT_PIPE_BASE + 0x8)   /* R: fifo counts         */
#define FFT_PIPE_PUBLISH  (FFT_PIPE_BASE + 0xC)   /* W: cycles + frame bump */

#define STATUS_IN_COUNT(s)   ((uint32_t)((s) & 0xFFFFU))
#define STATUS_OUT_COUNT(s)  ((uint32_t)(((s) >> 16) & 0xFFFFU))

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

		/* 3. Run the HW FFT and measure compute cycles only. */
		uint32_t t0 = k_cycle_get_32();
		int rc = fft_accel_transform(dev, g_demo_in, g_demo_out, FFT_N);
		uint32_t t1 = k_cycle_get_32();

		if (rc != 0) {
			LOG_ERR("frame %u: fft_accel_transform failed: %d",
				frame_n, rc);
			/* Bump the frame counter so the host sees forward
			 * progress and can read the (zero) cycles value as a
			 * sentinel for "transform failed". */
			sys_write32(0, FFT_PIPE_PUBLISH);
			continue;
		}

		uint32_t hw_cycles = t1 - t0;

		/* 4. Wait until the host has consumed any prior output frame.
		 *    On the first iteration FIFO_OUT is empty, so this returns
		 *    immediately. */
		while (STATUS_OUT_COUNT(sys_read32(FFT_PIPE_STATUS)) != 0) {
			k_msleep(1);
		}

		/* 5. Publish HW cycles BEFORE pushing samples so the host
		 *    reads a fresh value when fifo_out_count rises to FFT_N. */
		sys_write32(hw_cycles, FFT_PIPE_PUBLISH);

		/* 6. Push the result to FIFO_OUT.  Same {im, re} packing. */
		for (int i = 0; i < FFT_N; i++) {
			uint32_t w = ((uint32_t)(uint16_t)g_demo_out[i].im << 16)
				   |  (uint32_t)(uint16_t)g_demo_out[i].re;
			sys_write32(w, FFT_PIPE_PUSH);
		}

		frame_n++;
		if ((frame_n & 0x1FU) == 0U) {
			LOG_INF("frames=%u  hw=%u cycles (%u us)",
				frame_n, hw_cycles, cycles_to_us(hw_cycles));
		}
	}
}

K_THREAD_DEFINE(fft_demo_tid, 4096, fft_demo_thread,
		NULL, NULL, NULL, 5, 0, 0);
