// filter_mask.hpp — pure per-bin spectral filter-mask synthesis (Q1.15 complex)
// Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// This header is intentionally FREE OF any Zephyr / MMIO / hardware dependency
// so the mask-synthesis math can be unit-tested on the host (see host_tests/)
// independently of GHDL or Vivado.  The same functions are used on-target by
// the FftAccel HAL to build the 4096-entry coefficient table that the fabric
// complex-multiplier (cmpy) applies to each FFT bin before the IFFT.
//
// Coefficient format: per-bin COMPLEX Q1.15  H[k] = { re, im }, matching the
// hardware coeff BRAM word { im[31:16], re[15:0] } and fft_sample_t.  A value
// v represents v / 2^15; full scale 0x7FFF ≈ +0.999969 (Q1.15 cannot encode
// exactly 1.0 — an "all-pass" mask therefore droops magnitude by ~2^-15).
//
// Hermitian symmetry: for a real time-domain input to yield a real output,
// the mask must satisfy H[N-k] = conj(H[k]).  Brick-wall gain masks built here
// are purely real and symmetric in the folded frequency index, so H[N-k]=H[k]
// holds automatically.
//
// Q2.30 -> Q1.15 reduction (sat_round_q15) mirrors the fabric normalizer
// (cmpy_normalizer.vhd) bit-for-bit: round-half-up (+2^14) then arithmetic
// >>15, then saturate to int16.  Keeping the firmware and RTL reductions
// identical means compose_mul() on the CPU predicts the hardware result.

#pragma once

#include <cstdint>
#include <cstddef>

namespace ostomachion::filter {

// One per-bin complex coefficient, Q1.15.  Layout-compatible with
// fft_sample_t ({int16_t re; int16_t im;}) so the HAL can pass the buffer
// straight to the C driver's raw coefficient loader.
struct Coeff {
    int16_t re;
    int16_t im;
};

// Brick-wall filter kinds.  "Arbitrary combinations" are built by composing
// these with compose_mul() (cascade / logical-AND of passbands) and
// compose_max() (parallel / logical-OR of passbands).
enum class Kind {
    LowPass,
    HighPass,
    BandPass,
    Notch,
};

// Folded (physical) frequency index of bin k for an N-point FFT: bins k and
// N-k alias to the same |frequency|, so folded_freq is symmetric about N/2
// and ranges 0..N/2.  This is what makes synth() output Hermitian-symmetric.
constexpr int folded_freq(int k, int N) noexcept
{
    const int mirror = N - k;
    return (k <= mirror) ? k : mirror;
}

// Reduce a Q2.30 product (the result of multiplying two Q1.15 values) back to
// a saturated Q1.15 int16, round-half-up.  Identical policy to the fabric
// cmpy_normalizer so on-CPU composition predicts on-FPGA behaviour.
constexpr int16_t sat_round_q15(int64_t prod_q30) noexcept
{
    // Parenthesise the bias: '+' binds tighter than '<<', so the shift must be
    // computed first and added, not (prod + 1) << 14.
    int64_t r = (prod_q30 + (static_cast<int64_t>(1) << 14)) >> 15;
    if (r > 32767) {
        r = 32767;
    } else if (r < -32768) {
        r = -32768;
    }
    return static_cast<int16_t>(r);
}

// Synthesise a brick-wall mask of length N into out[0..N-1].
//
// Band edges are given as folded-frequency bin indices (0..N/2):
//   LowPass  — passband f <= hi          (caller: hi = cutoff)
//   HighPass — passband f >= lo          (caller: lo = cutoff)
//   BandPass — passband lo <= f <= hi
//   Notch    — stopband lo <= f <= hi    (pass everything else)
//
// Passband bins get { gain, 0 }; stopband bins get { 0, 0 }.
inline void synth(Kind kind, int N, int lo, int hi, int16_t gain, Coeff *out) noexcept
{
    for (int k = 0; k < N; ++k) {
        const int f = folded_freq(k, N);
        bool pass;
        switch (kind) {
        case Kind::LowPass:  pass = (f <= hi);            break;
        case Kind::HighPass: pass = (f >= lo);            break;
        case Kind::BandPass: pass = (f >= lo && f <= hi); break;
        case Kind::Notch:    pass = (f < lo  || f > hi);  break;
        default:             pass = false;                break;
        }
        out[k].re = pass ? gain : static_cast<int16_t>(0);
        out[k].im = 0;
    }
}

// All-pass mask: every bin = { gain, 0 }.  Used for the round-trip identity
// test and as the neutral element for compose_mul().
inline void all_pass(int N, int16_t gain, Coeff *out) noexcept
{
    for (int k = 0; k < N; ++k) {
        out[k].re = gain;
        out[k].im = 0;
    }
}

// Complex Q1.15 multiply with the hardware round/saturate reduction.
constexpr Coeff cmul_q15(Coeff a, Coeff b) noexcept
{
    const int64_t pr = static_cast<int64_t>(a.re) * b.re - static_cast<int64_t>(a.im) * b.im;
    const int64_t pi = static_cast<int64_t>(a.re) * b.im + static_cast<int64_t>(a.im) * b.re;
    return Coeff{ sat_round_q15(pr), sat_round_q15(pi) };
}

// Cascade two masks (logical-AND of passbands): out[k] = a[k] * b[k].
// out may alias a or b.
inline void compose_mul(const Coeff *a, const Coeff *b, int N, Coeff *out) noexcept
{
    for (int k = 0; k < N; ++k) {
        out[k] = cmul_q15(a[k], b[k]);
    }
}

// Combine two masks in parallel (logical-OR of passbands): per bin keep the
// coefficient with the larger magnitude.  out may alias a or b.
inline void compose_max(const Coeff *a, const Coeff *b, int N, Coeff *out) noexcept
{
    for (int k = 0; k < N; ++k) {
        const int64_t ma = static_cast<int64_t>(a[k].re) * a[k].re +
                           static_cast<int64_t>(a[k].im) * a[k].im;
        const int64_t mb = static_cast<int64_t>(b[k].re) * b[k].re +
                           static_cast<int64_t>(b[k].im) * b[k].im;
        out[k] = (ma >= mb) ? a[k] : b[k];
    }
}

}  // namespace ostomachion::filter
