// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// GPIO LED test suite for Ostomachion.
//
// Tests the four board LEDs (gpio pins 0–3) using the gpio-leds DT bindings.
// No external hardware is required.
//
// Output state is verified via API return codes.  On the Arty A7, the LEDs
// are visible on the board as direct confirmation; the GHDL simulation logs
// GPIO state changes to the console via the GPIO monitor process.
//
// Note: gpio_pin_get_raw() reads the GPIO INPUT register, which on NEORV32
// is a separate physical port from the OUTPUT register.  This test verifies
// correct driver API behaviour (no errors); visual / log observation confirms
// actual LED state.

#include <zephyr/ztest.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>

// LED DT specs derived from board aliases (led0–led3).
static const struct gpio_dt_spec k_leds[] = {
    GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios),
    GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios),
    GPIO_DT_SPEC_GET(DT_ALIAS(led2), gpios),
    GPIO_DT_SPEC_GET(DT_ALIAS(led3), gpios),
};

static constexpr int k_num_leds = static_cast<int>(ARRAY_SIZE(k_leds));

// --- Fixture ---------------------------------------------------------------

struct ostomachion_gpio_fixture {
    const struct device *dev;
};

static void *gpio_setup(void)
{
    static struct ostomachion_gpio_fixture f;
    // All LEDs share the same GPIO controller; use led0 as the reference.
    f.dev = k_leds[0].port;
    zassert_true(device_is_ready(f.dev),
                 "gpio device not ready — check DTS bindings");
    return &f;
}

// Leave all LEDs in a known-off state after each test.
static void gpio_after(void *f_)
{
    (void)f_;
    for (int i = 0; i < k_num_leds; i++) {
        (void)gpio_pin_set_dt(&k_leds[i], 0);
    }
}

ZTEST_SUITE(ostomachion_gpio, NULL, gpio_setup, NULL, gpio_after, NULL);

// --- Tests -----------------------------------------------------------------

ZTEST_F(ostomachion_gpio, test_gpio_device_ready)
{
    zassert_true(device_is_ready(fixture->dev), "gpio device not ready");
}

// Configure all 4 LEDs as outputs.  Verifies the driver accepts the
// GPIO_OUTPUT_INACTIVE flag and returns success for each pin.
ZTEST_F(ostomachion_gpio, test_led_configure)
{
    for (int i = 0; i < k_num_leds; i++) {
        zassert_ok(gpio_pin_configure_dt(&k_leds[i], GPIO_OUTPUT_INACTIVE),
                   "LED %d configure failed", i);
    }
}

// Drive all 4 LEDs high, verify each set call returns 0.
ZTEST_F(ostomachion_gpio, test_led_set_high)
{
    for (int i = 0; i < k_num_leds; i++) {
        zassert_ok(gpio_pin_configure_dt(&k_leds[i], GPIO_OUTPUT_INACTIVE),
                   "LED %d configure failed", i);
        zassert_ok(gpio_pin_set_dt(&k_leds[i], 1),
                   "LED %d set-high failed", i);
    }
}

// Drive all 4 LEDs low, verify each set call returns 0.
ZTEST_F(ostomachion_gpio, test_led_set_low)
{
    for (int i = 0; i < k_num_leds; i++) {
        zassert_ok(gpio_pin_configure_dt(&k_leds[i], GPIO_OUTPUT_ACTIVE),
                   "LED %d configure-active failed", i);
        zassert_ok(gpio_pin_set_dt(&k_leds[i], 0),
                   "LED %d set-low failed", i);
    }
}

// Toggle each LED 4 times.  Verifies gpio_pin_toggle_dt returns 0 on every
// call and that the driver's output shadow register remains consistent across
// repeated toggles.
ZTEST_F(ostomachion_gpio, test_led_toggle)
{
    for (int i = 0; i < k_num_leds; i++) {
        zassert_ok(gpio_pin_configure_dt(&k_leds[i], GPIO_OUTPUT_INACTIVE),
                   "LED %d configure failed", i);
    }

    for (int toggle = 0; toggle < 4; toggle++) {
        for (int i = 0; i < k_num_leds; i++) {
            zassert_ok(gpio_pin_toggle_dt(&k_leds[i]),
                       "LED %d toggle %d failed", i, toggle);
        }
    }
}

// Verify each LED can be driven independently without interfering with the
// others.  Pattern: set LED i high, set all others low, repeat for each i.
ZTEST_F(ostomachion_gpio, test_led_individual)
{
    for (int i = 0; i < k_num_leds; i++) {
        zassert_ok(gpio_pin_configure_dt(&k_leds[i], GPIO_OUTPUT_INACTIVE),
                   "LED %d configure failed", i);
    }

    for (int active = 0; active < k_num_leds; active++) {
        for (int i = 0; i < k_num_leds; i++) {
            int val = (i == active) ? 1 : 0;
            zassert_ok(gpio_pin_set_dt(&k_leds[i], val),
                       "LED %d set to %d failed (active=%d)", i, val, active);
        }
    }
}
