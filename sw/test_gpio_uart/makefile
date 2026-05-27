# Bare-metal test firmware for GHDL simulation.
# Toggles GPIO pin 0 and prints via UART0 (sim mode).

MARCH = rv32i_zicsr_zifencei

EFFORT = -Os

USER_FLAGS += -DUART0_SIM_MODE
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=16k
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=8k
USER_FLAGS += -specs=picolibc.specs

NEORV32_HOME ?= ../../neorv32

include $(NEORV32_HOME)/sw/common/common.mk
