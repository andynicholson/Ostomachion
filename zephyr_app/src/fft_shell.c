/*
 * fft_shell.c — Zephyr shell "fft" command
 * Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
 *
 * Provides interactive access to the FFT hardware accelerator from the
 * Zephyr shell (interactive / development firmware image, prj_shell.conf).
 *
 * Shell session examples:
 *   uart:~$ fft dc
 *   [FFT] Input: DC (all 0.5 + 0j)
 *   [FFT] Done in 87 us.  Bin 0: 32512  all others < 200  PASS
 *
 *   uart:~$ fft sine 8
 *   [FFT] Input: sine wave at bin 8
 *   [FFT] Done in 89 us.  Peak bin: 8  magnitude: 31940  PASS
 *
 *   uart:~$ fft run 64
 *   [FFT] Input: DC (64 points)
 *   [FFT] Done in 87 us.  Peak bin: 0  magnitude: 32512
 */

#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/misc/fft_accel.h>

#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

/* ── Helpers ─────────────────────────────────────────────────────────────── */

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

/* ── Static sample buffers (avoid stack overflow in shell thread) ─────────── */
static struct fft_sample_t g_fft_in[64];
static struct fft_sample_t g_fft_out[64];

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

	for (int i = 0; i < 64; i++) {
		g_fft_in[i].re = 16384;  /* 0.5 in Q1.15 */
		g_fft_in[i].im = 0;
	}

	shell_print(sh, "[FFT] Input: DC (all 0.5 + 0j, 64 points)");

	uint32_t t0 = k_cycle_get_32();
	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, 64);
	uint32_t t1 = k_cycle_get_32();

	if (rc != 0) {
		shell_error(sh, "[FFT] transform failed: %d", rc);
		return rc;
	}

#if CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC > 0
	uint32_t us = (uint64_t)(t1 - t0) * 1000000 /
		      CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC;
#else
	uint32_t us = 0;
#endif

	uint32_t bin0_mag = fft_magnitude(g_fft_out[0].re, g_fft_out[0].im);
	uint32_t max_other = 0;
	for (int k = 1; k < 64; k++) {
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
		shell_print(sh, "Usage: fft sine <bin>  (0..63)");
		return -EINVAL;
	}

	int target_bin = atoi(argv[1]);
	if (target_bin < 0 || target_bin >= 64) {
		shell_error(sh, "bin must be 0..63");
		return -EINVAL;
	}

	const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
	if (!device_is_ready(dev)) {
		shell_error(sh, "fft_accel not ready");
		return -ENODEV;
	}

	/* Use float: NEORV32 has no double-precision FPU */
	for (int k = 0; k < 64; k++) {
		float angle = 2.0f * 3.14159265f * target_bin * k / 64.0f;
		g_fft_in[k].re = (int16_t)(16384.0f * cosf(angle));
		g_fft_in[k].im = (int16_t)(-16384.0f * sinf(angle));
	}

	shell_print(sh, "[FFT] Input: sine wave at bin %d", target_bin);

	uint32_t t0 = k_cycle_get_32();
	int rc = fft_accel_transform(dev, g_fft_in, g_fft_out, 64);
	uint32_t t1 = k_cycle_get_32();

	if (rc != 0) {
		shell_error(sh, "[FFT] transform failed: %d", rc);
		return rc;
	}

#if CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC > 0
	uint32_t us = (uint64_t)(t1 - t0) * 1000000 /
		      CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC;
#else
	uint32_t us = 0;
#endif

	uint32_t peak_mag;
	int peak_bin = fft_peak(g_fft_out, 64, &peak_mag);

	/* Guard against target_bin=0: peak_bin >= -1 would always be true */
	int lo = (target_bin > 0) ? (target_bin - 1) : 0;
	bool pass = (peak_bin >= lo && peak_bin <= target_bin + 1);
	shell_print(sh,
		    "[FFT] Done in %u us.  Peak bin: %d  magnitude: %u  %s",
		    us, peak_bin, peak_mag, pass ? "PASS" : "FAIL");
	return pass ? 0 : -EIO;
}

/* ── "fft run [n_points]" ─────────────────────────────────────────────────── */

static int cmd_fft_run(const struct shell *sh, size_t argc, char **argv)
{
	int n = 64;
	if (argc >= 2) {
		n = atoi(argv[1]);
		if (n != 64) {
			shell_error(sh, "Only n=64 supported by this hardware");
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

#if CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC > 0
	uint32_t us = (uint64_t)(t1 - t0) * 1000000 /
		      CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC;
#else
	uint32_t us = 0;
#endif

	uint32_t peak_mag;
	int peak_bin = fft_peak(g_fft_out, n, &peak_mag);

	shell_print(sh,
		    "[FFT] Done in %u us.  Peak bin: %d  magnitude: %u",
		    us, peak_bin, peak_mag);
	return 0;
}

/* ── Shell command registration ──────────────────────────────────────────── */

SHELL_STATIC_SUBCMD_SET_CREATE(fft_sub,
	SHELL_CMD_ARG(run,  NULL,
		      "fft run [n_points]      — transform DC input",
		      cmd_fft_run,  1, 1),
	SHELL_CMD_ARG(sine, NULL,
		      "fft sine <bin>          — sine wave at given bin",
		      cmd_fft_sine, 2, 0),
	SHELL_CMD_ARG(dc,   NULL,
		      "fft dc                  — DC input, verify bin 0",
		      cmd_fft_dc,   1, 0),
	SHELL_SUBCMD_SET_END);

SHELL_CMD_REGISTER(fft, &fft_sub, "FFT hardware accelerator", NULL);
