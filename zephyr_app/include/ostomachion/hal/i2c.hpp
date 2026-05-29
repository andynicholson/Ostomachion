// Copyright (c) 2026
// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// ostomachion::hal::I2cBus — type-safe C++20 wrapper around the Zephyr I2C
// driver API.  Uses std::span<std::byte> for buffer arguments, eliminating
// void* + size_t pairs and providing clear const-correctness semantics.

#pragma once

#include <zephyr/drivers/i2c.h>

#include <cstddef>
#include <cstdint>
#include <span>

namespace ostomachion::hal {

// Represents an I2C bus controller.  Lightweight: stores a single device
// pointer.  Construct one per logical bus; pass by value freely.
class I2cBus {
public:
    explicit I2cBus(const struct device *bus) noexcept : bus_(bus) {}

    // Write data to a 7-bit slave address.  Returns 0 or negative errno.
    [[nodiscard]] int write(uint16_t addr,
                            std::span<const std::byte> data) noexcept
    {
        return i2c_write(bus_,
                         reinterpret_cast<const uint8_t *>(data.data()),
                         static_cast<uint32_t>(data.size()),
                         addr);
    }

    // Read data from a 7-bit slave address.  Returns 0 or negative errno.
    [[nodiscard]] int read(uint16_t addr, std::span<std::byte> data) noexcept
    {
        return i2c_read(bus_,
                        reinterpret_cast<uint8_t *>(data.data()),
                        static_cast<uint32_t>(data.size()),
                        addr);
    }

    // Combined write-then-repeated-START-then-read in a single transaction.
    // Equivalent to i2c_write_read().  Returns 0 or negative errno.
    [[nodiscard]] int write_then_read(uint16_t                   addr,
                                      std::span<const std::byte> tx,
                                      std::span<std::byte>       rx) noexcept
    {
        return i2c_write_read(bus_,
                              addr,
                              reinterpret_cast<const uint8_t *>(tx.data()),
                              static_cast<uint32_t>(tx.size()),
                              reinterpret_cast<uint8_t *>(rx.data()),
                              static_cast<uint32_t>(rx.size()));
    }

private:
    const struct device *bus_;
};

} // namespace ostomachion::hal
