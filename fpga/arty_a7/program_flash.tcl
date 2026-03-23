## Ostomachion — Quad-SPI flash programming script
## Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
##
## Programs the Arty A7-100T on-board Micron N25Q128A / MT25QL128 Quad-SPI
## configuration flash with the Ostomachion bitstream MCS image.
##
## After successful programming, the FPGA will automatically load the design
## on every power-up without requiring 'make fpga-program'.
##
## Usage (via Makefile):
##   make fpga-flash        # programs flash using build/arty_a7/*.mcs
##
## Usage (manual):
##   vivado -mode batch -source fpga/arty_a7/program_flash.tcl \
##          -tclargs build/arty_a7/ostomachion_arty_a7.mcs
##
## Prerequisites:
##   - Vivado ≥ 2024.1 installed and on PATH
##   - Arty A7-100T connected via Digilent USB-JTAG cable
##   - Bitstream built: 'make fpga-synth' must have succeeded

## ---------------------------------------------------------------------------
## Get MCS file path from argument
## ---------------------------------------------------------------------------
if {[llength $argv] < 1} {
    set script_dir [file dirname [file normalize [info script]]]
    set proj_root  [file normalize "$script_dir/../.."]
    set mcs_file   "$proj_root/build/arty_a7/ostomachion_arty_a7.mcs"
    puts "INFO: No MCS file argument; using default: $mcs_file"
} else {
    set mcs_file [lindex $argv 0]
}

if {![file exists $mcs_file]} {
    puts "ERROR: MCS file not found: $mcs_file"
    puts "ERROR: Run 'make fpga-synth' first to generate the flash image."
    exit 1
}
puts "INFO: Programming flash with: $mcs_file"

## ---------------------------------------------------------------------------
## Open Hardware Manager and connect to Arty A7
## ---------------------------------------------------------------------------
open_hw_manager
connect_hw_server -allow_non_jtag

## Open the first available JTAG target (the Arty A7's FTDI cable)
if {[llength [get_hw_targets]] == 0} {
    puts "ERROR: No JTAG targets found."
    puts "ERROR: Ensure the Arty A7 is connected and the Digilent cable driver is installed."
    close_hw_manager
    exit 1
}
open_hw_target [lindex [get_hw_targets] 0]

## Select the XC7A100T device
set device [lindex [get_hw_devices xc7a100t_0] 0]
if {$device eq ""} {
    set device [lindex [get_hw_devices] 0]
}
current_hw_device $device
refresh_hw_device $device
puts "INFO: Target device: [get_property PART $device]"

## ---------------------------------------------------------------------------
## Create configuration memory device (Micron MT25QL128 / N25Q128A)
## Vivado 2024+: use mt25ql128-spi-x1_x2_x4 (8-digit ID suffix varies)
## ---------------------------------------------------------------------------
set cfgmem_parts [get_cfgmem_parts {mt25ql128-spi-x1_x2_x4}]
if {[llength $cfgmem_parts] == 0} {
    ## Fall back to the older part name used in Vivado < 2024
    set cfgmem_parts [get_cfgmem_parts {n25q128-3.3v-spi-x1_x2_x4}]
}
if {[llength $cfgmem_parts] == 0} {
    puts "ERROR: Cannot find cfgmem part definition for MT25QL128 / N25Q128."
    puts "ERROR: Verify your Vivado installation includes the Artix-7 device support."
    close_hw_target
    close_hw_manager
    exit 1
}

create_hw_cfgmem \
    -hw_device  $device \
    -mem_dev    [lindex $cfgmem_parts 0]

## ---------------------------------------------------------------------------
## Configure and run the flash programming operation
## ---------------------------------------------------------------------------
set hw_cfgmem [get_hw_cfgmems]

set_property PROGRAM.BLANK_CHECK  0 $hw_cfgmem
set_property PROGRAM.ERASE        1 $hw_cfgmem
set_property PROGRAM.CFG_PROGRAM  1 $hw_cfgmem
set_property PROGRAM.VERIFY       1 $hw_cfgmem
set_property PROGRAM.CHECKSUM     0 $hw_cfgmem
set_property PROGRAM.FILES        [list $mcs_file] $hw_cfgmem

puts "INFO: Erasing and programming Quad-SPI flash (this takes ~60 seconds)..."
program_hw_cfgmem -hw_cfgmem $hw_cfgmem

puts "INFO: Flash programming complete."
puts "INFO: Rebooting FPGA from flash..."

## Boot from the newly programmed flash
boot_hw_device $device

puts "INFO: ============================================================"
puts "INFO:  Flash programming SUCCESSFUL"
puts "INFO:  The FPGA will now auto-configure from flash on every power-up."
puts "INFO: ============================================================"

close_hw_target
close_hw_manager
