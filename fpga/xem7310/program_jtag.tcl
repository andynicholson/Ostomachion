## Ostomachion — JTAG bitstream programming via Vivado Hardware Manager
## Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
##
## Programs the XEM7310-A200 FPGA via JTAG (volatile; erased on power-cycle).
## Requires an external JTAG cable (Xilinx Platform Cable USB II, Digilent
## HS2/HS3, or similar) connected to the FPGA JTAG pins on MC2 (pins 5/7/8/9).
##
## Usage (via Makefile):
##   make fpga-program
##
## Usage (manual):
##   vivado -mode batch -source fpga/xem7310/program_jtag.tcl \
##          -tclargs build/xem7310/ostomachion_xem7310.bit

## ---------------------------------------------------------------------------
## Get bitstream file path from argument
## ---------------------------------------------------------------------------
if {[llength $argv] < 1} {
    set script_dir [file dirname [file normalize [info script]]]
    set proj_root  [file normalize "$script_dir/../.."]
    set bit_file   "$proj_root/build/xem7310/ostomachion_xem7310.bit"
    puts "INFO: No bitstream argument; using default: $bit_file"
} else {
    set bit_file [lindex $argv 0]
}

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream file not found: $bit_file"
    puts "ERROR: Run 'make fpga-synth' first to generate the bitstream."
    exit 1
}
puts "INFO: Programming FPGA with: $bit_file"

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
## Program the FPGA
## ---------------------------------------------------------------------------
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device

puts "INFO: ============================================================"
puts "INFO:  FPGA programming SUCCESSFUL (volatile — SRAM)"
puts "INFO:  Use 'make fpga-flash' for persistent flash programming."
puts "INFO: ============================================================"

close_hw_target
close_hw_manager
