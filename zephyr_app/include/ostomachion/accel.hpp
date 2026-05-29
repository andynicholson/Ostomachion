// ostomachion/accel.hpp — Generic hardware accelerator abstraction
// Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// Defines the minimal vendor accelerator interface for the Ostomachion
// platform.  Every hardware accelerator driver (FFT, matrix multiply,
// crypto engine, …) provides a concrete class inheriting from Accel.
//
// Design goals:
//   - Zero virtual dispatch overhead on the critical path: submit() delegates
//     to the driver's MMIO control path, not a vtable chain.
//   - Extensible: new accelerators add a new AccelOpDesc subclass and a new
//     Accel subclass without touching existing drivers.
//   - C++20: uses [[nodiscard]], concepts where available.
//
// Usage example (FFT):
//   ostomachion::FftAccel fft{DEVICE_DT_GET(DT_NODELABEL(fft_accel))};
//   ostomachion::FftOpDesc op{in_buf, out_buf, 64};
//   int rc = fft.submit(op);   // blocks until complete
//   bool overflow = fft.last_overflow();

#pragma once

/* errno constants (ENODEV, EINVAL, …) arrive through the Zephyr include
 * chain when this header is used within the Zephyr build system.
 * <cerrno> is not available in Zephyr's -nostdinc++ minimal C++ environment;
 * errno.h is included transitively by <zephyr/device.h> in every TU that
 * uses this header. */
#include <cstddef>   /* size_t — provided by Zephyr's minimal C++ support */

namespace ostomachion {

// ── AccelOpDesc ────────────────────────────────────────────────────────────
//
// Base descriptor for one hardware accelerator operation.
// Concrete operation types derive from this (e.g. FftOpDesc).
// The type_id field enables type discrimination without RTTI (Zephyr builds
// typically compile with -fno-rtti).
//
struct AccelOpDesc {
    /** Identifies the concrete op type so submit() can safely static_cast. */
    enum class Type : unsigned {
        Unknown = 0,
        Fft     = 1,
        /* Add new accelerator types here */
    };

    const Type type_id;  ///< Set by concrete subclass constructor

    // Non-copyable to prevent accidental sharing between concurrent calls.
    AccelOpDesc(const AccelOpDesc &)            = delete;
    AccelOpDesc &operator=(const AccelOpDesc &) = delete;

    ~AccelOpDesc() = default;  /* Non-virtual: base should not be deleted polymorphically */

protected:
    explicit AccelOpDesc(Type t = Type::Unknown) : type_id{t} {}
};

// ── Accel (abstract base) ──────────────────────────────────────────────────
//
// Abstract interface every Ostomachion hardware accelerator driver exposes.
//
// Thread-safety contract:
//   - submit() is synchronous and serialised internally (mutex or similar).
//   - ready() and last_overflow() are idempotent reads; callers must not
//     call submit() from two threads on the same Accel instance without
//     external synchronisation.
//
class Accel {
public:
    virtual ~Accel() = default;

    // Non-copyable, non-movable to prevent aliasing bugs.
    Accel(const Accel &)            = delete;
    Accel &operator=(const Accel &) = delete;
    Accel(Accel &&)                 = delete;
    Accel &operator=(Accel &&)      = delete;

    /**
     * @brief Return true if the underlying Zephyr device is ready.
     *
     * A false return means init failed or the device was not matched in DTS.
     * submit() returns -ENODEV when !ready().
     */
    [[nodiscard]] virtual bool ready() const noexcept = 0;

    /**
     * @brief Submit one accelerator operation and wait for completion.
     *
     * Blocks the calling thread until hardware signals completion or the
     * implementation-defined timeout elapses.
     *
     * @param op  Operation descriptor (concrete subclass of AccelOpDesc).
     * @return 0 on success, negative errno on failure:
     *         -ENODEV   device not ready
     *         -EINVAL   unsupported op parameters
     *         -ETIMEDOUT hardware did not complete in time
     *         -EIO      hardware error (DMA, bus, …)
     */
    [[nodiscard]] virtual int submit(const AccelOpDesc &op) noexcept = 0;

    /**
     * @brief Return true if the most recent submit() detected a numeric
     *        overflow in the hardware data path.
     *
     * The flag is cleared at the start of each submit() call.
     * Not all accelerator types support overflow detection; implementations
     * that do not may return false unconditionally.
     */
    [[nodiscard]] virtual bool last_overflow() const noexcept { return false; }

protected:
    Accel() = default;
};

}  // namespace ostomachion
