// Copyright (c) 2026
// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
//
// Ostomachion — application entry point.
//
// Architecture overview:
//   - The ztest framework (CONFIG_ZTEST=y) provides its own main() that
//     discovers and runs all registered ZTEST_SUITE instances under tests/
//     before returning: test_spi, test_i2c, test_gpio, plus test_wdt
//     (CONFIG_WDT_NEORV32) and test_fft_accel (CONFIG_FFT_ACCEL) — see
//     CMakeLists.txt for the gating.
//   - A SYS_INIT hook sets GPIO pin 0 (LED0) high early in the boot sequence.
//     This gives the simulation testbench an immediate proof-of-life signal
//     (gpio_toggle_cnt increments from 0→1) before the polling test drivers
//     monopolise the CPU.
//   - The led_blink thread provides a visible heartbeat on real hardware once
//     the tests have completed and the scheduler has idle time.
//   - When CONFIG_WDT_NEORV32=y (FPGA target), the led_blink thread also feeds
//     the hardware watchdog every 500 ms.  The WDT timeout is 5 s by default
//     (configured in wdt_setup_fpga); if the LED thread hangs for more than
//     5 s the system resets automatically.
//
// To add a new test suite: create tests/test_<peripheral>.cpp, register it
// with ZTEST_SUITE, and add it to CMakeLists.txt target_sources().

#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>

#ifdef CONFIG_WDT_NEORV32
#include <zephyr/drivers/watchdog.h>
#endif

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

#ifdef CONFIG_WDT_NEORV32
// WDT channel ID returned by wdt_install_timeout(); stored for wdt_feed().
static int g_wdt_channel_id = -1;

// Initialise the hardware watchdog with a 5-second timeout.
// Called from led_blink_thread before the blink loop starts so that the
// WDT is only armed once the system has fully booted.
static void wdt_setup_fpga(const struct device *wdt_dev)
{
    if (!device_is_ready(wdt_dev)) {
        return;
    }

    static const struct wdt_timeout_cfg wdt_cfg = {
        .window =
            {
                .min = 0U,
                .max = 5000U, // 5 s timeout; LED thread feeds every 500 ms
            },
        .callback = NULL, // reset-only mode
        .flags    = 0U,
    };

    g_wdt_channel_id = wdt_install_timeout(wdt_dev, &wdt_cfg);
    if (g_wdt_channel_id < 0) {
        return;
    }

    wdt_setup(wdt_dev, WDT_OPT_PAUSE_HALTED_BY_DBG);
}
#endif // CONFIG_WDT_NEORV32

static void led_blink_thread(void *, void *, void *)
{
    ostomachion::hal::GpioOutput led{GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios)};

#ifdef CONFIG_WDT_NEORV32
    const struct device *wdt_dev = DEVICE_DT_GET_OR_NULL(DT_NODELABEL(wdt0));
    wdt_setup_fpga(wdt_dev);
#endif

    while (true) {
        led.toggle();
        k_msleep(500);

#ifdef CONFIG_WDT_NEORV32
        if ((wdt_dev != NULL) && (g_wdt_channel_id >= 0)) {
            wdt_feed(wdt_dev, g_wdt_channel_id);
        }
#endif
    }
}

K_THREAD_DEFINE(led_blink, 1536, led_blink_thread,
                NULL, NULL, NULL, 7, 0, 0);
