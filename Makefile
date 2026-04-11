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

# ---------- FPGA / Opal Kelly XEM7310-A200 settings ---------------------------
# Override on the command line, e.g.: make fpga-synth VIVADO=/opt/Xilinx/Vivado/2024.1/bin/vivado
VIVADO      ?= vivado
OPENOCD     ?= openocd
UART_DEVICE ?= /dev/ttyUSB0

# FrontPanel SDK paths — auto-detected from FRONTPANEL_DIR, or override directly.
FRONTPANEL_DIR ?= $(wildcard /home/andy/OpalKelly/FrontPanel-Ubuntu24.04LTS-x64-5.3.6)
FP_PYTHON_DIR  ?= $(FRONTPANEL_DIR)/API/Python
FP_LIB_DIR     ?= $(FRONTPANEL_DIR)/API
export PYTHONPATH    := $(FP_PYTHON_DIR)$(if $(PYTHONPATH),:$(PYTHONPATH))
export LD_LIBRARY_PATH := $(FP_LIB_DIR)$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))

FPGA_DIR             = fpga/xem7310
ZEPHYR_BUILD_FPGA    = build_zephyr_fpga
ZEPHYR_BUILD_HW_TEST = build_zephyr_hw_test
ZEPHYR_BUILD_ACCEL   = build_zephyr_accel_test
ZEPHYR_BUILD_SHELL   = build_zephyr_shell
BIT_FILE             = build/xem7310/ostomachion_xem7310.bit
MCS_FILE             = build/xem7310/ostomachion_xem7310.mcs

.PHONY: all analyze simulate clean sw test-baremetal test-default test-zephyr zephyr \
        zephyr-fpga fpga-synth fpga-program fpga-flash fpga-fw fpga-check fpga-release \
        test-hw test-accel-hw shell-hw uart-bridge

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
	cp $(SW_DIR)/neorv32_application_image.vhd test_imem_image.vhd

# ---------- convenience targets -------------------------------------------
test-baremetal: sw clean-ghdl
	$(MAKE) IMEM_IMAGE=test_imem_image.vhd SIM_TIME=500us all

test-default: clean-ghdl
	$(MAKE) SIM_TIME=500us all

# ---------- Zephyr build & test -----------------------------------------------
# Update the root compile_commands.json symlink so clangd picks up the
# include paths from whichever Zephyr config was built most recently.
define update-compile-commands
	@if [ -f $(1)/compile_commands.json ]; then \
		ln -sf $(1)/compile_commands.json compile_commands.json; \
	fi
endef

zephyr:
	@echo "=== Building Zephyr app ==="
	west build -b $(ZEPHYR_BOARD) $(ZEPHYR_APP_DIR) \
		-d $(ZEPHYR_BUILD_DIR) --pristine=auto \
		-- -DCMAKE_PROGRAM_PATH=$(IMAGE_GEN_DIR)
	cp $(ZEPHYR_BUILD_DIR)/zephyr/zephyr.vhd zephyr_imem_image.vhd
	$(call update-compile-commands,$(ZEPHYR_BUILD_DIR))

ZEPHYR_SIM_TIME ?= 800ms

test-zephyr: zephyr clean-ghdl
	$(MAKE) IMEM_IMAGE=zephyr_imem_image.vhd SIM_TIME=$(ZEPHYR_SIM_TIME) all
	@if grep -q 'PROJECT EXECUTION SUCCESSFUL' neorv32_tb.UART0_rx.out 2>/dev/null; then \
		echo "=== PASS: All Zephyr ZTEST suites passed ==="; \
	else \
		echo "=== FAIL: 'PROJECT EXECUTION SUCCESSFUL' not found in simulation output ===" >&2; \
		cat neorv32_tb.UART0_rx.out 2>/dev/null || echo "(no UART output file found)" >&2; \
		exit 1; \
	fi

clean-ghdl:
	@echo "=== Cleaning GHDL artifacts ==="
	ghdl --clean --work=neorv32 2>/dev/null || true
	ghdl --clean --work=work    2>/dev/null || true
	rm -f *.o *.cf output.ghw neorv32_tb UART0.log neorv32_tb.*.out

clean: clean-ghdl
	@echo "=== Cleaning SW build ==="
	$(MAKE) -C $(SW_DIR) RISCV_PREFIX=$(RISCV_PREFIX) clean 2>/dev/null || true
	rm -f test_imem_image.vhd zephyr_imem_image.vhd
	rm -rf $(ZEPHYR_BUILD_DIR) $(ZEPHYR_BUILD_FPGA) $(ZEPHYR_BUILD_HW_TEST) \
	       $(ZEPHYR_BUILD_ACCEL) $(ZEPHYR_BUILD_SHELL)

# ---------- FPGA targets (Opal Kelly XEM7310-A200) ----------------------------

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
	$(call update-compile-commands,$(ZEPHYR_BUILD_FPGA))

## Synthesise, implement and generate the XEM7310-A200 bitstream via Vivado.
## Requires Vivado to be on PATH or VIVADO variable set.
## Output: build/xem7310/ostomachion_xem7310.bit
fpga-synth:
	@echo "=== Running Vivado batch build ==="
	mkdir -p build/xem7310
	@command -v "$(VIVADO)" >/dev/null 2>&1 || { echo "ERROR: '$(VIVADO)' not found — install Vivado and add to PATH or set VIVADO=/path/to/vivado"; exit 1; }
	bash -o pipefail -c '$(VIVADO) -mode batch -source $(FPGA_DIR)/build.tcl 2>&1 | tee build/xem7310/build.log'
	@echo "=== Bitstream: $(BIT_FILE) ==="

## Program the XEM7310-A200 bitstream over USB using the Opal Kelly
## FrontPanel Python API.  The board must be connected via USB-C.
## Requires: FrontPanel SDK installed, 'ok' Python package importable.
fpga-program: $(BIT_FILE)
	@echo "=== Programming XEM7310-A200 via FrontPanel USB ==="
	python3 scripts/fpga_program.py $(BIT_FILE)

## Write the bitstream to the on-board SPI flash for persistent boot.
## Uses the FrontPanel FlashLoader utility from the FrontPanel SDK.
## After this operation the FPGA loads the design automatically on every
## power-up without needing fpga-program.
## Requires: FrontPanel SDK installed (FlashLoader in PATH or SDK bin dir).
fpga-flash: $(BIT_FILE)
	@echo "=== Programming XEM7310-A200 SPI flash via FrontPanel ==="
	FlashLoader --bitfile $(BIT_FILE)
	@echo "=== Flash programming complete — FPGA will auto-boot on next power-up ==="

## Start the FrontPanel UART-over-USB bridge.
## Creates a PTY (pseudo-terminal) that minicom or the bootloader upload
## script can use as UART_DEVICE.  Runs in the foreground; Ctrl-C to stop.
##
## Usage:
##   make uart-bridge                       # 19200 baud (bootloader)
##   make uart-bridge BRIDGE_BAUD=115200    # application baud
##   make uart-bridge PROGRAM=1             # program FPGA first, then bridge
##
## With PROGRAM=1 the script creates the PTY, programs the FPGA, then starts
## bridging — all on one USB handle.  This avoids the race where fpga-program
## and uart-bridge can't share the FrontPanel USB device simultaneously.
## Connect minicom to the PTY path BEFORE the FPGA finishes programming to
## capture the bootloader banner.
##
## The PTY path is printed on startup, e.g. /dev/pts/3.  Use it as:
##   make fpga-fw UART_DEVICE=/dev/pts/3
##   minicom -D /dev/pts/3 -b 19200
BRIDGE_BAUD ?= 19200

uart-bridge:
	@echo "=== Starting FrontPanel UART bridge ($(BRIDGE_BAUD) baud) ==="
ifdef PROGRAM
	python3 scripts/uart_bridge.py --baud $(BRIDGE_BAUD) --program $(BIT_FILE) $(BRIDGE_ARGS)
else
	python3 scripts/uart_bridge.py --baud $(BRIDGE_BAUD) $(BRIDGE_ARGS)
endif

## Upload Zephyr firmware to the NEORV32 bootloader over UART.
## The NEORV32 BROM bootloader listens at 19200 baud on UART0 immediately
## after reset.  Use this target for firmware iteration without re-synthesising.
## Prerequisites: zephyr-fpga must have been built; board must be reset.
##
## Without MC1 access, start the UART bridge first:
##   Terminal 1:  make uart-bridge                    (prints PTY path)
##   Terminal 2:  make fpga-fw UART_DEVICE=/dev/pts/N
fpga-fw: zephyr-fpga
	@echo "=== Uploading firmware via NEORV32 UART bootloader ==="
	bash $(NEORV32_HOME)/sw/image_gen/uart_upload.sh \
		$(UART_DEVICE) \
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

## Build hardware test firmware and upload to the XEM7310-A200 via UART bootloader.
## Combines prj.conf + prj_fpga.conf + prj_hw_test.conf (verbose output, logs,
## no I2C slave by default).  Override UART_DEVICE if your adapter is on a
## different port.  Bitstream must already be programmed via fpga-program.
##
## Without MC1 access, use the FrontPanel UART bridge:
##   Terminal 1:  make uart-bridge                    (prints PTY path)
##   Terminal 2:  make test-hw UART_DEVICE=/dev/pts/N
##   Terminal 3:  make uart-bridge BRIDGE_BAUD=115200 (for test output)
##
## Hardware test setup (requires MC1 for SPI/I2C):
##   SPI loopback : jumper MC1-28 (MOSI, W6) → MC1-29 (MISO, U5)
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
	bash $(NEORV32_HOME)/sw/image_gen/uart_upload.sh \
		$(UART_DEVICE) \
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
	bash $(NEORV32_HOME)/sw/image_gen/uart_upload.sh \
		$(UART_DEVICE) \
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
	$(call update-compile-commands,$(ZEPHYR_BUILD_SHELL))
	@echo "=== Uploading shell firmware via UART bootloader ==="
	bash $(NEORV32_HOME)/sw/image_gen/uart_upload.sh \
		$(UART_DEVICE) \
		$(ZEPHYR_BUILD_SHELL)/zephyr/zephyr.bin
	@echo "=== Connect at 115200 baud — type 'help' for available commands ==="

## NOTE: FFT simulation target removed.
## The FFT core is now the Xilinx xfft IP (PG109), instantiated in the
## block design.  GHDL simulation of Xilinx encrypted IP is not supported.
