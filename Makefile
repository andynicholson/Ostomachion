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

# ---------- FPGA / Arty A7 settings ------------------------------------------
# Override on the command line, e.g.: make fpga-synth VIVADO=/opt/Xilinx/Vivado/2024.1/bin/vivado
VIVADO      ?= vivado
OPENOCD     ?= openocd
UART_DEVICE ?= /dev/ttyUSB1

FPGA_DIR             = fpga/arty_a7
ZEPHYR_BUILD_FPGA    = build_zephyr_fpga
ZEPHYR_BUILD_HW_TEST = build_zephyr_hw_test
ZEPHYR_BUILD_ACCEL   = build_zephyr_accel_test
ZEPHYR_BUILD_SHELL   = build_zephyr_shell
BIT_FILE             = build/arty_a7/ostomachion_arty_a7.bit
MCS_FILE             = build/arty_a7/ostomachion_arty_a7.mcs

.PHONY: all analyze simulate clean sw test-baremetal test-default test-zephyr zephyr \
        zephyr-fpga fpga-synth fpga-program fpga-flash fpga-fw fpga-check fpga-release \
        test-hw test-accel-hw shell-hw

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
	$(MAKE) IMEM_IMAGE=zephyr_imem_image.vhd SIM_TIME=$(SIM_TIME) all

clean-ghdl:
	@echo "=== Cleaning GHDL artifacts ==="
	ghdl --clean --work=neorv32 2>/dev/null || true
	ghdl --clean --work=work    2>/dev/null || true
	rm -f *.o *.cf output.ghw neorv32_tb UART0.log

clean: clean-ghdl
	@echo "=== Cleaning SW build ==="
	$(MAKE) -C $(SW_DIR) RISCV_PREFIX=$(RISCV_PREFIX) clean 2>/dev/null || true
	rm -f test_imem_image.vhd zephyr_imem_image.vhd
	rm -rf $(ZEPHYR_BUILD_DIR) $(ZEPHYR_BUILD_FPGA) $(ZEPHYR_BUILD_HW_TEST) \
	       $(ZEPHYR_BUILD_ACCEL) $(ZEPHYR_BUILD_SHELL)

# ---------- FPGA targets (Arty A7) -------------------------------------------

## Build Zephyr firmware for the FPGA target.
## Applies app_fpga.overlay (115200 baud) and prj_fpga.conf (IRQ drivers,
## larger stacks).  Output ELF: $(ZEPHYR_BUILD_FPGA)/zephyr/zephyr.elf
zephyr-fpga:
	@echo "=== Building Zephyr FPGA firmware ==="
	west build -b $(ZEPHYR_BOARD) $(ZEPHYR_APP_DIR) \
		-d $(ZEPHYR_BUILD_FPGA) --pristine=auto \
		-- -DCMAKE_PROGRAM_PATH=$(IMAGE_GEN_DIR) \
		   -DDTC_OVERLAY_FILE="$(CURDIR)/$(ZEPHYR_APP_DIR)/app.overlay;$(CURDIR)/$(ZEPHYR_APP_DIR)/app_fpga.overlay" \
		   -DOVERLAY_CONFIG="$(CURDIR)/$(ZEPHYR_APP_DIR)/prj.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_fpga.conf"

## Synthesise, implement and generate the Arty A7 bitstream via Vivado batch mode.
## Requires Vivado to be on PATH or VIVADO variable set.
## Output: build/arty_a7/ostomachion_arty_a7.bit
fpga-synth:
	@echo "=== Running Vivado batch build ==="
	mkdir -p build/arty_a7
	@command -v "$(VIVADO)" >/dev/null 2>&1 || { echo "ERROR: '$(VIVADO)' not found — install Vivado and add to PATH or set VIVADO=/path/to/vivado"; exit 1; }
	bash -o pipefail -c '$(VIVADO) -mode batch -source $(FPGA_DIR)/build.tcl 2>&1 | tee build/arty_a7/build.log'
	@echo "=== Bitstream: $(BIT_FILE) ==="

## Program the Arty A7 bitstream over JTAG using OpenOCD.
## The bitstream is loaded into SRAM (volatile; erased on power-cycle).
## Requires OpenOCD ≥ 0.12 with Xilinx support and the Digilent FTDI driver.
fpga-program: $(BIT_FILE)
	@echo "=== Programming Arty A7 via JTAG ==="
	$(OPENOCD) -f $(FPGA_DIR)/openocd.cfg \
		-c "pld load 0 $(BIT_FILE)" \
		-c shutdown

## Write the bitstream to the on-board Quad-SPI flash for persistent boot.
## After this operation the FPGA loads the design automatically on every
## power-up without needing fpga-program.
## Requires: fpga-synth must have been run (produces the .mcs file).
## Requires: Vivado on PATH and JTAG cable connected.
fpga-flash: $(MCS_FILE)
	@echo "=== Programming Arty A7 Quad-SPI flash via Vivado ==="
	$(VIVADO) -mode batch -source $(FPGA_DIR)/program_flash.tcl \
		-tclargs $(MCS_FILE) \
		| tee build/arty_a7/flash_program.log
	@echo "=== Flash programming complete — FPGA will auto-boot on next power-up ==="

## Upload Zephyr firmware to the NEORV32 bootloader over UART.
## The NEORV32 BROM bootloader listens at 19200 baud on UART0 immediately
## after reset.  Use this target for firmware iteration without re-synthesising.
## Prerequisites: zephyr-fpga must have been built; board must be reset.
fpga-fw: zephyr-fpga
	@echo "=== Uploading firmware via NEORV32 UART bootloader ==="
	python3 $(NEORV32_HOME)/sw/bootloader/neorv32_upload.py \
		--port $(UART_DEVICE) \
		$(ZEPHYR_BUILD_FPGA)/zephyr/zephyr.bin
	@echo "=== Firmware upload complete ==="

## Stage release certification artifacts into release/<VERSION>/.
## Requires: fpga-synth must have completed successfully.
## Usage: make fpga-release VERSION=v1.0.0
fpga-release:
	@echo "=== Staging release artifacts ==="
	bash scripts/gen_release_artifacts.sh $(VERSION)

## Run post-build quality gates against an existing built project.
## Checks: timing closure (WNS/WHS >= 0), DRC errors, resource headroom.
## Does NOT re-synthesise — must run after fpga-synth.
fpga-check:
	@echo "=== Running FPGA build quality checks ==="
	$(VIVADO) -mode batch -source $(FPGA_DIR)/check_build.tcl
	@echo "=== Quality check complete ==="

## Build hardware test firmware and upload to the Arty A7 via UART bootloader.
## Combines prj.conf + prj_fpga.conf + prj_hw_test.conf (verbose output, logs,
## no I2C slave by default).  Override UART_DEVICE if your board is on a
## different port.  Bitstream must already be programmed via fpga-program.
##
## Hardware test setup:
##   SPI loopback : jumper Pmod JA pin 2 (MOSI, B11) → pin 3 (MISO, A11)
##   I2C slave    : add CONFIG_TEST_I2C_SLAVE_ADDR=<addr> to skip gracefully
##   UART output  : minicom -D $(UART_DEVICE) -b 115200
test-hw:
	@echo "=== Building Zephyr hardware test firmware ==="
	west build -b $(ZEPHYR_BOARD) $(ZEPHYR_APP_DIR) \
		-d $(ZEPHYR_BUILD_HW_TEST) --pristine=auto \
		-- -DCMAKE_PROGRAM_PATH=$(IMAGE_GEN_DIR) \
		   -DDTC_OVERLAY_FILE="$(CURDIR)/$(ZEPHYR_APP_DIR)/app.overlay;$(CURDIR)/$(ZEPHYR_APP_DIR)/app_fpga.overlay" \
		   -DOVERLAY_CONFIG="$(CURDIR)/$(ZEPHYR_APP_DIR)/prj.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_fpga.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_hw_test.conf"
	@echo "=== Uploading hardware test firmware via UART bootloader ==="
	python3 $(NEORV32_HOME)/sw/bootloader/neorv32_upload.py \
		--port $(UART_DEVICE) \
		$(ZEPHYR_BUILD_HW_TEST)/zephyr/zephyr.bin
	@echo "=== Firmware uploaded — connect a terminal at 115200 baud to see results ==="

## Build automated ZTEST image with FFT accelerator support and upload.
## Runs all ZTEST suites (spi, i2c, gpio, fft) at boot.
## Prerequisites: accelerator bitstream must be programmed via fpga-program.
## UART output at 115200 baud shows pass/fail for each test.
test-accel-hw:
	@echo "=== Building Zephyr ZTEST accelerator firmware ==="
	west build -b $(ZEPHYR_BOARD) $(ZEPHYR_APP_DIR) \
		-d $(ZEPHYR_BUILD_ACCEL) --pristine=auto \
		-- -DCMAKE_PROGRAM_PATH=$(IMAGE_GEN_DIR) \
		   -DDTC_OVERLAY_FILE="$(CURDIR)/$(ZEPHYR_APP_DIR)/app.overlay;$(CURDIR)/$(ZEPHYR_APP_DIR)/app_fpga.overlay;$(CURDIR)/$(ZEPHYR_APP_DIR)/app_accel.overlay" \
		   -DOVERLAY_CONFIG="$(CURDIR)/$(ZEPHYR_APP_DIR)/prj.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_fpga.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_accel.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_hw_test.conf"
	@echo "=== Uploading ZTEST accelerator firmware via UART bootloader ==="
	python3 $(NEORV32_HOME)/sw/bootloader/neorv32_upload.py \
		--port $(UART_DEVICE) \
		$(ZEPHYR_BUILD_ACCEL)/zephyr/zephyr.bin
	@echo "=== Firmware uploaded — connect a terminal at 115200 baud ==="

## Build interactive shell firmware with FFT commands and upload.
## Boots to Zephyr shell prompt.  No ZTEST — use 'test run' and 'fft' commands.
## Prerequisites: accelerator bitstream must be programmed via fpga-program.
shell-hw:
	@echo "=== Building Zephyr interactive shell firmware ==="
	west build -b $(ZEPHYR_BOARD) $(ZEPHYR_APP_DIR) \
		-d $(ZEPHYR_BUILD_SHELL) --pristine=auto \
		-- -DCMAKE_PROGRAM_PATH=$(IMAGE_GEN_DIR) \
		   -DDTC_OVERLAY_FILE="$(CURDIR)/$(ZEPHYR_APP_DIR)/app.overlay;$(CURDIR)/$(ZEPHYR_APP_DIR)/app_fpga.overlay;$(CURDIR)/$(ZEPHYR_APP_DIR)/app_accel.overlay" \
		   -DOVERLAY_CONFIG="$(CURDIR)/$(ZEPHYR_APP_DIR)/prj.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_fpga.conf;$(CURDIR)/$(ZEPHYR_APP_DIR)/prj_shell.conf"
	@echo "=== Uploading shell firmware via UART bootloader ==="
	python3 $(NEORV32_HOME)/sw/bootloader/neorv32_upload.py \
		--port $(UART_DEVICE) \
		$(ZEPHYR_BUILD_SHELL)/zephyr/zephyr.bin
	@echo "=== Connect at 115200 baud — type 'help' for available commands ==="

## NOTE: FFT simulation target removed.
## The FFT core is now the Xilinx xfft IP (PG109), instantiated in the
## block design.  GHDL simulation of Xilinx encrypted IP is not supported.
