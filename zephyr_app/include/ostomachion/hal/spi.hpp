// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// ostomachion::hal::SpiDevice — type-safe C++20 wrapper around the Zephyr SPI
// driver API.  Uses std::span<std::byte> instead of void* + size_t pairs to
// provide compile-time size checking and clear const-correctness semantics.

#pragma once

#include <zephyr/drivers/spi.h>

#include <cstddef>
#include <span>

namespace ostomachion::hal {

// Represents a single SPI device on a bus.  Lightweight: stores a device
// pointer and a copy of the spi_config struct (two pointer-sized fields plus
// a uint32 and a uint16).  Safe to copy and pass by value.
class SpiDevice {
public:
    SpiDevice(const struct device *bus, const spi_config &cfg) noexcept
        : bus_(bus), cfg_(cfg)
    {
    }

    // Full-duplex transfer.  tx and rx must have equal length.  Returns 0 on
    // success or a negative errno on failure.
    //
    // Note: spi_buf::buf is void* (not const void*) in the Zephyr C API — a
    // known quirk.  The TX buffer is not mutated by the driver; the
    // const_cast here is safe.
    [[nodiscard]] int transfer(std::span<const std::byte> tx,
                               std::span<std::byte>       rx) noexcept
    {
        spi_buf tx_buf = {
            .buf = const_cast<std::byte *>(tx.data()),
            .len = tx.size(),
        };
        spi_buf rx_buf = {
            .buf = rx.data(),
            .len = rx.size(),
        };
        const spi_buf_set tx_set = {.buffers = &tx_buf, .count = 1U};
        const spi_buf_set rx_set = {.buffers = &rx_buf, .count = 1U};
        return spi_transceive(bus_, &cfg_, &tx_set, &rx_set);
    }

    // Fixed-extent overload is omitted: our minimal <span> implementation uses
    // dynamic_extent only.  Call transfer(span<const byte>{arr.data(),N}, ...)
    // or let the deduction guides on span handle array arguments directly.

private:
    const struct device *bus_;
    spi_config           cfg_;
};

} // namespace ostomachion::hal
