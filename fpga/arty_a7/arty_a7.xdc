## Ostomachion — Arty A7 pin constraints
## Target: xc7a100tcsg324-1 (Digilent Arty A7-100T)
## All I/O: LVCMOS33 unless noted

## ==========================================================================
## Clock
## ==========================================================================
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

## ==========================================================================
## Reset (active-low pushbutton BTN RESET)
## ==========================================================================
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports ck_rst]

## ==========================================================================
## USB-UART (FTDI FT2232HQ channel B — micro-USB connector)
## ==========================================================================
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_txd_out]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports uart_rxd_in]

## ==========================================================================
## LEDs LD0..LD3 (green)
## ==========================================================================
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

## ==========================================================================
## SPI master — Pmod JA (2×6 header, top row pins 1–4)
##   JA-1 (G13) = SCK
##   JA-2 (B11) = MOSI
##   JA-3 (A11) = MISO
##   JA-4 (D12) = CS0
## ==========================================================================
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports spi_clk_o]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports spi_dat_o]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports spi_dat_i]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports spi_csn_o]

## ==========================================================================
## I2C / TWI (open-drain) — Pmod JB (2×6 header, top row pins 1–2)
##   JB-1 (E15) = SDA
##   JB-2 (E16) = SCL
## NOTE: External 4.7 kΩ pull-ups to 3V3 are required on the Pmod connector.
## ==========================================================================
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33} [get_ports twi_sda]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports twi_scl]

## ==========================================================================
## JTAG on-chip debugger — Pmod JC (2×6 header, top row pins 1–4)
##   JC-1 (K17) = TCK
##   JC-2 (M18) = TDI
##   JC-3 (N17) = TDO
##   JC-4 (P18) = TMS
## ==========================================================================
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports jtag_tck_i]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports jtag_tdi_i]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports jtag_tdo_o]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports jtag_tms_i]

## ==========================================================================
## JTAG clock (user JTAG via Pmod, not the dedicated FPGA JTAG pads)
## 10 MHz is a safe upper bound for most JTAG probes over Pmod.
## CLOCK_DEDICATED_ROUTE FALSE suppresses DRC REQP-49 for user-I/O clocks.
## ==========================================================================
create_clock -period 100.000 -name jtag_tck [get_ports jtag_tck_i]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets jtag_tck_i_IBUF]

## ==========================================================================
## Timing exceptions for asynchronous I/O
## SPI MISO, TWI, and JTAG control signals are asynchronous to the 100 MHz
## system clock.  Without these constraints Vivado reports unconstrained paths.
## ==========================================================================
set_false_path -from [get_ports {spi_dat_i twi_sda twi_scl jtag_tdi_i jtag_tms_i}]
set_false_path -to   [get_ports {spi_clk_o spi_dat_o spi_csn_o twi_sda twi_scl jtag_tdo_o uart_txd_out}]

## ==========================================================================
## Bitstream / configuration
## ==========================================================================
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
