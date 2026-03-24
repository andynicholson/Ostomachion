// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// ostomachion::hal::GpioOutput / GpioInput — zero-overhead C++20 wrappers
// around the Zephyr GPIO driver API.
//
// Both classes own a single pin and configure it at construction time.
// A failed gpio_pin_configure_dt() panics immediately — a misconfigured
// pin is an unrecoverable hardware error.

#pragma once

#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>

namespace ostomachion::hal {

class GpioOutput {
public:
    explicit GpioOutput(const gpio_dt_spec &spec) : spec_(spec)
    {
        if (gpio_pin_configure_dt(&spec_, GPIO_OUTPUT_ACTIVE) < 0) {
            k_panic();
        }
    }

    void set(bool active) noexcept
    {
        gpio_pin_set_dt(&spec_, static_cast<int>(active));
    }

    void toggle() noexcept { gpio_pin_toggle_dt(&spec_); }

private:
    gpio_dt_spec spec_;
};

// Non-copyable to prevent aliasing of the underlying gpio_dt_spec.
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

    [[nodiscard]] bool get() const noexcept
    {
        return gpio_pin_get_dt(&spec_) > 0;
    }

    // True when the pin is in its DTS-defined active state.
    [[nodiscard]] bool is_active() const noexcept
    {
        return gpio_pin_get_dt(&spec_) == 1;
    }

private:
    gpio_dt_spec spec_;
};

} // namespace ostomachion::hal
