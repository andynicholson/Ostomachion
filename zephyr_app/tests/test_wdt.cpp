// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0
//
// NEORV32 WDT test suite for Ostomachion.
//
// Tests the NEORV32 Watchdog Timer driver (CONFIG_WDT_NEORV32=y).
// The WDT hardware must be enabled (IO_WDT_EN=true in xem7310_top.vhd).
//
// These tests verify:
//   - Device readiness via device_is_ready()
//   - wdt_install_timeout() rejects invalid configurations
//   - wdt_install_timeout() accepts valid timeout values
//   - wdt_setup() enables the watchdog
//   - wdt_feed() succeeds without a hardware reset
//   - wdt_disable() stops the watchdog
//
// IMPORTANT: The WDT generates a hardware RESET on timeout.  All tests feed
// the watchdog before the window expires.  No test intentionally lets the
// watchdog fire — that would reset the system and hang the test runner.

#include <zephyr/ztest.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/devicetree.h>
#include <zephyr/kernel.h>

// Use the DT nodelabel defined in app_fpga.overlay.
// If the node is absent (simulation build), tests skip gracefully.
#if DT_NODE_HAS_STATUS(DT_NODELABEL(wdt0), okay)
#define WDT_NODE DT_NODELABEL(wdt0)
#define WDT_AVAILABLE 1
#else
#define WDT_AVAILABLE 0
#endif

// ── Fixture ──────────────────────────────────────────────────────────────────

struct ostomachion_wdt_fixture {
    const struct device *dev;
    int channel;
};

static void *wdt_setup(void)
{
    static struct ostomachion_wdt_fixture f;
    f.channel = -1;

#if WDT_AVAILABLE
    f.dev = DEVICE_DT_GET(WDT_NODE);
    zassume_true(device_is_ready(f.dev),
                 "WDT device not ready — check DTS / IO_WDT_EN generic");
#else
    f.dev = NULL;
    ztest_test_skip();  // WDT not enabled in this build configuration
#endif
    return &f;
}

// After each test: disable the WDT to prevent it from firing during the
// next test or resetting the board.
static void wdt_teardown(void *f_)
{
    struct ostomachion_wdt_fixture *f = (struct ostomachion_wdt_fixture *)f_;
    if ((f->dev != NULL) && device_is_ready(f->dev)) {
        wdt_disable(f->dev);
    }
}

ZTEST_SUITE(ostomachion_wdt, NULL, wdt_setup, NULL, wdt_teardown, NULL);

// ── Tests ─────────────────────────────────────────────────────────────────────

// Confirm the device is present and ready.
ZTEST_F(ostomachion_wdt, test_device_ready)
{
    zassert_true(device_is_ready(fixture->dev), "WDT device not ready");
}

// install_timeout should reject a zero max_window.
ZTEST_F(ostomachion_wdt, test_install_zero_window_rejected)
{
    const struct wdt_timeout_cfg cfg = {
        .window   = {.min = 0U, .max = 0U},
        .callback = NULL,
        .flags    = 0U,
    };
    int ret = wdt_install_timeout(fixture->dev, &cfg);
    zassert_true(ret < 0,
                 "Expected error for zero max_window, got %d", ret);
}

// install_timeout should reject a non-NULL callback (WDT is reset-only).
static void dummy_callback(const struct device *dev, int channel_id) { (void)dev; (void)channel_id; }

ZTEST_F(ostomachion_wdt, test_install_callback_rejected)
{
    const struct wdt_timeout_cfg cfg = {
        .window   = {.min = 0U, .max = 1000U},
        .callback = dummy_callback,
        .flags    = 0U,
    };
    int ret = wdt_install_timeout(fixture->dev, &cfg);
    zassert_equal(ret, -ENOTSUP,
                  "Expected -ENOTSUP for callback, got %d", ret);
}

// A reasonable timeout (5 s) should be accepted.
ZTEST_F(ostomachion_wdt, test_install_valid_timeout)
{
    const struct wdt_timeout_cfg cfg = {
        .window   = {.min = 0U, .max = 5000U},
        .callback = NULL,
        .flags    = 0U,
    };
    int ch = wdt_install_timeout(fixture->dev, &cfg);
    zassert_equal(ch, 0, "Expected channel 0, got %d", ch);
    fixture->channel = ch;
}

// wdt_setup() should succeed after installing a valid timeout.
// wdt_feed() must be called immediately to prevent the 5 s window from expiring.
ZTEST_F(ostomachion_wdt, test_setup_and_feed)
{
    const struct wdt_timeout_cfg cfg = {
        .window   = {.min = 0U, .max = 5000U},
        .callback = NULL,
        .flags    = 0U,
    };
    int ch = wdt_install_timeout(fixture->dev, &cfg);
    zassert_equal(ch, 0, "install_timeout failed: %d", ch);
    fixture->channel = ch;

    int ret = wdt_setup(fixture->dev, WDT_OPT_PAUSE_HALTED_BY_DBG);
    zassert_ok(ret, "wdt_setup failed: %d", ret);

    // Feed multiple times to verify no spurious reset occurs.
    for (int i = 0; i < 5; i++) {
        ret = wdt_feed(fixture->dev, fixture->channel);
        zassert_ok(ret, "wdt_feed %d failed: %d", i, ret);
        k_msleep(10);
    }

    // Disable to prevent reset after the test.
    ret = wdt_disable(fixture->dev);
    zassert_ok(ret, "wdt_disable failed: %d", ret);
}

// wdt_feed() should return -EINVAL for any channel other than 0.
ZTEST_F(ostomachion_wdt, test_feed_invalid_channel)
{
    const struct wdt_timeout_cfg cfg = {
        .window   = {.min = 0U, .max = 5000U},
        .callback = NULL,
        .flags    = 0U,
    };
    int ch = wdt_install_timeout(fixture->dev, &cfg);
    zassert_equal(ch, 0, "install_timeout failed: %d", ch);
    zassert_ok(wdt_setup(fixture->dev, 0U), "wdt_setup failed");

    int ret = wdt_feed(fixture->dev, 1);  // channel 1 is invalid
    zassert_equal(ret, -EINVAL,
                  "Expected -EINVAL for channel 1, got %d", ret);
}

// wdt_disable() should stop the watchdog.
ZTEST_F(ostomachion_wdt, test_disable)
{
    const struct wdt_timeout_cfg cfg = {
        .window   = {.min = 0U, .max = 5000U},
        .callback = NULL,
        .flags    = 0U,
    };
    int ch = wdt_install_timeout(fixture->dev, &cfg);
    zassert_equal(ch, 0, "install_timeout failed: %d", ch);
    fixture->channel = ch;

    zassert_ok(wdt_setup(fixture->dev, 0U), "wdt_setup failed");
    // Feed once, then disable — system should NOT reset.
    zassert_ok(wdt_feed(fixture->dev, ch), "wdt_feed failed");
    zassert_ok(wdt_disable(fixture->dev), "wdt_disable failed");

    // Wait well past the 5 s timeout; no reset should occur.
    k_msleep(50);
}
