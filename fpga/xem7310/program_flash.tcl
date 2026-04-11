## Ostomachion — SPI flash programming script (XEM7310-A200)
## Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
##
## Programs the XEM7310-A200 on-board 16 MiB FPGA SPI configuration flash
## with the Ostomachion bitstream MCS image.
##
## After successful programming, the FPGA will automatically load the design
## on every power-up without requiring 'make fpga-program'.
##
## Usage (via Makefile):
##   make fpga-flash
##
## Usage (manual):
##   vivado -mode batch -source fpga/xem7310/program_flash.tcl \
##          -tclargs build/xem7310/ostomachion_xem7310.mcs
##
## Prerequisites:
##   - Vivado >= 2024.1 installed and on PATH
##   - External JTAG cable connected to XEM7310 MC2 FPGA JTAG pins
##   - Bitstream built: 'make fpga-synth' must have succeeded

## ---------------------------------------------------------------------------
## Get MCS file path from argument
## ---------------------------------------------------------------------------
if {[llength $argv] < 1} {
    set script_dir [file dirname [file normalize [info script]]]
    set proj_root  [file normalize "$script_dir/../.."]
    set mcs_file   "$proj_root/build/xem7310/ostomachion_xem7310.mcs"
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
## Open Hardware Manager and connect
## ---------------------------------------------------------------------------
open_hw_manager
connect_hw_server -allow_non_jtag

if {[llength [get_hw_targets]] == 0} {
    puts "ERROR: No JTAG targets found."
    puts "ERROR: Ensure a JTAG cable is connected to the XEM7310 MC2 FPGA JTAG pins."
    close_hw_manager
    exit 1
}
open_hw_target [lindex [get_hw_targets] 0]

## Select the XC7A200T device
set device [lindex [get_hw_devices xc7a200t_0] 0]
if {$device eq ""} {
    set device [lindex [get_hw_devices] 0]
}
current_hw_device $device
refresh_hw_device $device
puts "INFO: Target device: [get_property PART $device]"

## ---------------------------------------------------------------------------
## Create configuration memory device
## XEM7310-A200 uses an on-board 16 MiB SPI flash.  Try common Vivado
## cfgmem part names; adjust if your Vivado version uses a different name.
## ---------------------------------------------------------------------------
set cfgmem_parts {}
foreach part_name {mt25ql128-spi-x1_x2_x4 n25q128-3.3v-spi-x1_x2_x4 s25fl128sxxxxxx0-spi-x1_x2_x4} {
    set cfgmem_parts [get_cfgmem_parts $part_name]
    if {[llength $cfgmem_parts] > 0} { break }
}
if {[llength $cfgmem_parts] == 0} {
    puts "ERROR: Cannot find cfgmem part definition for on-board SPI flash."
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

puts "INFO: Erasing and programming SPI flash (this takes ~60 seconds)..."
program_hw_cfgmem -hw_cfgmem $hw_cfgmem

puts "INFO: Flash programming complete."
puts "INFO: Rebooting FPGA from flash..."

boot_hw_device $device

puts "INFO: ============================================================"
puts "INFO:  Flash programming SUCCESSFUL"
puts "INFO:  The FPGA will now auto-configure from flash on every power-up."
puts "INFO: ============================================================"

close_hw_target
close_hw_manager
