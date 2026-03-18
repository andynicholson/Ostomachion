#include <neorv32.h>

static void short_delay(void) {
  for (volatile int i = 0; i < 200; i++) {
    asm volatile ("nop");
  }
}

int main() {

  neorv32_uart0_setup(19200, 0);
  neorv32_uart0_puts("NEORV32 bare-metal test OK\n");

  neorv32_gpio_port_set(0);

  uint32_t state = 0;
  while (1) {
    state ^= 1;
    neorv32_gpio_port_set(state);
    short_delay();
  }

  return 0;
}
