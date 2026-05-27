// test_fft_accel.cpp — ZTEST suite for the FFT hardware accelerator
// Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
//
// Automated CI path: built when CONFIG_FFT_ACCEL=y and CONFIG_ZTEST=y.
// These tests require the accelerator bitstream to be loaded in the FPGA.
//
// FFT configuration: 4096-point, 16-bit Q1.15, pipelined streaming,
// all 6 radix-4 stages scaled (÷4 each, total ÷4096), forward transform.
//
// Tests:
//   1. test_dc_response       — DC input → bin-0 dominant; magnitude > 0
//   2. test_dc_exact          — DC input → out[0].re ≈ 16384 within ±5%
//   3. test_single_tone       — bin-8 cosine → peak EXACTLY at 8 or 4088
//   4. test_no_off_by_one     — bin-1 cosine → peak EXACTLY at 1 or 4095
//   5. test_y_n_minus_1       — verifies bin 4095 actually lands in g_out[4095]
//   6. test_roundtrip_latency — N=4096 completes within 2000 µs
//   7. test_invalid_n         — non-4096 lengths return -EINVAL
//   8. test_sequential        — two back-to-back transforms both produce valid results
//
// The exact-bin tests (3, 4, 5) are written to FAIL on any one-bin misalignment
// of the DMA→BRAM mapping.  They are the regression guard for the BRAM
// read-latency contract (ACCEL_ARCH.md §4.1).
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
#include <stdlib.h>  /* abs */

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

/* ── Helpers ─────────────────────────────────────────────────────────────────
 * mag_sq uses int64_t to avoid signed overflow when re = im = INT16_MIN.
 */
static int64_t mag_sq(int16_t re, int16_t im)
{
    return (int64_t)re * re + (int64_t)im * im;
}

/* Find the bin with the largest magnitude.  Returns the bin index and writes
 * the magnitude squared to *peak_mag_sq if non-null. */
static int peak_bin(const fft_sample_t *out, int n, int64_t *peak_mag_sq)
{
    int64_t m_max = 0;
    int     bin   = 0;
    for (int k = 0; k < n; k++) {
        int64_t m = mag_sq(out[k].re, out[k].im);
        if (m > m_max) {
            m_max = m;
            bin   = k;
        }
    }
    if (peak_mag_sq) {
        *peak_mag_sq = m_max;
    }
    return bin;
}

/* Fill g_in[] with a real cosine at the given bin (Q1.15 amplitude 0.5). */
static void fill_cosine(int target_bin)
{
    for (int k = 0; k < FFT_N; k++) {
        float angle = 2.0f * M_PI * target_bin * k / (float)FFT_N;
        g_in[k].re = (int16_t)(16384.0f * cosf(angle));
        g_in[k].im = 0;
    }
}

/* ── Tests ───────────────────────────────────────────────────────────────────*/

ZTEST_F(ostomachion_fft, test_dc_response)
{
    /* DC input: all samples (0.5 + 0j) in Q1.15.
     * With 4096 samples of re=16384 and 6 radix-4 stages each ÷4:
     *   bin-0 re = 4096 * 16384 / 4^6 = 16384.
     * Tolerance is generous because this test only checks that bin-0
     * dominates; test_dc_exact below checks the value tightly. */
    for (int i = 0; i < FFT_N; i++) {
        g_in[i].re = 16384;
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

ZTEST_F(ostomachion_fft, test_dc_exact)
{
    /* Strict DC magnitude check: catches a partial off-by-one (bin energy split
     * between bins 0 and 1) and any scaling drift.  Tolerance ±5% on re; im
     * must be near zero (±200 LSB). */
    for (int i = 0; i < FFT_N; i++) {
        g_in[i].re = 16384;
        g_in[i].im = 0;
    }

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    const int32_t expected = 16384;
    const int32_t tol      = 16384 / 20;   /* 5% of 16384 ≈ 819 */
    int32_t re0 = g_out[0].re;
    int32_t im0 = g_out[0].im;

    zassert_true(re0 > expected - tol && re0 < expected + tol,
                 "DC exact: bin-0 re=%d outside [%d, %d]",
                 re0, expected - tol, expected + tol);
    zassert_true(im0 > -200 && im0 < 200,
                 "DC exact: bin-0 im=%d not near zero", im0);
    LOG_INF("DC exact: bin-0 re=%d (expected ~%d ±%d), im=%d",
            re0, expected, tol, im0);
}

ZTEST_F(ostomachion_fft, test_single_tone)
{
    /* Real cosine at bin 8.  A pure cosine produces two symmetric peaks at
     * bin 8 and bin 4088 (= 4096 − 8).  No tolerance on the peak location:
     * an off-by-one in the DMA→BRAM mapping would put the peak at bin 9 or
     * bin 4089 and this test must catch that. */
    const int TARGET_BIN = 8;
    fill_cosine(TARGET_BIN);

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    int64_t pmag = 0;
    int     pbin = peak_bin(g_out, FFT_N, &pmag);

    const int MIRROR = FFT_N - TARGET_BIN;  /* 4088 */
    bool peak_ok = (pbin == TARGET_BIN) || (pbin == MIRROR);
    zassert_true(peak_ok,
                 "Single-tone: peak at bin %d, expected exactly %d or %d "
                 "(any off-by-one indicates a DMA mapping bug)",
                 pbin, TARGET_BIN, MIRROR);
    LOG_INF("Single-tone bin-%d: peak at bin %d, mag_sq=%lld",
            TARGET_BIN, pbin, (long long)pmag);
}

ZTEST_F(ostomachion_fft, test_no_off_by_one)
{
    /* The most stringent off-by-one regression guard: bin 1 has the lowest
     * possible non-DC frequency.  An off-by-one would push the peak into bin 0
     * (DC region) or bin 2, both of which are far from bin 1's expected
     * energy.  Mirror is at 4095. */
    const int TARGET_BIN = 1;
    fill_cosine(TARGET_BIN);

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    int     pbin = peak_bin(g_out, FFT_N, NULL);
    const int MIRROR = FFT_N - TARGET_BIN;  /* 4095 */

    bool peak_ok = (pbin == TARGET_BIN) || (pbin == MIRROR);
    zassert_true(peak_ok,
                 "Off-by-one guard: bin-%d cosine peaked at bin %d "
                 "(must be exactly %d or %d)",
                 TARGET_BIN, pbin, TARGET_BIN, MIRROR);
    LOG_INF("Off-by-one guard: bin-%d cosine peaked at bin %d (PASS)",
            TARGET_BIN, pbin);
}

ZTEST_F(ostomachion_fft, test_y_n_minus_1)
{
    /* Y[N-1] (= Y[4095]) is the final output sample of the frame.  Under-
     * length S2MM transfers drop it; this test guards the symmetric
     * `byte_len = N*4` rule (ACCEL_ARCH.md §4.4) by asserting that a real
     * cosine at bin 1 lights up the mirror peak at bin 4095 non-zero. */
    fill_cosine(1);

    ostomachion::FftAccel accel(fixture->dev);
    int rc = accel.transform(g_in, g_out, FFT_N);
    zassert_equal(rc, 0, "transform failed: %d", rc);

    int64_t bin_n_minus_1 = mag_sq(g_out[FFT_N - 1].re, g_out[FFT_N - 1].im);
    zassert_true(bin_n_minus_1 > 0,
                 "Y[N-1] (bin %d) mag_sq=%lld — bin not captured by DMA "
                 "(check byte_len handling and N+1 transfer)",
                 FFT_N - 1, (long long)bin_n_minus_1);
    LOG_INF("Y[N-1] capture: g_out[%d] re=%d im=%d mag_sq=%lld",
            FFT_N - 1, g_out[FFT_N - 1].re, g_out[FFT_N - 1].im,
            (long long)bin_n_minus_1);
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
