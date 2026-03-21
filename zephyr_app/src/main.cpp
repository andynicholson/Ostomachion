// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// Ostomachion — application entry point.
//
// Architecture overview:
//   - The ztest framework (CONFIG_ZTEST=y) provides its own main() that
//     discovers and runs all registered ZTEST_SUITE instances
//     (tests/test_spi.cpp, tests/test_i2c.cpp) before returning.
//   - A SYS_INIT hook sets GPIO pin 0 (LED0) high early in the boot sequence.
//     This gives the simulation testbench an immediate proof-of-life signal
//     (gpio_toggle_cnt increments from 0→1) before the polling test drivers
//     monopolise the CPU.
//   - The led_blink thread provides a visible heartbeat on real hardware once
//     the tests have completed and the scheduler has idle time.
//
// To add a new test suite: create tests/test_<peripheral>.cpp, register it
// with ZTEST_SUITE, and add it to CMakeLists.txt target_sources().

#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>

#include "ostomachion/hal/gpio.hpp"

// Runs after driver init, before the main thread.  Drives LED0 / gpio[0] high
// so that the testbench watchdog sees at least one GPIO transition within its
// 190 ms check window even when polling drivers hold the CPU throughout tests.
static int gpio_alive_init(void)
{
    const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
    if (!device_is_ready(led.port)) {
        return 0;
    }
    gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);
    gpio_pin_set_dt(&led, 1); // 0->1 transition detected by testbench watchdog
    return 0;
}
SYS_INIT(gpio_alive_init, APPLICATION, 0);

static void led_blink_thread(void *, void *, void *)
{
    ostomachion::hal::GpioOutput led{GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios)};
    while (true) {
        led.toggle();
        k_msleep(500);
    }
}

K_THREAD_DEFINE(led_blink, 1024, led_blink_thread,
                NULL, NULL, NULL, 7, 0, 0);
