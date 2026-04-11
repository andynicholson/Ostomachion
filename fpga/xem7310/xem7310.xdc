## Ostomachion — Opal Kelly XEM7310-A200 pin constraints
## Target: xc7a200tfbg484-1 (Opal Kelly XEM7310-A200)
##
## I/O assignments use the MC1 and MC2 expansion connectors.  Bank 34 and
## Bank 35 default to LVCMOS33 (3.3 V from on-board ferrite beads).
## Bank 13 is fixed at 3.3 V.
##
## Connector pinout reference: https://pins.opalkelly.com/pin_list/XEM7310

## ==========================================================================
## 200 MHz LVDS oscillator (Bank 13, internal to module — not on connectors)
## External termination provided on XEM7310 PCB; DIFF_TERM must be FALSE.
## ==========================================================================
set_property -dict {PACKAGE_PIN W11 IOSTANDARD LVDS_25 DIFF_TERM FALSE} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN W12 IOSTANDARD LVDS_25 DIFF_TERM FALSE} [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

## ==========================================================================
## Reset (active-low, directly from MC1 connector pin 37)
## ==========================================================================
set_property -dict {PACKAGE_PIN AB7 IOSTANDARD LVCMOS33} [get_ports ext_rstn]

## ==========================================================================
## UART (MC1, Bank 34)
##   MC1-15 (W9)  = TX out
##   MC1-17 (Y9)  = RX in
## Connect an external USB-UART adapter (e.g. FTDI TTL-232R-3V3) to these
## MC1 pins.  There is no on-board USB-UART on the XEM7310.
## ==========================================================================
set_property -dict {PACKAGE_PIN W9  IOSTANDARD LVCMOS33} [get_ports uart_txd_out]
set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33} [get_ports uart_rxd_in]

## ==========================================================================
## On-board LEDs D1–D8 (active-low — anodes pulled to 1.5 V, FPGA sinks)
## Bank 14, VCCO = 1.5 V → LVCMOS15
## Drive '0' to turn ON, '1' to turn OFF.
## The RTL inverts gpio_out so that software sees active-high semantics.
## ==========================================================================
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS15} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS15} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS15} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS15} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS15} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS15} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS15} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS15} [get_ports {led[7]}]

## ==========================================================================
## SPI master (MC1, Bank 34)
##   MC1-27 (T5)  = SCK
##   MC1-28 (W6)  = MOSI
##   MC1-29 (U5)  = MISO
##   MC1-30 (W5)  = CS0
## ==========================================================================
set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVCMOS33} [get_ports spi_clk_o]
set_property -dict {PACKAGE_PIN W6  IOSTANDARD LVCMOS33} [get_ports spi_dat_o]
set_property -dict {PACKAGE_PIN U5  IOSTANDARD LVCMOS33} [get_ports spi_dat_i]
set_property -dict {PACKAGE_PIN W5  IOSTANDARD LVCMOS33} [get_ports spi_csn_o]

## ==========================================================================
## I2C / TWI (open-drain) — MC1, Bank 34
##   MC1-31 (AA5) = SDA
##   MC1-33 (AB5) = SCL
## NOTE: External 4.7 kΩ pull-ups to 3V3 are required on the carrier board.
## ==========================================================================
set_property -dict {PACKAGE_PIN AA5 IOSTANDARD LVCMOS33} [get_ports twi_sda]
set_property -dict {PACKAGE_PIN AB5 IOSTANDARD LVCMOS33} [get_ports twi_scl]

## ==========================================================================
## NEORV32 on-chip debugger JTAG (MC2, Bank 35)
##   MC2-15 (P5)  = TCK
##   MC2-16 (P6)  = TMS
##   MC2-17 (P4)  = TDI
##   MC2-19 (N4)  = TDO
## These are USER I/O pins for the NEORV32 OCD, not the FPGA configuration
## JTAG (which is on MC2 pins 5/7/8/9).
## ==========================================================================
set_property -dict {PACKAGE_PIN P5  IOSTANDARD LVCMOS33} [get_ports jtag_tck_i]
set_property -dict {PACKAGE_PIN P6  IOSTANDARD LVCMOS33} [get_ports jtag_tms_i]
set_property -dict {PACKAGE_PIN P4  IOSTANDARD LVCMOS33} [get_ports jtag_tdi_i]
set_property -dict {PACKAGE_PIN N4  IOSTANDARD LVCMOS33} [get_ports jtag_tdo_o]

## ==========================================================================
## JTAG clock — user JTAG via MC2 connector, not the dedicated FPGA JTAG pads.
## CLOCK_DEDICATED_ROUTE FALSE suppresses DRC REQP-49 for user-I/O clocks.
## ==========================================================================
create_clock -period 100.000 -name jtag_tck [get_ports jtag_tck_i]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets jtag_tck_i_IBUF]

## ==========================================================================
## Timing exceptions for asynchronous I/O
## ==========================================================================
set_false_path -from [get_ports {spi_dat_i twi_sda twi_scl jtag_tdi_i jtag_tms_i uart_rxd_in ext_rstn}]
set_false_path -to   [get_ports {spi_clk_o spi_dat_o spi_csn_o twi_sda twi_scl jtag_tdo_o uart_txd_out led[*]}]

## ==========================================================================
## FrontPanel Host Interface (directly wired to Cypress FX3 USB controller)
## Pin assignments from Opal Kelly SDK — LVCMOS18, Bank 15
## ==========================================================================
set_property PACKAGE_PIN Y19  [get_ports {okHU[0]}]
set_property PACKAGE_PIN R18  [get_ports {okHU[1]}]
set_property PACKAGE_PIN R16  [get_ports {okHU[2]}]
set_property SLEW FAST        [get_ports {okHU[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {okHU[*]}]

set_property PACKAGE_PIN W19  [get_ports {okUH[0]}]
set_property PACKAGE_PIN V18  [get_ports {okUH[1]}]
set_property PACKAGE_PIN U17  [get_ports {okUH[2]}]
set_property PACKAGE_PIN W17  [get_ports {okUH[3]}]
set_property PACKAGE_PIN T19  [get_ports {okUH[4]}]
set_property IOSTANDARD LVCMOS18 [get_ports {okUH[*]}]

set_property PACKAGE_PIN AB22 [get_ports {okUHU[0]}]
set_property PACKAGE_PIN AB21 [get_ports {okUHU[1]}]
set_property PACKAGE_PIN Y22  [get_ports {okUHU[2]}]
set_property PACKAGE_PIN AA21 [get_ports {okUHU[3]}]
set_property PACKAGE_PIN AA20 [get_ports {okUHU[4]}]
set_property PACKAGE_PIN W22  [get_ports {okUHU[5]}]
set_property PACKAGE_PIN W21  [get_ports {okUHU[6]}]
set_property PACKAGE_PIN T20  [get_ports {okUHU[7]}]
set_property PACKAGE_PIN R19  [get_ports {okUHU[8]}]
set_property PACKAGE_PIN P19  [get_ports {okUHU[9]}]
set_property PACKAGE_PIN U21  [get_ports {okUHU[10]}]
set_property PACKAGE_PIN T21  [get_ports {okUHU[11]}]
set_property PACKAGE_PIN R21  [get_ports {okUHU[12]}]
set_property PACKAGE_PIN P21  [get_ports {okUHU[13]}]
set_property PACKAGE_PIN R22  [get_ports {okUHU[14]}]
set_property PACKAGE_PIN P22  [get_ports {okUHU[15]}]
set_property PACKAGE_PIN R14  [get_ports {okUHU[16]}]
set_property PACKAGE_PIN W20  [get_ports {okUHU[17]}]
set_property PACKAGE_PIN Y21  [get_ports {okUHU[18]}]
set_property PACKAGE_PIN P17  [get_ports {okUHU[19]}]
set_property PACKAGE_PIN U20  [get_ports {okUHU[20]}]
set_property PACKAGE_PIN N17  [get_ports {okUHU[21]}]
set_property PACKAGE_PIN N14  [get_ports {okUHU[22]}]
set_property PACKAGE_PIN V20  [get_ports {okUHU[23]}]
set_property PACKAGE_PIN P16  [get_ports {okUHU[24]}]
set_property PACKAGE_PIN T18  [get_ports {okUHU[25]}]
set_property PACKAGE_PIN V19  [get_ports {okUHU[26]}]
set_property PACKAGE_PIN AB20 [get_ports {okUHU[27]}]
set_property PACKAGE_PIN P15  [get_ports {okUHU[28]}]
set_property PACKAGE_PIN V22  [get_ports {okUHU[29]}]
set_property PACKAGE_PIN U18  [get_ports {okUHU[30]}]
set_property PACKAGE_PIN AB18 [get_ports {okUHU[31]}]
set_property SLEW FAST        [get_ports {okUHU[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {okUHU[*]}]

set_property PACKAGE_PIN N13  [get_ports {okAA}]
set_property IOSTANDARD LVCMOS18 [get_ports {okAA}]

## FrontPanel host-interface clock (active edge of okUH[0], ~100.8 MHz)
create_clock -name okUH0 -period 9.920 [get_ports {okUH[0]}]

set_input_delay  -add_delay -max -clock [get_clocks {okUH0}]  8.000 [get_ports {okUH[*]}]
set_input_delay  -add_delay -min -clock [get_clocks {okUH0}] 10.000 [get_ports {okUH[*]}]
set_multicycle_path -setup -from [get_ports {okUH[*]}] 2

set_input_delay  -add_delay -max -clock [get_clocks {okUH0}]  8.000 [get_ports {okUHU[*]}]
set_input_delay  -add_delay -min -clock [get_clocks {okUH0}]  2.000 [get_ports {okUHU[*]}]
set_multicycle_path -setup -from [get_ports {okUHU[*]}] 2

set_output_delay -add_delay -max -clock [get_clocks {okUH0}]  2.000 [get_ports {okHU[*]}]
set_output_delay -add_delay -min -clock [get_clocks {okUH0}] -0.500 [get_ports {okHU[*]}]

set_output_delay -add_delay -max -clock [get_clocks {okUH0}]  2.000 [get_ports {okUHU[*]}]
set_output_delay -add_delay -min -clock [get_clocks {okUH0}] -0.500 [get_ports {okUHU[*]}]

## ==========================================================================
## FrontPanel UART bridge — clock domain crossing
## XPM async FIFOs set ASYNC_REG automatically; Vivado applies the correct
## timing exceptions for their gray-code synchronizers.
## The manual baud-divisor double-register (fp_uart_bridge/baud_sync*)
## crosses from okHost ~100.8 MHz to the 100 MHz system clock.
## ==========================================================================
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *uart_bridge_i/baud_sync1*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *uart_src_sync1*}]
## TX FIFO reset: sys_rstn (sys_clk) drives rst on the TX xpm_fifo_async
## whose wr_clk is fp_clk.  XPM internally synchronizes the reset across
## clock domains; the inter-clock path does not need to be timed.
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *uart_bridge_i/tx_fifo_i*xpm_fifo_rst_inst*}]

## ==========================================================================
## Bitstream / configuration
## XEM7310 ties CFGBVS_B to GND; config bank is 1.8 V (per Opal Kelly SDK).
## ==========================================================================
set_property CFGBVS GND         [current_design]
set_property CONFIG_VOLTAGE 1.8  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS True [current_design]
