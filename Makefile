NEORV32_HOME = ./neorv32
GHDL_FLAGS   = --std=08

CORE_SOURCES = $(wildcard $(NEORV32_HOME)/rtl/core/*.vhd)
SIM_SOURCES  = sim/sim_uart_rx.vhd
SIM_TIME    ?= 500us

# Override IMEM image (analyzed after core to shadow the default).
IMEM_IMAGE  ?=

# Software build settings
SW_DIR       = sw/test_gpio_uart
RISCV_PREFIX ?= riscv64-unknown-elf-

# Zephyr build settings
ZEPHYR_APP_DIR   = zephyr_app
ZEPHYR_BUILD_DIR = build_zephyr
ZEPHYR_BOARD     = neorv32/neorv32/minimalboot
IMAGE_GEN_DIR    = $(CURDIR)/neorv32/sw/image_gen

.PHONY: all analyze simulate clean sw test-baremetal test-default test-zephyr zephyr

# ---------- default flow (uses the image baked into neorv32/rtl/core) ------
all: analyze simulate

analyze:
	@echo "=== Analyzing NEORV32 core ==="
ifdef IMEM_IMAGE
	ghdl -i $(GHDL_FLAGS) --work=neorv32 \
		$(filter-out %neorv32_application_image.vhd, $(CORE_SOURCES)) \
		$(IMEM_IMAGE)
else
	ghdl -i $(GHDL_FLAGS) --work=neorv32 $(CORE_SOURCES)
endif
	@echo "=== Analyzing sim helpers ==="
	ghdl -i $(GHDL_FLAGS) --work=work $(SIM_SOURCES)
	@echo "=== Analyzing wrapper & testbench ==="
	ghdl -i $(GHDL_FLAGS) --work=work rtl/neorv32_wrapper.vhd sim/neorv32_tb.vhd

WAVE ?=

simulate:
	@echo "=== Elaborating ==="
	ghdl -m $(GHDL_FLAGS) --work=work neorv32_tb
	@echo "=== Running simulation ($(SIM_TIME)) ==="
	ghdl -r $(GHDL_FLAGS) --work=work neorv32_tb \
		$(if $(WAVE),--wave=output.ghw) \
		--stop-time=$(SIM_TIME) \
		--ieee-asserts=disable \
		--assert-level=error

# ---------- software build ------------------------------------------------
sw:
	@echo "=== Building test firmware ==="
	$(MAKE) -C $(SW_DIR) RISCV_PREFIX=$(RISCV_PREFIX) clean image
	cp $(SW_DIR)/neorv32_imem_image.vhd test_imem_image.vhd

# ---------- convenience targets -------------------------------------------
test-baremetal: sw clean-ghdl
	$(MAKE) IMEM_IMAGE=test_imem_image.vhd SIM_TIME=500us all

test-default: clean-ghdl
	$(MAKE) SIM_TIME=500us all

# ---------- Zephyr build & test -----------------------------------------------
zephyr:
	@echo "=== Building Zephyr app ==="
	west build -b $(ZEPHYR_BOARD) $(ZEPHYR_APP_DIR) \
		-d $(ZEPHYR_BUILD_DIR) --pristine=auto \
		-- -DCMAKE_PROGRAM_PATH=$(IMAGE_GEN_DIR)
	cp $(ZEPHYR_BUILD_DIR)/zephyr/zephyr.vhd zephyr_imem_image.vhd

test-zephyr: zephyr clean-ghdl
	$(MAKE) IMEM_IMAGE=zephyr_imem_image.vhd SIM_TIME=80ms all

clean-ghdl:
	@echo "=== Cleaning GHDL artifacts ==="
	ghdl --clean --work=neorv32 2>/dev/null || true
	ghdl --clean --work=work    2>/dev/null || true
	rm -f *.o *.cf output.ghw neorv32_tb UART0.log

clean: clean-ghdl
	@echo "=== Cleaning SW build ==="
	$(MAKE) -C $(SW_DIR) RISCV_PREFIX=$(RISCV_PREFIX) clean 2>/dev/null || true
	rm -f test_imem_image.vhd zephyr_imem_image.vhd
	rm -rf $(ZEPHYR_BUILD_DIR)
