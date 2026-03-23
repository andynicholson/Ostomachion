// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// ostomachion::hal::GpioInput — zero-overhead C++20 wrapper around the
// Zephyr GPIO driver API for input-configured pins.
//
// Usage:
//   // Declare a GPIO input using a DTS spec (from app.overlay / board .dts)
//   ostomachion::hal::GpioInput btn{GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios)};
//
//   bool pressed = btn.get();      // sample the pin level
//   bool active  = btn.is_active();// true when pin is in its active state
//
// The pin is configured with GPIO_INPUT at construction.  gpio_pin_configure_dt
// failures panic immediately — a misconfigured pin is an unrecoverable error.

#pragma once

#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>

namespace ostomachion::hal {

// Owns a single GPIO pin configured as an active-high input.
// Non-copyable and non-movable to prevent aliasing of the underlying gpio_dt_spec.
class GpioInput {
public:
    explicit GpioInput(const gpio_dt_spec &spec) : spec_(spec)
    {
        if (gpio_pin_configure_dt(&spec_, GPIO_INPUT) < 0) {
            k_panic();
        }
    }

    GpioInput(const GpioInput &)            = delete;
    GpioInput &operator=(const GpioInput &) = delete;

    // Return the raw logical pin level (true = high, false = low).
    // On NEORV32, this reads the GPIO INPUT port register directly.
    [[nodiscard]] bool get() const noexcept
    {
        return gpio_pin_get_dt(&spec_) > 0;
    }

    // Return true when the pin is in its "active" state as defined by the
    // DTS gpio-active-high / gpio-active-low flags.
    [[nodiscard]] bool is_active() const noexcept
    {
        return gpio_pin_get_dt(&spec_) == 1;
    }

private:
    gpio_dt_spec spec_;
};

} // namespace ostomachion::hal
