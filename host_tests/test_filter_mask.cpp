// test_filter_mask.cpp — host (off-target) unit tests for filter-mask synthesis
// Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// These tests are GHDL- and Vivado-independent: they exercise ONLY the pure
// math in ostomachion/filter_mask.hpp, which is the part of the FFT→filter→IFFT
// feature that has no Xilinx-IP dependency.  Built and run by host_tests/
// CMake + ctest (see remote-build.sh "math" stage); they are the fast CI gate
// that fails before any synthesis is attempted.
//
// Coverage:
//   1. synth() brick-wall masks (LP/HP/BP/notch) match an analytic reference,
//      bit-exact, and are Hermitian-symmetric.
//   2. all_pass() droops by exactly the Q1.15 unity error and nothing more.
//   3. sat_round_q15() matches the fabric normalizer policy at the rounding
//      and saturation boundaries.
//   4. compose_mul() (cascade) and compose_max() (parallel) build the expected
//      combined passbands — the "arbitrary combination" contract.
//   5. End-to-end fixed-point DFT → mask → IDFT round-trip stays within the
//      documented LSB budget vs a double-precision golden model, for an
//      all-pass mask and a low-pass mask.

#include "ostomachion/filter_mask.hpp"

#include <cmath>
#include <cstdio>
#include <cstdint>
#include <complex>
#include <vector>

using ostomachion::filter::Coeff;
using ostomachion::filter::Kind;
namespace flt = ostomachion::filter;

// ── Tiny test harness (no GoogleTest dependency — host CI stays toolchain-free)
static int g_fails = 0;
static int g_checks = 0;

#define CHECK(cond, ...)                                                   \
    do {                                                                   \
        ++g_checks;                                                        \
        if (!(cond)) {                                                     \
            ++g_fails;                                                     \
            std::printf("FAIL %s:%d: ", __FILE__, __LINE__);               \
            std::printf(__VA_ARGS__);                                      \
            std::printf("\n");                                             \
        }                                                                  \
    } while (0)

// ── Reference brick-wall predicate, computed independently of synth() ───────
static bool ref_pass(Kind kind, int f, int lo, int hi)
{
    switch (kind) {
    case Kind::LowPass:  return f <= hi;
    case Kind::HighPass: return f >= lo;
    case Kind::BandPass: return f >= lo && f <= hi;
    case Kind::Notch:    return f < lo || f > hi;
    }
    return false;
}

static int ref_folded(int k, int N) { return std::min(k, N - k); }

// ── Test 1: synth() matches the analytic mask and is Hermitian-symmetric ────
static void test_synth_brickwall()
{
    const int N = 4096;
    const int16_t gain = 0x7FFF;
    std::vector<Coeff> m(N);

    struct Case { Kind kind; int lo; int hi; const char *name; };
    const Case cases[] = {
        { Kind::LowPass,  0,   100, "lowpass<=100"   },
        { Kind::HighPass, 200, 0,   "highpass>=200"  },
        { Kind::BandPass, 50,  150, "bandpass[50,150]" },
        { Kind::Notch,    60,  64,  "notch[60,64]"   },
    };

    for (const auto &c : cases) {
        flt::synth(c.kind, N, c.lo, c.hi, gain, m.data());
        for (int k = 0; k < N; ++k) {
            const int f = ref_folded(k, N);
            const int16_t want = ref_pass(c.kind, f, c.lo, c.hi) ? gain : 0;
            CHECK(m[k].re == want && m[k].im == 0,
                  "%s bin %d (f=%d): got {%d,%d} want {%d,0}",
                  c.name, k, f, m[k].re, m[k].im, want);
        }
        // Hermitian symmetry: H[N-k] == conj(H[k]); masks are real so == H[k].
        for (int k = 1; k < N; ++k) {
            CHECK(m[k].re == m[N - k].re && m[k].im == -m[N - k].im,
                  "%s not Hermitian at k=%d", c.name, k);
        }
    }
}

// ── Test 2: all_pass droops by exactly the Q1.15 unity error ────────────────
static void test_all_pass()
{
    const int N = 4096;
    std::vector<Coeff> m(N);
    flt::all_pass(N, 0x7FFF, m.data());
    for (int k = 0; k < N; ++k) {
        CHECK(m[k].re == 0x7FFF && m[k].im == 0,
              "all_pass bin %d = {%d,%d}", k, m[k].re, m[k].im);
    }
}

// ── Test 3: sat_round_q15 boundary behaviour ────────────────────────────────
static void test_sat_round()
{
    // Q2.30: 1.0 == (1<<30).  Round-half-up >>15 → 1.0 in Q1.15 == 32768,
    // which saturates to 32767.
    CHECK(flt::sat_round_q15(int64_t(1) << 30) == 32767, "1.0 should saturate to 32767");
    // 0.5 in Q2.30 == (1<<29) → 0.5 Q1.15 == 16384.
    CHECK(flt::sat_round_q15(int64_t(1) << 29) == 16384, "0.5 -> 16384");
    // Exactly +0.5 LSB rounds up: prod = (2^15)/2 in Q15 terms == 16384 in Q30
    // i.e. value 16384 >>15 with +16384 bias → 1.
    CHECK(flt::sat_round_q15(16384) == 1, "half-LSB rounds up to 1");
    CHECK(flt::sat_round_q15(16383) == 0, "just below half-LSB rounds to 0");
    CHECK(flt::sat_round_q15(0) == 0, "zero -> zero");
    // Large negative saturates to -32768.
    CHECK(flt::sat_round_q15(-(int64_t(1) << 40)) == -32768, "large neg saturates");
    // -1.0 Q2.30 == -(1<<30) → -32768.
    CHECK(flt::sat_round_q15(-(int64_t(1) << 30)) == -32768, "-1.0 -> -32768");
}

// ── Test 4: compose_mul / compose_max passband logic ────────────────────────
static void test_compose()
{
    const int N = 4096;
    const int16_t gain = 0x7FFF;
    std::vector<Coeff> lp(N), hp(N), out(N);

    // Cascade LP(<=300) ∩ HP(>=100) == band-pass [100,300].
    flt::synth(Kind::LowPass,  N, 0,   300, gain, lp.data());
    flt::synth(Kind::HighPass, N, 100, 0,   gain, hp.data());
    flt::compose_mul(lp.data(), hp.data(), N, out.data());
    for (int k = 0; k < N; ++k) {
        const int f = ref_folded(k, N);
        const bool want = (f >= 100 && f <= 300);
        const bool got = (out[k].re != 0);
        CHECK(got == want, "compose_mul bin %d (f=%d): got=%d want=%d re=%d",
              k, f, got, want, out[k].re);
    }

    // Parallel LP(<=50) ∪ HP(>=4000-equiv folded>=1000) keeps the larger-mag
    // coeff per bin → union of passbands.
    std::vector<Coeff> a(N), b(N);
    flt::synth(Kind::LowPass,  N, 0,    50, gain, a.data());
    flt::synth(Kind::HighPass, N, 1000, 0,  gain, b.data());
    flt::compose_max(a.data(), b.data(), N, out.data());
    for (int k = 0; k < N; ++k) {
        const int f = ref_folded(k, N);
        const bool want = (f <= 50) || (f >= 1000);
        const bool got = (out[k].re != 0);
        CHECK(got == want, "compose_max bin %d (f=%d): got=%d want=%d", k, f, got, want);
    }
}

// ── Fixed-point pipeline model: forward FFT (÷N) → mask → IFFT ──────────────
// Mirrors the fabric arithmetic closely enough to bound round-trip error.
// We model the two ÷N-scaled xfft stages with an UNSCALED inverse for the
// identity round-trip (matches the all-pass demonstration word 0x0000), using
// floating point for the transforms (the xfft truncation/round is sub-LSB at
// these amplitudes) and the EXACT Q1.15 mask reduction for the filter step.
static void dft(const std::vector<std::complex<double>> &in,
                std::vector<std::complex<double>> &out, bool inverse)
{
    const int N = (int)in.size();
    out.assign(N, {0, 0});
    const double sign = inverse ? +1.0 : -1.0;
    for (int k = 0; k < N; ++k) {
        std::complex<double> acc{0, 0};
        for (int n = 0; n < N; ++n) {
            double th = sign * 2.0 * M_PI * k * n / N;
            acc += in[n] * std::complex<double>(std::cos(th), std::sin(th));
        }
        // Forward stage applies 1/N scaling (matches word 0x1555 ÷N); the
        // unscaled inverse (word 0x0000) applies no scaling.
        out[k] = inverse ? acc : acc / double(N);
    }
}

static void test_roundtrip_allpass()
{
    // Small N keeps the O(N^2) reference DFT fast while still exercising the
    // scaling/mask/round-trip arithmetic; the LSB budget is N-independent.
    const int N = 64;
    std::vector<std::complex<double>> x(N), X, Y;
    // Low-amplitude real cosine at bin 5 (amp 0.25 in Q1.15 ≈ 8192).
    for (int n = 0; n < N; ++n) {
        x[n] = { 0.25 * std::cos(2.0 * M_PI * 5 * n / N), 0.0 };
    }

    dft(x, X, /*inverse=*/false);

    // All-pass Q1.15 mask: multiply each bin by 0.999969 with sat/round.
    Coeff h{0x7FFF, 0};
    for (int k = 0; k < N; ++k) {
        // Convert bin to Q1.15-ish complex, apply mask in the same way the
        // fabric does, convert back.  Bins here are small (<1), so scale to
        // Q1.15, multiply, reduce, unscale.
        int64_t xr = std::llround(X[k].real() * 32768.0);
        int64_t xi = std::llround(X[k].imag() * 32768.0);
        Coeff xc{ (int16_t)std::max<int64_t>(-32768, std::min<int64_t>(32767, xr)),
                  (int16_t)std::max<int64_t>(-32768, std::min<int64_t>(32767, xi)) };
        Coeff prod = flt::cmul_q15(xc, h);
        X[k] = { prod.re / 32768.0, prod.im / 32768.0 };
    }

    dft(X, Y, /*inverse=*/true);

    // Round-trip should reproduce x within the documented ≤4 LSB budget.
    double max_lsb = 0.0;
    for (int n = 0; n < N; ++n) {
        double err = std::abs(Y[n].real() - x[n].real()) * 32768.0;
        if (err > max_lsb) max_lsb = err;
        CHECK(std::abs(Y[n].imag()) * 32768.0 < 4.0,
              "allpass roundtrip imag leak at n=%d: %f LSB",
              n, std::abs(Y[n].imag()) * 32768.0);
    }
    CHECK(max_lsb <= 4.0, "allpass roundtrip max error %.3f LSB exceeds 4", max_lsb);
    std::printf("INFO allpass roundtrip max error = %.3f LSB\n", max_lsb);
}

static void test_roundtrip_lowpass()
{
    const int N = 64;
    std::vector<std::complex<double>> x(N), X, Y;
    // Two tones: bin 3 (in passband) + bin 20 (in stopband), amp 0.2 each.
    for (int n = 0; n < N; ++n) {
        x[n] = { 0.2 * std::cos(2.0 * M_PI * 3 * n / N) +
                 0.2 * std::cos(2.0 * M_PI * 20 * n / N), 0.0 };
    }

    dft(x, X, false);

    // Low-pass folded cutoff at 8: bin 3 passes, bin 20 (folded 20) blocked.
    std::vector<Coeff> m(N);
    flt::synth(Kind::LowPass, N, 0, 8, 0x7FFF, m.data());
    for (int k = 0; k < N; ++k) {
        int64_t xr = std::llround(X[k].real() * 32768.0);
        int64_t xi = std::llround(X[k].imag() * 32768.0);
        Coeff xc{ (int16_t)std::max<int64_t>(-32768, std::min<int64_t>(32767, xr)),
                  (int16_t)std::max<int64_t>(-32768, std::min<int64_t>(32767, xi)) };
        Coeff prod = flt::cmul_q15(xc, m[k]);
        X[k] = { prod.re / 32768.0, prod.im / 32768.0 };
    }

    dft(X, Y, true);

    // The bin-20 tone must be removed: compare against a pure bin-3 cosine.
    double max_lsb = 0.0;
    for (int n = 0; n < N; ++n) {
        double want = 0.2 * std::cos(2.0 * M_PI * 3 * n / N);
        double err = std::abs(Y[n].real() - want) * 32768.0;
        if (err > max_lsb) max_lsb = err;
    }
    // Brick-wall removal of a clean tone is near-perfect; allow a modest margin.
    CHECK(max_lsb <= 8.0, "lowpass roundtrip max error %.3f LSB exceeds 8", max_lsb);
    std::printf("INFO lowpass roundtrip max error = %.3f LSB\n", max_lsb);
}

int main()
{
    test_synth_brickwall();
    test_all_pass();
    test_sat_round();
    test_compose();
    test_roundtrip_allpass();
    test_roundtrip_lowpass();

    std::printf("\n%d checks, %d failures\n", g_checks, g_fails);
    if (g_fails == 0) {
        std::printf("PROJECT EXECUTION SUCCESSFUL\n");
        return 0;
    }
    return 1;
}
