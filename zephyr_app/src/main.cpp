#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>

class LedController {
public:
    explicit LedController(const struct gpio_dt_spec &spec) : spec_(spec) {
        gpio_pin_configure_dt(&spec_, GPIO_OUTPUT_ACTIVE);
    }

    void toggle() {
        gpio_pin_toggle_dt(&spec_);
    }

private:
    struct gpio_dt_spec spec_;
};

int main() {
    static const struct gpio_dt_spec led0 = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

    auto my_led = LedController(led0);

    printk("NEORV32 + Zephyr + C++20 Booted!\n");

    while (true) {
        my_led.toggle();
        k_msleep(500);
    }

    return 0;
}
