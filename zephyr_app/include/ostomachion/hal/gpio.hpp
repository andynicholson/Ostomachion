// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// ostomachion::hal::GpioOutput — zero-overhead C++20 wrapper around the
// Zephyr GPIO driver API.  A future GpioInput class lives alongside this one.

#pragma once

#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>

namespace ostomachion::hal {

// Owns a single GPIO pin configured as an active-high output.
// Construction calls gpio_pin_configure_dt(); on failure the system panics
// immediately — a misconfigured pin is an unrecoverable hardware error.
class GpioOutput {
public:
    explicit GpioOutput(const gpio_dt_spec &spec) : spec_(spec)
    {
        if (gpio_pin_configure_dt(&spec_, GPIO_OUTPUT_ACTIVE) < 0) {
            k_panic();
        }
    }

    // Drive the pin high (active=true) or low (active=false).
    void set(bool active) noexcept
    {
        gpio_pin_set_dt(&spec_, static_cast<int>(active));
    }

    // Toggle the pin state.
    void toggle() noexcept { gpio_pin_toggle_dt(&spec_); }

private:
    gpio_dt_spec spec_;
};

} // namespace ostomachion::hal
