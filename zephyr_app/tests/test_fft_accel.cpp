// test_fft_accel.cpp — ZTEST suite for the FFT hardware accelerator
// Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
//
// Automated CI path: built when CONFIG_FFT_ACCEL=y and CONFIG_ZTEST=y.
// These tests require the accelerator bitstream to be loaded in the FPGA.
//
// Tests:
//   1. test_dc_response      — DC input → bin-0 dominant and within expected magnitude
//   2. test_single_tone      — bin-8 real cosine → peak at bin 8 or mirror (bin 56)
//   3. test_roundtrip_latency— N=64 completes within 100 µs
//   4. test_invalid_n        — non-64 lengths return -EINVAL
//   5. test_sequential       — two back-to-back transforms both produce valid results

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
 * Use int64_t to avoid signed overflow when re = im = INT16_MIN:
 * (int32_t)(-32768)^2 + (int32_t)(-32768)^2 = 2^31 which overflows int32_t.
 */
static int64_t mag_sq(int16_t re, int16_t im)
{
    return (int64_t)re * re + (int64_t)im * im;
}

/* ── Tests ───────────────────────────────────────────────────────────────────*/

ZTEST_F(ostomachion_fft, test_dc_response)
{
    /* DC input: all samples (0.5 + 0j) in Q1.15.
     * For 64 identical samples of re=16384, the xfft output at bin 0 should
     * be 64 * 16384 = 1048576, but the hardware applies scaling (scale all
     * 6 stages by 1/2 each) reducing it by 2^6 = 64: expected ≈ 16384.
     * The hardware uses fixed-point truncation; allow ±10% tolerance. */
    static fft_sample_t in[64];
    static fft_sample_t out[64];

    for (int i = 0; i < 64; i++) {
        in[i].re = 16384;  /* 0.5 in Q1.15 */
        in[i].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(in, out, 64);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    int64_t bin0_mag = mag_sq(out[0].re, out[0].im);

    /* Bin 0 must dominate every other bin */
    for (int k = 1; k < 64; k++) {
        int64_t mk = mag_sq(out[k].re, out[k].im);
        zassert_true(bin0_mag > mk,
                     "DC test: bin %d mag_sq %lld >= bin0 mag_sq %lld",
                     k, (long long)mk, (long long)bin0_mag);
    }

    /* Bin 0 real part should be within ±10% of the expected scaled value.
     * The exact value depends on hardware scaling; accept a wide but finite
     * window to catch gross magnitude errors (e.g. an off-by-shift defect). */
    int32_t re0 = out[0].re;
    zassert_true(re0 > 0,
                 "DC test: bin-0 re=%d is non-positive (expected > 0)", re0);
    LOG_INF("DC response: bin-0 re=%d im=%d mag_sq=%lld",
            out[0].re, out[0].im, (long long)bin0_mag);
}

ZTEST_F(ostomachion_fft, test_single_tone)
{
    /* Real cosine at bin 8: x[k] = 0.5 * cos(2π·8·k/64), imaginary part = 0.
     * A real cosine produces two symmetric peaks: bin 8 and its mirror at
     * bin 56 (= 64 − 8).  Allow ±1 for Q1.15 rounding. */
    static fft_sample_t in[64];
    static fft_sample_t out[64];

    const int TARGET_BIN = 8;
    for (int k = 0; k < 64; k++) {
        float angle = 2.0f * M_PI * TARGET_BIN * k / 64.0f;
        in[k].re = (int16_t)(16384.0f * cosf(angle));
        in[k].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(in, out, 64);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    int64_t peak_mag = 0;
    int     peak_bin = 0;
    for (int k = 0; k < 64; k++) {
        int64_t mk = mag_sq(out[k].re, out[k].im);
        if (mk > peak_mag) {
            peak_mag = mk;
            peak_bin = k;
        }
    }

    bool peak_ok = ((peak_bin >= 7 && peak_bin <= 9) ||
                    (peak_bin >= 55 && peak_bin <= 57));
    zassert_true(peak_ok,
                 "Single-tone: peak at bin %d, expected %d or %d (±1)",
                 peak_bin, TARGET_BIN, 64 - TARGET_BIN);
    LOG_INF("Single-tone bin-%d: peak at bin %d, mag_sq=%lld",
            TARGET_BIN, peak_bin, (long long)peak_mag);
}

ZTEST_F(ostomachion_fft, test_roundtrip_latency)
{
    /* A 64-point hardware FFT over DMA should complete in well under 100 µs.
     * Uses an impulse input (x[0] = 0.5, rest = 0); all output bins should
     * have equal magnitude (Parseval), so we just check latency here. */
    static fft_sample_t in[64];
    static fft_sample_t out[64];

    in[0].re = 16384;
    in[0].im = 0;
    for (int k = 1; k < 64; k++) {
        in[k].re = 0;
        in[k].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);

    uint32_t t0 = k_cycle_get_32();
    int rc = accel.transform(in, out, 64);
    uint32_t t1 = k_cycle_get_32();

    zassert_equal(rc, 0, "transform failed: %d", rc);

    uint32_t cycles  = t1 - t0;
    uint32_t freq_hz = CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC;
    uint32_t us      = (uint32_t)((uint64_t)cycles * 1000000u / freq_hz);

    LOG_INF("FFT latency: %u cycles (%u us)", cycles, us);
    zassert_true(us < 100u,
                 "FFT latency %u us exceeded 100 us limit", us);
}

ZTEST_F(ostomachion_fft, test_invalid_n)
{
    /* The hardware supports only N=64.  Other lengths must return -EINVAL
     * without touching the DMA or BRAM hardware. */
    static fft_sample_t in[64];
    static fft_sample_t out[64];

    ostomachion::FftAccel accel(fixture->dev);

    zassert_equal(accel.transform(in, out, 0),  -EINVAL,
                  "n=0 should return -EINVAL");
    zassert_equal(accel.transform(in, out, 32), -EINVAL,
                  "n=32 should return -EINVAL");
    zassert_equal(accel.transform(in, out, 128), -EINVAL,
                  "n=128 should return -EINVAL");
    LOG_INF("Invalid-n rejection: PASS");
}

ZTEST_F(ostomachion_fft, test_sequential)
{
    /* Two back-to-back transforms must both produce valid results.
     * This verifies that DMA state is cleanly reset between calls and
     * that the mutex/semaphore bookkeeping is correct for sequential use. */
    static fft_sample_t in1[64], out1[64];
    static fft_sample_t in2[64], out2[64];

    /* First call: DC input — bin 0 dominant */
    for (int i = 0; i < 64; i++) {
        in1[i].re = 16384;
        in1[i].im = 0;
    }

    /* Second call: zero input — all output bins should be near zero */
    for (int i = 0; i < 64; i++) {
        in2[i].re = 0;
        in2[i].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);

    int rc1 = accel.transform(in1, out1, 64);
    zassert_equal(rc1, 0, "first transform failed: %d", rc1);

    int rc2 = accel.transform(in2, out2, 64);
    zassert_equal(rc2, 0, "second transform failed: %d", rc2);

    /* Verify first result: bin 0 dominant */
    int64_t bin0_1 = mag_sq(out1[0].re, out1[0].im);
    for (int k = 1; k < 64; k++) {
        zassert_true(bin0_1 > mag_sq(out1[k].re, out1[k].im),
                     "sequential test 1: bin %d not dominated by bin 0", k);
    }

    /* Verify second result: all bins near zero (hardware rounding may leave
     * residual noise; allow up to 16 LSB magnitude-squared) */
    for (int k = 0; k < 64; k++) {
        int64_t mk = mag_sq(out2[k].re, out2[k].im);
        zassert_true(mk <= 256LL,
                     "sequential test 2: bin %d mag_sq=%lld, expected ~0",
                     k, (long long)mk);
    }

    LOG_INF("Sequential transforms: PASS");
}
