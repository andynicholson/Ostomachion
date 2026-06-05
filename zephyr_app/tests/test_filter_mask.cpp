// test_filter_mask.cpp — on-target ZTEST for the filter-mask synthesis math
// Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// Runs on the NEORV32 GHDL sim model (and on hardware) — it touches NO Xilinx
// IP, so it is the on-target companion to the host-side host_tests/
// test_filter_mask.cpp.  It proves the pure mask synthesis in
// ostomachion/filter_mask.hpp links and behaves correctly when compiled with
// the Zephyr/picolibc C++ toolchain (catching any toolchain-specific math or
// constexpr issue the host compiler would not).
//
// This suite is gated on CONFIG_ZTEST only (NOT CONFIG_FFT_ACCEL): the math is
// hardware-independent, so it runs in the default sim CI build alongside the
// SPI/I2C/GPIO suites.

#include <zephyr/ztest.h>

#include "ostomachion/filter_mask.hpp"

using ostomachion::filter::Coeff;
using ostomachion::filter::Kind;
namespace flt = ostomachion::filter;

// Use a modest N on-target to keep BSS small; the synthesis logic is
// N-independent (the host test covers N=4096).
#define MASK_N 256

static Coeff g_mask[MASK_N];
static Coeff g_mask_b[MASK_N];

static int ref_folded(int k, int N) { return (k <= N - k) ? k : N - k; }

ZTEST_SUITE(ostomachion_filter_mask, NULL, NULL, NULL, NULL, NULL);

ZTEST(ostomachion_filter_mask, test_lowpass)
{
    flt::synth(Kind::LowPass, MASK_N, 0, 32, 0x7FFF, g_mask);
    for (int k = 0; k < MASK_N; ++k) {
        int f = ref_folded(k, MASK_N);
        int16_t want = (f <= 32) ? 0x7FFF : 0;
        zassert_equal(g_mask[k].re, want, "LP bin %d (f=%d) re=%d", k, f, g_mask[k].re);
        zassert_equal(g_mask[k].im, 0, "LP bin %d im nonzero", k);
    }
}

ZTEST(ostomachion_filter_mask, test_highpass)
{
    flt::synth(Kind::HighPass, MASK_N, 64, 0, 0x7FFF, g_mask);
    for (int k = 0; k < MASK_N; ++k) {
        int f = ref_folded(k, MASK_N);
        int16_t want = (f >= 64) ? 0x7FFF : 0;
        zassert_equal(g_mask[k].re, want, "HP bin %d (f=%d)", k, f);
    }
}

ZTEST(ostomachion_filter_mask, test_notch)
{
    flt::synth(Kind::Notch, MASK_N, 30, 34, 0x7FFF, g_mask);
    for (int k = 0; k < MASK_N; ++k) {
        int f = ref_folded(k, MASK_N);
        bool pass = (f < 30 || f > 34);
        zassert_equal(g_mask[k].re, pass ? 0x7FFF : 0, "notch bin %d (f=%d)", k, f);
    }
}

ZTEST(ostomachion_filter_mask, test_hermitian)
{
    // Brick-wall masks must be Hermitian-symmetric so real input → real output.
    flt::synth(Kind::BandPass, MASK_N, 10, 50, 0x7FFF, g_mask);
    for (int k = 1; k < MASK_N; ++k) {
        zassert_equal(g_mask[k].re, g_mask[MASK_N - k].re, "not symmetric re k=%d", k);
        zassert_equal(g_mask[k].im, -g_mask[MASK_N - k].im, "not conj im k=%d", k);
    }
}

ZTEST(ostomachion_filter_mask, test_sat_round)
{
    zassert_equal(flt::sat_round_q15(int64_t(1) << 30), 32767, "1.0 saturates");
    zassert_equal(flt::sat_round_q15(int64_t(1) << 29), 16384, "0.5");
    zassert_equal(flt::sat_round_q15(16384), 1, "half-LSB rounds up");
    zassert_equal(flt::sat_round_q15(-(int64_t(1) << 30)), -32768, "-1.0 saturates");
}

ZTEST(ostomachion_filter_mask, test_compose_mul)
{
    // LP(<=100) ∩ HP(>=20) == band-pass [20,100].
    flt::synth(Kind::LowPass,  MASK_N, 0,  100, 0x7FFF, g_mask);
    flt::synth(Kind::HighPass, MASK_N, 20, 0,   0x7FFF, g_mask_b);
    flt::compose_mul(g_mask, g_mask_b, MASK_N, g_mask);
    for (int k = 0; k < MASK_N; ++k) {
        int f = ref_folded(k, MASK_N);
        bool want = (f >= 20 && f <= 100);
        zassert_equal(g_mask[k].re != 0, want, "compose_mul bin %d (f=%d)", k, f);
    }
}

ZTEST(ostomachion_filter_mask, test_compose_max)
{
    // LP(<=10) ∪ HP(>=100) == union of passbands.
    flt::synth(Kind::LowPass,  MASK_N, 0,   10, 0x7FFF, g_mask);
    flt::synth(Kind::HighPass, MASK_N, 100, 0,  0x7FFF, g_mask_b);
    flt::compose_max(g_mask, g_mask_b, MASK_N, g_mask);
    for (int k = 0; k < MASK_N; ++k) {
        int f = ref_folded(k, MASK_N);
        bool want = (f <= 10) || (f >= 100);
        zassert_equal(g_mask[k].re != 0, want, "compose_max bin %d (f=%d)", k, f);
    }
}
