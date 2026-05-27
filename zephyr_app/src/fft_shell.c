/*
 * fft_shell.c — Zephyr shell "fft" command
 * Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
 *
 * Provides interactive access to the FFT hardware accelerator from the
 * Zephyr shell (interactive / development firmware image, prj_shell.conf).
 *
 * Shell session examples:
 *   uart:~$ fft dc
 *   [FFT] Input: DC (all 0.5 + 0j, 4096 points)
 *   [FFT] Done in 240 us.  Bin 0: 16384  max_other: 0  PASS
 *
 *   uart:~$ fft sine 8
 *   [FFT] Input: sine wave at bin 8 (4096 points)
 *   [FFT] Done in 250 us.  Peak bin: 8  magnitude: 8192  PASS
 *
 *   uart:~$ fft run 4096
 *   [FFT] Input: DC (4096 points)
 *   [FFT] Done in 240 us.  Peak bin: 0  magnitude: 16384
 */

#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/misc/fft_accel.h>
#include <zephyr/sys/sys_io.h>

#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static inline uint32_t cycles_to_us(uint32_t c0, uint32_t c1)
{
#if CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC > 0
	return (uint32_t)((uint64_t)(c1 - c0) * 1000000 /
			  CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
#else
	ARG_UNUSED(c0);
	ARG_UNUSED(c1);
	return 0;
#endif
}

/* int64_t avoids overflow when re = im = INT16_MIN */
static int64_t fft_mag_sq(int16_t re, int16_t im)
{
	return (int64_t)re * re + (int64_t)im * im;
}

static uint32_t fft_magnitude(int16_t re, int16_t im)
{
	/* Integer sqrt via Newton iteration — good enough for display */
	int64_t sq = fft_mag_sq(re, im);
	if (sq <= 0) {
		return 0;
	}
	uint32_t x = (uint32_t)sq;
	uint32_t r = x;
	uint32_t r1 = (r + x / r) / 2;
	while (r1 < r) {
		r  = r1;
		r1 = (r + x / r) / 2;
	}
	return r;
}

/* Returns peak bin index and writes magnitude to *mag_out */
static int fft_peak(const struct fft_sample_t *out, int n, uint32_t *mag_out)
{
	int peak_bin = 0;
	uint32_t peak_mag = 0;

	for (int k = 0; k < n; k++) {
		uint32_t m = fft_magnitude(out[k].re, out[k].im);
		if (m > peak_mag) {
			peak_mag = m;
			peak_bin = k;
		}
	}
	if (mag_out) {
		*mag_out = peak_mag;
	}
	return peak_bin;
}

#define FFT_N 4096

/* ── Shared sample buffers — also used by test_runner.c in the shell build ──
 * Not static: extern declarations in test_runner.c reference these.
 * Keeping them in a single translation unit avoids the linker placing
 * duplicate 16 KB arrays in BSS (one per .o that declares a static version).
 */
struct fft_sample_t g_fft_in[FFT_N];
struct fft_sample_t g_fft_out[FFT_N];

/* ── "fft dc" ─────────────────────────────────────────────────────────────── */

static int cmd_fft_dc(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		shell_error(sh, "fft_accel not ready");
		return -ENODEV;
	}

	for (int i = 0; i < FFT_N; i++) {
		g_fft_in[i].re = 16384;  /* 0.5 in Q1.15 */
		g_fft_in[i].im = 0;
	}

	shell_print(sh, "[FFT] Input: DC (all 0.5 + 0j, %d points)", FFT_N);

	uint32_t t0 = k_cycle_get_32();
	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, FFT_N);
	uint32_t t1 = k_cycle_get_32();

	if (rc != 0) {
		shell_error(sh, "[FFT] transform failed: %d", rc);
		return rc;
	}

	uint32_t us = cycles_to_us(t0, t1);

	uint32_t bin0_mag = fft_magnitude(g_fft_out[0].re, g_fft_out[0].im);
	uint32_t max_other = 0;
	for (int k = 1; k < FFT_N; k++) {
		uint32_t m = fft_magnitude(g_fft_out[k].re, g_fft_out[k].im);
		if (m > max_other) {
			max_other = m;
		}
	}

	bool pass = (bin0_mag > max_other * 10);  /* bin 0 dominates by 10× */
	shell_print(sh,
		    "[FFT] Done in %u us.  Bin 0: %u  max_other: %u  %s",
		    us, bin0_mag, max_other, pass ? "PASS" : "FAIL");
	return pass ? 0 : -EIO;
}

/* ── "fft sine <bin>" ─────────────────────────────────────────────────────── */

static int cmd_fft_sine(const struct shell *sh, size_t argc, char **argv)
{
	if (argc < 2) {
		shell_print(sh, "Usage: fft sine <bin>  (0..%d)", FFT_N / 2 - 1);
		return -EINVAL;
	}

	int target_bin = atoi(argv[1]);
	if (target_bin < 0 || target_bin >= FFT_N / 2) {
		shell_error(sh, "bin must be 0..%d", FFT_N / 2 - 1);
		return -EINVAL;
	}

	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		shell_error(sh, "fft_accel not ready");
		return -ENODEV;
	}

	/* Use float: NEORV32 has no double-precision FPU */
	for (int k = 0; k < FFT_N; k++) {
		float angle = 2.0f * 3.14159265f * target_bin * k / (float)FFT_N;
		g_fft_in[k].re = (int16_t)(16384.0f * cosf(angle));
		g_fft_in[k].im = 0;  /* real cosine — symmetric spectrum */
	}

	shell_print(sh, "[FFT] Input: cosine at bin %d (%d points)",
		    target_bin, FFT_N);

	uint32_t t0 = k_cycle_get_32();
	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, FFT_N);
	uint32_t t1 = k_cycle_get_32();

	if (rc != 0) {
		shell_error(sh, "[FFT] transform failed: %d", rc);
		return rc;
	}

	uint32_t us = cycles_to_us(t0, t1);

	uint32_t peak_mag;
	int peak_bin = fft_peak(g_fft_out, FFT_N, &peak_mag);

	/* A real cosine has a symmetric spectrum: equal peaks at target_bin and
	 * its mirror at FFT_N - target_bin.  Either bin is a valid result. */
	int lo     = (target_bin > 0) ? (target_bin - 1) : 0;
	int mirror = FFT_N - target_bin;
	bool pass = (peak_bin >= lo        && peak_bin <= target_bin + 1) ||
		    (peak_bin >= mirror - 1 && peak_bin <= mirror + 1);
	shell_print(sh,
		    "[FFT] Done in %u us.  Peak bin: %d  magnitude: %u  %s",
		    us, peak_bin, peak_mag, pass ? "PASS" : "FAIL");

	/* ── Pipeline-latency diagnostic ─────────────────────────────────────
	 * Theory: the xfft pipelined streaming core asserts m_axis_data_tvalid
	 * immediately, outputting L zeros while the pipeline fills.  The DMA
	 * S2MM captures those L zeros before X[0] arrives, shifting the output
	 * by L positions: X[target_bin] lands at out[L + target_bin].
	 *
	 * Print selected bins to confirm/deny this:
	 *   out[0]          — should be 0 if shifted (pipeline-fill zero)
	 *   out[target_bin] — should be 0 if shifted (still in garbage range)
	 *   out[peak_bin]   — the actual observed maximum
	 *   out[peak_bin - target_bin] — if shift = L this equals X[0]; its
	 *                    magnitude should be near zero for a pure cosine
	 *   out[mirror]     — should be 0 (mirror beyond capture window if shifted)
	 */
	int shift_probe = peak_bin - target_bin;
	shell_print(sh, "[FFT-DIAG] out[   0]: re=%6d im=%6d mag=%u",
		    g_fft_out[0].re, g_fft_out[0].im,
		    fft_magnitude(g_fft_out[0].re, g_fft_out[0].im));
	if (target_bin > 0 && target_bin < FFT_N) {
		shell_print(sh, "[FFT-DIAG] out[%4d]: re=%6d im=%6d mag=%u  (target)",
			    target_bin,
			    g_fft_out[target_bin].re, g_fft_out[target_bin].im,
			    fft_magnitude(g_fft_out[target_bin].re,
					  g_fft_out[target_bin].im));
	}
	if (shift_probe > 0 && shift_probe < FFT_N) {
		shell_print(sh, "[FFT-DIAG] out[%4d]: re=%6d im=%6d mag=%u  (peak-target=shift probe X[0]?)",
			    shift_probe,
			    g_fft_out[shift_probe].re, g_fft_out[shift_probe].im,
			    fft_magnitude(g_fft_out[shift_probe].re,
					  g_fft_out[shift_probe].im));
	}
	shell_print(sh, "[FFT-DIAG] out[%4d]: re=%6d im=%6d mag=%u  (peak)",
		    peak_bin,
		    g_fft_out[peak_bin].re, g_fft_out[peak_bin].im, peak_mag);
	if (mirror > 0 && mirror < FFT_N) {
		shell_print(sh, "[FFT-DIAG] out[%4d]: re=%6d im=%6d mag=%u  (mirror)",
			    mirror,
			    g_fft_out[mirror].re, g_fft_out[mirror].im,
			    fft_magnitude(g_fft_out[mirror].re,
					  g_fft_out[mirror].im));
	}

	return pass ? 0 : -EIO;
}

/* ── "fft run [n_points]" ─────────────────────────────────────────────────── */

static int cmd_fft_run(const struct shell *sh, size_t argc, char **argv)
{
	int n = FFT_N;
	if (argc >= 2) {
		n = atoi(argv[1]);
		if (n != FFT_N) {
			shell_error(sh, "Only n=%d supported by this hardware", FFT_N);
			return -EINVAL;
		}
	}

	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		shell_error(sh, "fft_accel not ready");
		return -ENODEV;
	}

	/* DC input for a simple sanity run */
	for (int i = 0; i < n; i++) {
		g_fft_in[i].re = 16384;
		g_fft_in[i].im = 0;
	}

	shell_print(sh, "[FFT] Input: DC (%d points)", n);

	uint32_t t0 = k_cycle_get_32();
	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, (size_t)n);
	uint32_t t1 = k_cycle_get_32();

	if (rc != 0) {
		shell_error(sh, "[FFT] transform failed: %d", rc);
		return rc;
	}

	uint32_t us = cycles_to_us(t0, t1);

	uint32_t peak_mag;
	int peak_bin = fft_peak(g_fft_out, FFT_N, &peak_mag);

	shell_print(sh,
		    "[FFT] Done in %u us.  Peak bin: %d  magnitude: %u",
		    us, peak_bin, peak_mag);
	return 0;
}

/* ── "fft diag" — pipeline latency probe ────────────────────────────────── */

static int cmd_fft_diag(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		shell_error(sh, "fft_accel not ready");
		return -ENODEV;
	}

	/* DC input: FFT should give a single peak at bin 0.
	 * If the xfft pipeline fills with zeros before X[0] appears (pipeline
	 * latency shift), the DC peak will NOT be at out[0] — it will be at
	 * out[L] where L is the pipeline latency (number of garbage zero samples
	 * captured before the first valid FFT output). */
	for (int i = 0; i < FFT_N; i++) {
		g_fft_in[i].re = 16384;
		g_fft_in[i].im = 0;
	}

	shell_print(sh, "[FFT-DIAG] DC input, searching for peak across all bins...");

	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, FFT_N);
	if (rc != 0) {
		shell_error(sh, "[FFT] transform failed: %d", rc);
		return rc;
	}

	uint32_t peak_mag;
	int peak_bin = fft_peak(g_fft_out, FFT_N, &peak_mag);

	/* Read RX BRAM[0..7] directly — bypasses the driver's BRAM skip so we
	 * can see exactly what the DMA wrote, independent of any skip offset. */
	static const uintptr_t rx_bram =
		DT_REG_ADDR_BY_NAME(DT_NODELABEL(fft_accel), rx_bram);
	shell_print(sh, "[FFT-DIAG] Raw RX BRAM[0..7] (direct read, no skip):");
	for (int k = 0; k < 8; k++) {
		uint32_t w  = sys_read32(rx_bram + k * 4);
		int16_t  re = (int16_t)(w & 0xFFFFu);
		int16_t  im = (int16_t)(w >> 16);
		uint32_t m  = fft_magnitude(re, im);
		shell_print(sh, "  BRAM[%d]: 0x%08x  re=%6d im=%6d mag=%u",
			    k, w, re, im, m);
	}

	/* Print out[0..7] unconditionally so we can see where the DC energy lands
	 * regardless of where fft_peak reports the maximum. */
	shell_print(sh, "[FFT-DIAG] out[0..7] (via driver, with skip applied):");
	for (int k = 0; k < 8; k++) {
		uint32_t m = fft_magnitude(g_fft_out[k].re, g_fft_out[k].im);
		shell_print(sh, "  out[%4d]: re=%6d im=%6d mag=%u",
			    k, g_fft_out[k].re, g_fft_out[k].im, m);
	}

	/* Print bin 0 and the actual peak (they should be the same). */
	shell_print(sh, "[FFT-DIAG] out[   0]: re=%6d im=%6d mag=%u  (expected DC peak)",
		    g_fft_out[0].re, g_fft_out[0].im,
		    fft_magnitude(g_fft_out[0].re, g_fft_out[0].im));
	shell_print(sh, "[FFT-DIAG] out[%4d]: re=%6d im=%6d mag=%u  (actual peak)",
		    peak_bin,
		    g_fft_out[peak_bin].re, g_fft_out[peak_bin].im, peak_mag);

	/* Print a window of 8 bins around the actual peak. */
	int lo = (peak_bin > 4) ? (peak_bin - 4) : 0;
	int hi = (peak_bin + 4 < FFT_N) ? (peak_bin + 4) : FFT_N - 1;
	shell_print(sh, "[FFT-DIAG] Bins %d..%d around peak:", lo, hi);
	for (int k = lo; k <= hi; k++) {
		uint32_t m = fft_magnitude(g_fft_out[k].re, g_fft_out[k].im);
		shell_print(sh, "  out[%4d]: re=%6d im=%6d mag=%u%s",
			    k, g_fft_out[k].re, g_fft_out[k].im, m,
			    (k == peak_bin) ? " ← PEAK" : "");
	}

	/* PASS requires peak at bin 0 AND dominant magnitude (> 10× any other bin).
	 * A vacuous "PASS" where all bins are ~0 and peak_bin happens to be 0
	 * would mean the DC energy is missing entirely. */
	uint32_t bin0_mag = fft_magnitude(g_fft_out[0].re, g_fft_out[0].im);
	uint32_t max_other = 0;
	for (int k = 1; k < FFT_N; k++) {
		uint32_t m = fft_magnitude(g_fft_out[k].re, g_fft_out[k].im);
		if (m > max_other) max_other = m;
	}
	bool pass = (peak_bin == 0) && (bin0_mag > max_other * 10);
	shell_print(sh, "[FFT-DIAG] DC peak at bin %d  mag=%u  max_other=%u  %s",
		    peak_bin, peak_mag, max_other,
		    pass ? "PASS" : "FAIL");
	return pass ? 0 : -EIO;
}

/* ── Shell command registration ──────────────────────────────────────────── */

SHELL_STATIC_SUBCMD_SET_CREATE(fft_sub,
	SHELL_CMD_ARG(run,  NULL,
		      "fft run [n_points]      — transform DC input (n must be 4096)",
		      cmd_fft_run,  1, 1),
	SHELL_CMD_ARG(sine, NULL,
		      "fft sine <bin>          — cosine at given bin (0..2047)",
		      cmd_fft_sine, 2, 0),
	SHELL_CMD_ARG(dc,   NULL,
		      "fft dc                  — DC input, verify bin 0",
		      cmd_fft_dc,   1, 0),
	SHELL_CMD_ARG(diag, NULL,
		      "fft diag                — DC input, find pipeline latency shift",
		      cmd_fft_diag, 1, 0),
	SHELL_SUBCMD_SET_END);

SHELL_CMD_REGISTER(fft, &fft_sub, "FFT hardware accelerator", NULL);
