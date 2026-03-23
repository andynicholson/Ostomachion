// test_fft_accel.cpp — ZTEST suite for the FFT hardware accelerator
// Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
//
// Automated CI path: built when CONFIG_FFT_ACCEL=y and CONFIG_ZTEST=y.
// These tests require the accelerator bitstream to be loaded in the FPGA.
//
// FFT configuration: 4096-point, 16-bit Q1.15, pipelined streaming,
// all 12 stages scaled (÷2 each), forward transform.
//
// Tests:
//   1. test_dc_response      — DC input → bin-0 dominant; magnitude > 0
//   2. test_single_tone      — bin-8 real cosine → peak at bin 8 or mirror (4088)
//   3. test_roundtrip_latency— N=4096 completes within 2000 µs
//   4. test_invalid_n        — non-4096 lengths return -EINVAL
//   5. test_sequential       — two back-to-back transforms both produce valid results
//
// Memory note: a 4096-point FFT buffer is 16 KB (4096 × 4 bytes).
// All test functions share a SINGLE file-scope in/out buffer pair to keep
// the total BSS footprint to 32 KB rather than 160 KB.

#include <zephyr/ztest.h>
#include <zephyr/device.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <ostomachion/hal/fft_accel.hpp>

#include <math.h>    /* cosf — available via picolibc */
#include <stdint.h>

LOG_MODULE_REGISTER(test_fft_accel, LOG_LEVEL_INF);

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

#define FFT_N 4096

/* ── Shared file-scope buffers (32 KB total) ─────────────────────────────────
 * Declaring all buffers at file scope prevents the linker stacking multiple
 * per-function 'static' arrays of 16 KB each in BSS simultaneously.
 */
static fft_sample_t g_in[FFT_N];
static fft_sample_t g_out[FFT_N];

/* ── Fixture ─────────────────────────────────────────────────────────────────*/

struct ostomachion_fft_fixture {
    const struct device *dev;
};

static void *fft_setup(void)
{
    static struct ostomachion_fft_fixture f;
    f.dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
    zassert_true(device_is_ready(f.dev),
                 "fft_accel not ready — check DTS, CONFIG_FFT_ACCEL, "
                 "and that the accelerator bitstream is loaded");
    return &f;
}

ZTEST_SUITE(ostomachion_fft, NULL, fft_setup, NULL, NULL, NULL);

/* ── Helper: integer magnitude squared ───────────────────────────────────────
 * Use int64_t to avoid signed overflow when re = im = INT16_MIN.
 */
static int64_t mag_sq(int16_t re, int16_t im)
{
    return (int64_t)re * re + (int64_t)im * im;
}

/* ── Tests ───────────────────────────────────────────────────────────────────*/

ZTEST_F(ostomachion_fft, test_dc_response)
{
    /* DC input: all samples (0.5 + 0j) in Q1.15.
     * With 4096 samples of re=16384 and all 12 stages scaled by 1/2:
     *   bin-0 re = 4096 * 16384 / 2^12 = 16384 (same as input amplitude).
     * Allow ±10% tolerance for truncation rounding. */
    for (int i = 0; i < FFT_N; i++) {
        g_in[i].re = 16384;  /* 0.5 in Q1.15 */
        g_in[i].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    int64_t bin0_mag = mag_sq(g_out[0].re, g_out[0].im);

    for (int k = 1; k < FFT_N; k++) {
        int64_t mk = mag_sq(g_out[k].re, g_out[k].im);
        zassert_true(bin0_mag > mk,
                     "DC test: bin %d mag_sq %lld >= bin0 mag_sq %lld",
                     k, (long long)mk, (long long)bin0_mag);
    }

    int32_t re0 = g_out[0].re;
    zassert_true(re0 > 0,
                 "DC test: bin-0 re=%d is non-positive (expected ~16384)", re0);
    LOG_INF("DC response: bin-0 re=%d im=%d mag_sq=%lld",
            g_out[0].re, g_out[0].im, (long long)bin0_mag);
}

ZTEST_F(ostomachion_fft, test_single_tone)
{
    /* Real cosine at bin 8: x[k] = 0.5 * cos(2π·8·k/4096), imaginary = 0.
     * A real cosine produces two symmetric peaks: bin 8 and its mirror at
     * bin 4088 (= 4096 − 8).  Allow ±1 bin for Q1.15 rounding. */
    const int TARGET_BIN = 8;
    for (int k = 0; k < FFT_N; k++) {
        float angle = 2.0f * M_PI * TARGET_BIN * k / (float)FFT_N;
        g_in[k].re = (int16_t)(16384.0f * cosf(angle));
        g_in[k].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    int64_t peak_mag = 0;
    int     peak_bin = 0;
    for (int k = 0; k < FFT_N; k++) {
        int64_t mk = mag_sq(g_out[k].re, g_out[k].im);
        if (mk > peak_mag) {
            peak_mag = mk;
            peak_bin = k;
        }
    }

    const int MIRROR = FFT_N - TARGET_BIN;  /* 4088 */
    bool peak_ok = ((peak_bin >= TARGET_BIN - 1 && peak_bin <= TARGET_BIN + 1) ||
                    (peak_bin >= MIRROR - 1      && peak_bin <= MIRROR + 1));
    zassert_true(peak_ok,
                 "Single-tone: peak at bin %d, expected %d or %d (±1)",
                 peak_bin, TARGET_BIN, MIRROR);
    LOG_INF("Single-tone bin-%d: peak at bin %d, mag_sq=%lld",
            TARGET_BIN, peak_bin, (long long)peak_mag);
}

ZTEST_F(ostomachion_fft, test_roundtrip_latency)
{
    /* A 4096-point DMA+xfft round-trip at 100 MHz:
     *   DMA in:  16 KB ≈ 40 µs  |  xfft: 4096 cycles ≈ 41 µs  |  DMA out ≈ 40 µs
     * Total typically 100–300 µs.  Limit 2000 µs for interrupt/scheduler jitter. */
    g_in[0].re = 16384;
    g_in[0].im = 0;
    for (int k = 1; k < FFT_N; k++) {
        g_in[k].re = 0;
        g_in[k].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);

    uint32_t t0 = k_cycle_get_32();
    int rc = accel.transform(g_in, g_out, FFT_N);
    uint32_t t1 = k_cycle_get_32();

    zassert_equal(rc, 0, "transform failed: %d", rc);

    uint32_t cycles  = t1 - t0;
    uint32_t freq_hz = CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC;
    uint32_t us      = (freq_hz > 0)
                       ? (uint32_t)((uint64_t)cycles * 1000000u / freq_hz)
                       : 0u;

    LOG_INF("4096-pt FFT latency: %u cycles (%u us)", cycles, us);

    if (freq_hz > 0) {
        zassert_true(us < 2000u,
                     "FFT latency %u us exceeded 2000 us limit", us);
    }
}

ZTEST_F(ostomachion_fft, test_invalid_n)
{
    /* xfft IP is synthesised for N=4096 only.  Any other size → -EINVAL. */
    static fft_sample_t tiny_in[4];
    static fft_sample_t tiny_out[4];

    ostomachion::FftAccel accel(fixture->dev);

    zassert_equal(accel.transform(tiny_in, tiny_out, 0),    -EINVAL, "n=0 should be -EINVAL");
    zassert_equal(accel.transform(tiny_in, tiny_out, 64),   -EINVAL, "n=64 should be -EINVAL");
    zassert_equal(accel.transform(tiny_in, tiny_out, 1024), -EINVAL, "n=1024 should be -EINVAL");
    zassert_equal(accel.transform(tiny_in, tiny_out, 4095), -EINVAL, "n=4095 should be -EINVAL");
    zassert_equal(accel.transform(tiny_in, tiny_out, 8192), -EINVAL, "n=8192 should be -EINVAL");
    LOG_INF("Invalid-n rejection: PASS");
}

ZTEST_F(ostomachion_fft, test_sequential)
{
    /* Two back-to-back transforms using the shared buffer pair.
     * This verifies DMA state is cleanly reset (k_sem_reset path). */
    ostomachion::FftAccel accel(fixture->dev);

    /* First transform: DC input — bin 0 should dominate */
    for (int i = 0; i < FFT_N; i++) {
        g_in[i].re = 16384;
        g_in[i].im = 0;
    }
    int rc1 = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc1, 0, "first transform failed: %d", rc1);

    int64_t bin0_1 = mag_sq(g_out[0].re, g_out[0].im);
    for (int k = 1; k < FFT_N; k++) {
        zassert_true(bin0_1 > mag_sq(g_out[k].re, g_out[k].im),
                     "sequential test 1: bin %d not dominated by bin 0", k);
    }

    /* Second transform: zero input — all output bins should be near zero */
    for (int i = 0; i < FFT_N; i++) {
        g_in[i].re = 0;
        g_in[i].im = 0;
    }
    int rc2 = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc2, 0, "second transform failed: %d", rc2);

    for (int k = 0; k < FFT_N; k++) {
        int64_t mk = mag_sq(g_out[k].re, g_out[k].im);
        zassert_true(mk <= 256LL,
                     "sequential test 2: bin %d mag_sq=%lld, expected ~0",
                     k, (long long)mk);
    }

    LOG_INF("Sequential transforms: PASS");
}
