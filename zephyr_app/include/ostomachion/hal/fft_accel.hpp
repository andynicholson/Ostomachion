// fft_accel.hpp — C++20 RAII HAL for the Ostomachion FFT accelerator
// Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// Usage:
//   #include <ostomachion/hal/fft_accel.hpp>
//
//   const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
//   ostomachion::FftAccel accel{dev};
//
//   static fft_sample_t in[4096]{};
//   static fft_sample_t out[4096]{};
//   // fill in[] ...
//   int rc = accel.transform(in, out, 4096);   // direct typed interface
//   // OR, via the generic Accel platform interface:
//   ostomachion::FftOpDesc op{in, out, 4096};
//   rc = accel.submit(op);
//   if (accel.last_overflow()) { /* reduce input amplitude */ }

#pragma once

#include <ostomachion/accel.hpp>
#include <zephyr/device.h>
#include <zephyr/drivers/misc/fft_accel.h>
#include <cstddef>

namespace ostomachion {

// ── FftOpDesc ──────────────────────────────────────────────────────────────
//
// Operation descriptor for one N-point FFT.
// Passed to FftAccel::submit() via the generic Accel interface.
//
struct FftOpDesc : AccelOpDesc {
    const fft_sample_t *in;   ///< Input samples (Q1.15 complex), length n
    fft_sample_t       *out;  ///< Output buffer, length n
    size_t              n;    ///< Transform length (must be 4096)

    FftOpDesc(const fft_sample_t *in_, fft_sample_t *out_, size_t n_)
        : AccelOpDesc{AccelOpDesc::Type::Fft}, in{in_}, out{out_}, n{n_} {}
};

// ── FftAccel ───────────────────────────────────────────────────────────────
//
// Concrete accelerator class for the Xilinx xfft hardware pipeline.
// Inherits from Accel so it can be stored as ostomachion::Accel& in a
// platform-wide accelerator table without knowing the concrete type.
//
class FftAccel : public Accel {
public:
    explicit FftAccel(const struct device *dev) : dev_{dev}
    {
        if (!device_is_ready(dev_)) {
            dev_ = nullptr;
        }
    }

    /** @return true if the underlying device is ready */
    [[nodiscard]] bool ready() const noexcept override { return dev_ != nullptr; }

    /**
     * @brief Submit an FftOpDesc operation and wait for completion.
     *
     * @p op must be an FftOpDesc; passing any other AccelOpDesc type
     * returns -EINVAL.
     *
     * @param op  FftOpDesc carrying in/out buffers and transform length.
     * @return 0 on success, negative errno on failure.
     */
    [[nodiscard]] int submit(const AccelOpDesc &op) noexcept override
    {
        if (!ready()) {
            return -ENODEV;
        }
        /* Type discrimination without RTTI (Zephyr builds use -fno-rtti).
         * Only FftOpDesc (type_id == Type::Fft) is accepted. */
        if (op.type_id != AccelOpDesc::Type::Fft) {
            return -EINVAL;
        }
        const auto &fop = static_cast<const FftOpDesc &>(op);
        return fft_accel_transform(dev_, fop.in, fop.out, fop.n);
    }

    /**
     * @brief Return true if the last submit() detected xfft fixed-point overflow.
     *
     * The overflow flag is captured by a fabric sticky latch and read back over
     * the AXI GPIO input channel inside fft_accel_transform() (NOT via an
     * interrupt — see ACCEL_ARCH.md §2.3); it reflects the most recent
     * transform.  Check this after submit() returns 0 to detect silent
     * magnitude corruption.
     */
    [[nodiscard]] bool last_overflow() const noexcept override
    {
        return dev_ != nullptr && fft_accel_get_last_overflow(dev_);
    }

    /**
     * @brief Run a complex FFT on the hardware (typed convenience interface).
     *
     * Not thread-safe: concurrent calls from multiple threads are serialised
     * by an internal mutex in the driver, but callers should avoid sharing
     * a single FftAccel instance across threads without external locking.
     *
     * @param in   Pointer to N input samples (Q1.15 complex).
     * @param out  Pointer to N output sample buffer.
     * @param n    Transform length (must be 4096).
     * @return 0 on success, negative errno on failure.
     */
    [[nodiscard]] int transform(const fft_sample_t *in,
                                fft_sample_t       *out,
                                size_t              n) const noexcept
    {
        if (!ready()) {
            return -ENODEV;
        }
        return fft_accel_transform(dev_, in, out, n);
    }

private:
    const struct device *dev_;
};

}  // namespace ostomachion
