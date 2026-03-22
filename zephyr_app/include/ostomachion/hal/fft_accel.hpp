// fft_accel.hpp — C++20 RAII HAL for the Ostomachion FFT accelerator
// Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
//
// Usage:
//   #include <ostomachion/hal/fft_accel.hpp>
//
//   const struct device *dev = DEVICE_DT_GET(DT_NODELABEL(fft_accel));
//   ostomachion::FftAccel accel{dev};
//
//   fft_sample_t in[64]{};
//   fft_sample_t out[64]{};
//   // fill in[] ...
//   accel.transform(in, out, 64);

#pragma once

#include <zephyr/device.h>
#include <zephyr/drivers/misc/fft_accel.h>
#include <cstdint>
#include <cstddef>

namespace ostomachion {

/**
 * @brief C++20 RAII wrapper for the FFT hardware accelerator.
 *
 * Acquires the device at construction and provides a typed transform()
 * method.  The device is not released on destruction (it persists for
 * the system lifetime).
 */
class FftAccel {
public:
    explicit FftAccel(const struct device *dev) : dev_{dev}
    {
        if (!device_is_ready(dev_)) {
            dev_ = nullptr;
        }
    }

    /* Non-copyable, non-movable: copying would silently alias the device
     * pointer with no shared access control, leading to concurrent-use bugs. */
    FftAccel(const FftAccel &)            = delete;
    FftAccel &operator=(const FftAccel &) = delete;
    FftAccel(FftAccel &&)                 = delete;
    FftAccel &operator=(FftAccel &&)      = delete;

    /** @return true if the underlying device is ready */
    [[nodiscard]] bool ready() const noexcept { return dev_ != nullptr; }

    /**
     * @brief Run a complex FFT on the hardware.
     *
     * Not thread-safe: concurrent calls from multiple threads are serialised
     * by an internal mutex in the driver, but callers should avoid sharing
     * a single FftAccel instance across threads without external locking.
     *
     * @param in   Pointer to N input samples (Q1.15 complex).
     * @param out  Pointer to N output sample buffer.
     * @param n    Transform length (must be 64).
     * @return 0 on success, negative errno on failure.
     */
    int transform(const fft_sample_t *in,
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
